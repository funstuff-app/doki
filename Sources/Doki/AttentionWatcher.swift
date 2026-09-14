import AppKit

/// Watches every Dock-visible app for the exact attention state the Dock keys off:
/// LaunchServices `_kLSApplicationDesiresAttentionKey` (string value "LSWantsAttention"),
/// read per-pid via `_LSASNCreateWithPid` + `_LSCopyApplicationInformationItem`.
///
/// A false→true transition = that app started bouncing → `onStart(pid, name)`.
/// true→false = it stopped (activated / done) → `onStop(pid)`.
/// Catching the transition (poll ~25 ms) pins the bounce phase to the app's `_bounceST`,
/// and since our schedule and the Dock's both repeat every 2000 ms, they stay locked.
final class AttentionWatcher {
    private typealias ASNCreateFn = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<AnyObject>?
    private typealias CopyItemFn = @convention(c) (Int32, AnyObject, CFString) -> Unmanaged<AnyObject>?

    private let asnCreate: ASNCreateFn
    private let copyItem: CopyItemFn
    private let key: CFString

    private var timer: DispatchSourceTimer?
    private var bouncing: Set<pid_t> = []
    /// Dock-visible apps whose attention flag the fast poll checks. Enumerating
    /// NSWorkspace.runningApplications and reading activationPolicy does an
    /// LSCopyApplicationInformation per app — far too expensive at 40 Hz (it was
    /// nearly all of the app's idle CPU). Rebuilt on launch/terminate
    /// notifications plus a slow safety refresh (apps rarely change policy).
    private var tracked: [(pid: pid_t, name: String)] = []
    private var lastRefresh = 0.0
    private var workspaceObservers: [NSObjectProtocol] = []

    var onStart: ((pid_t, String) -> Void)?
    var onStop: ((pid_t) -> Void)?
    /// Optional filter: return false to ignore an app entirely.
    var shouldTrack: ((NSRunningApplication) -> Bool)?

    enum WatcherError: Error, CustomStringConvertible {
        case load, symbol(String)
        var description: String {
            switch self {
            case .load: return "could not dlopen LaunchServices"
            case .symbol(let s): return "missing LaunchServices symbol: \(s)"
            }
        }
    }

    init() throws {
        let path = "/System/Library/Frameworks/CoreServices.framework/Versions/A/"
            + "Frameworks/LaunchServices.framework/Versions/A/LaunchServices"
        guard let h = dlopen(path, RTLD_NOW) else { throw WatcherError.load }
        func sym(_ n: String) throws -> UnsafeMutableRawPointer {
            guard let p = dlsym(h, n) else { throw WatcherError.symbol(n) }
            return p
        }
        asnCreate = unsafeBitCast(try sym("_LSASNCreateWithPid"), to: ASNCreateFn.self)
        copyItem = unsafeBitCast(try sym("_LSCopyApplicationInformationItem"), to: CopyItemFn.self)
        // The constant's string value is "LSWantsAttention" on this OS.
        let kp = try sym("_kLSApplicationDesiresAttentionKey")
            .assumingMemoryBound(to: Unmanaged<CFString>.self)
        key = kp.pointee.takeUnretainedValue()
    }

    /// True iff the app with this pid currently wants attention (is bouncing).
    func wantsAttention(_ pid: pid_t) -> Bool {
        guard let asn = asnCreate(kCFAllocatorDefault, pid)?.takeRetainedValue() else { return false }
        guard let v = copyItem(-1, asn, key)?.takeRetainedValue() else { return false }
        return (v as? NSNumber)?.boolValue ?? false
    }

    func start(pollMs: Int = 25) {
        refreshTracked()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.refreshTracked()
            })
        }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(pollMs), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        print("watching all Dock apps for bounces (poll \(pollMs)ms)…")
    }

    func stop() {
        timer?.cancel(); timer = nil
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { nc.removeObserver($0) }
        workspaceObservers.removeAll()
        for pid in bouncing { onStop?(pid) }
        bouncing.removeAll()
    }

    /// Rebuild the tracked-app list (the expensive part: one LS info copy per app).
    private func refreshTracked() {
        // Only regular (Dock-visible) apps can bounce.
        tracked = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && (shouldTrack?($0) ?? true) }
            .compactMap { app in
                let pid = app.processIdentifier
                return pid > 0 ? (pid, app.localizedName ?? "pid \(pid)") : nil
            }
        lastRefresh = nowSec()
    }

    private func poll() {
        // Safety net for apps that switch activationPolicy without relaunching.
        if nowSec() - lastRefresh > 2.0 { refreshTracked() }
        var nowBouncing: Set<pid_t> = []
        for app in tracked where wantsAttention(app.pid) {
            nowBouncing.insert(app.pid)
            if !bouncing.contains(app.pid) {
                onStart?(app.pid, app.name)
            }
        }
        for pid in bouncing.subtracting(nowBouncing) { onStop?(pid) }
        bouncing = nowBouncing
    }
}
