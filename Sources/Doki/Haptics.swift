import Foundation
import IOKit

/// Drives the built-in trackpad's Taptic Engine through the private
/// `MultitouchSupport.framework` `MTActuator*` API.
///
/// Notes that are load-bearing on Apple Silicon (M1):
///   * We resolve the symbols with `dlopen`/`dlsym` rather than declaring them
///     `extern`. Direct linking against the private framework trips pointer
///     authentication (PAC) and bus-errors at the call site.
///   * The actuator is created from a numeric device ID read from the opaque
///     `MTDevice` struct at byte offset 64 (the getter has an unstable calling
///     convention) — the approach proven by MatMercer/mactic.
///   * There can be MORE THAN ONE actuator-capable device (e.g. an external Magic
///     Trackpad alongside the laptop's). We must pick the **built-in** one via
///     `MTDeviceIsBuiltIn`, or the taps fire on the wrong trackpad.
///
/// The engine only exposes a handful of fixed, pre-baked click patterns. There is
/// no waveform/amplitude control for the laptop trackpad, so we choreograph these
/// discrete taps in time rather than synthesizing a continuous vibration.
final class Haptics {

    /// The pre-baked actuation patterns the Taptic Engine understands.
    enum Pattern: Int32, CaseIterable {
        case weakClick = 1
        case strongClick = 2
        case buzz = 3
        case lightTap = 4
        case mediumTap = 5
        case strongTap = 6

        var label: String {
            switch self {
            case .weakClick: return "weak click"
            case .strongClick: return "strong click"
            case .buzz: return "buzz"
            case .lightTap: return "light tap"
            case .mediumTap: return "medium tap"
            case .strongTap: return "strong tap"
            }
        }
    }

    // MARK: - Private framework function pointer types

    fileprivate typealias MTDeviceRef = UnsafeMutableRawPointer
    fileprivate typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    fileprivate typealias IsBuiltInFn = @convention(c) (MTDeviceRef) -> Bool
    fileprivate typealias GetDeviceIDFn = @convention(c) (MTDeviceRef, UnsafeMutablePointer<UInt64>) -> Int32
    fileprivate typealias ActuatorCreateFn = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    fileprivate typealias ActuatorOpenFn = @convention(c) (CFTypeRef, UInt32) -> Int32
    fileprivate typealias ActuatorCloseFn = @convention(c) (CFTypeRef) -> Int32
    fileprivate typealias ActuatorActuateFn =
        @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32

    private let actuate: ActuatorActuateFn
    private let close: ActuatorCloseFn
    private struct Actuator { let ref: CFTypeRef; let id: UInt64; let builtIn: Bool }
    private let actuatorList: [Actuator]  // every actuation-capable trackpad (built-in + Magic Trackpad)
    var deviceIDs: [UInt64] { actuatorList.map(\.id) }

    // MARK: - Symbol loading

    private struct Syms {
        let createList: CreateListFn
        let isBuiltIn: IsBuiltInFn?
        let getDeviceID: GetDeviceIDFn?
        let actuatorCreate: ActuatorCreateFn
        let actuatorOpen: ActuatorOpenFn
        let actuatorClose: ActuatorCloseFn
        let actuatorActuate: ActuatorActuateFn
    }

    enum HapticsError: Error, CustomStringConvertible {
        case frameworkLoad(String)
        case missingSymbol(String)
        case noDevice
        case noUsableActuator(String)

        var description: String {
            switch self {
            case .frameworkLoad(let p): return "could not dlopen MultitouchSupport at \(p)"
            case .missingSymbol(let s): return "missing private symbol: \(s)"
            case .noDevice: return "no multitouch device found"
            case .noUsableActuator(let attempts):
                return "no trackpad yielded a working actuator — tried \(attempts)"
            }
        }
    }

    private static func loadSyms() throws -> (UnsafeMutableRawPointer, Syms) {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else { throw HapticsError.frameworkLoad(path) }
        func req<T>(_ name: String, as t: T.Type) throws -> T {
            guard let p = dlsym(handle, name) else { throw HapticsError.missingSymbol(name) }
            return unsafeBitCast(p, to: T.self)
        }
        func opt<T>(_ name: String, as t: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        let syms = Syms(
            createList: try req("MTDeviceCreateList", as: CreateListFn.self),
            isBuiltIn: opt("MTDeviceIsBuiltIn", as: IsBuiltInFn.self),
            getDeviceID: opt("MTDeviceGetDeviceID", as: GetDeviceIDFn.self),
            actuatorCreate: try req("MTActuatorCreateFromDeviceID", as: ActuatorCreateFn.self),
            actuatorOpen: try req("MTActuatorOpen", as: ActuatorOpenFn.self),
            actuatorClose: try req("MTActuatorClose", as: ActuatorCloseFn.self),
            actuatorActuate: try req("MTActuatorActuate", as: ActuatorActuateFn.self)
        )
        return (handle, syms)
    }

    /// All devices in MTDeviceCreateList order, with their offset-64 ID and built-in flag.
    private static func devices(_ s: Syms) throws -> [(dev: MTDeviceRef, id: UInt64, builtIn: Bool)] {
        guard let list = s.createList()?.takeRetainedValue() else { throw HapticsError.noDevice }
        let n = CFArrayGetCount(list)
        guard n > 0 else { throw HapticsError.noDevice }
        var out: [(MTDeviceRef, UInt64, Bool)] = []
        for i in 0..<n {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            let id = dev.load(fromByteOffset: 64, as: UInt64.self)
            let builtIn = s.isBuiltIn?(dev) ?? false
            out.append((dev, id, builtIn))
        }
        return out
    }

    /// Candidate device IDs for EVERY trackpad (built-in + paired Magic Trackpad),
    /// deduped. The offset-64 struct read isn't stable across Mac models / OS builds
    /// (it produced a rejected ID on a 13" M1 2020), so we also collect the ID from
    /// the MTDeviceGetDeviceID getter and from the IORegistry "Multitouch ID"
    /// property; init probes each and opens an actuator on every one that works.
    /// Non-actuating devices (e.g. a Magic Mouse) fail to open and are dropped.
    private static func candidateIDs(_ syms: Syms, devs: [(dev: MTDeviceRef, id: UInt64, builtIn: Bool)]) -> [(id: UInt64, builtIn: Bool)] {
        var builtInFor: [UInt64: Bool] = [:]   // an id is built-in if ANY source says so
        func note(_ id: UInt64, _ b: Bool) {
            guard id != 0 else { return }
            builtInFor[id] = (builtInFor[id] ?? false) || b
        }
        for d in devs {
            note(d.id, d.builtIn)                              // struct read @ offset 64
            if let g = syms.getDeviceID {
                var v: UInt64 = 0
                if g(d.dev, &v) == 0 { note(v, d.builtIn) }    // private getter
            }
        }
        for r in registryMultitouchIDs() { note(r.id, r.builtIn) }
        // Built-in first (stable feel is the primary device), then external.
        return builtInFor.map { (id: $0.key, builtIn: $0.value) }
            .sorted { ($0.builtIn ? 0 : 1, $0.id) < ($1.builtIn ? 0 : 1, $1.id) }
    }

    /// "Multitouch ID" + built-in flag of every AppleMultitouchDevice in the
    /// IORegistry (built-in and external), so a paired Magic Trackpad is included.
    private static func registryMultitouchIDs() -> [(id: UInt64, builtIn: Bool)] {
        var out: [(UInt64, Bool)] = []
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleMultitouchDevice"), &it) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(it) }
        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            func prop(_ k: String) -> Any? {
                IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let id = (prop("Multitouch ID") as? NSNumber)?.uint64Value else { continue }
            let builtIn = (prop("MT Built-In") as? Bool) ?? (prop("Multitouch Serial Number") == nil)
            out.append((id, builtIn))
        }
        return out
    }

    // MARK: - Lifecycle

    init() throws {
        let (_, syms) = try Haptics.loadSyms()
        let devs = try Haptics.devices(syms)
        let candidates = Haptics.candidateIDs(syms, devs: devs)
        self.actuate = syms.actuatorActuate
        self.close = syms.actuatorClose

        var opened: [Actuator] = []
        var attempts: [String] = []
        for c in candidates {
            guard let created = syms.actuatorCreate(c.id)?.takeRetainedValue() else {
                attempts.append("\(c.id): create failed"); continue
            }
            if syms.actuatorOpen(created, 0) == 0 {
                opened.append(Actuator(ref: created, id: c.id, builtIn: c.builtIn))
            } else {
                _ = syms.actuatorClose(created)
                attempts.append("\(c.id): open failed")
            }
        }
        guard !opened.isEmpty else {
            throw HapticsError.noUsableActuator(attempts.isEmpty ? "no candidate device IDs" : attempts.joined(separator: "; "))
        }
        self.actuatorList = opened
    }

    /// Wireless actuations run here, OFF the synth timing thread, so a Bluetooth
    /// stall can never delay the built-in tap. At most one is in flight at a time
    /// (`wBusy`); impulses that arrive while the previous is still draining are
    /// DROPPED rather than queued, so the wireless pad plays current taps and
    /// never accumulates a backlog that drifts later and later.
    private let wirelessQueue = DispatchQueue(label: "haptics.wireless", qos: .userInteractive)
    private let wLock = NSLock()
    private var wBusy = false

    deinit { actuatorList.forEach { _ = close($0.ref) } }

    // MARK: - Actuation

    /// Fire a discrete tap on every trackpad. Built-in fires inline (precise);
    /// wireless fires async on its own queue so Bluetooth latency can't drag the
    /// built-in off phase.
    @discardableResult
    func tap(_ pattern: Pattern, primary: Bool = true) -> Int32 { fire(pattern.rawValue, primary: primary) }

    /// Fire an arbitrary actuation ID on all trackpads (for the diagnostic sweep).
    @discardableResult
    func actuate(id: Int32) -> Int32 { fire(id, primary: true) }

    private func fire(_ id: Int32, primary: Bool) -> Int32 {
        var firstErr: Int32 = 0
        for a in actuatorList {
            if a.builtIn {
                let r = actuate(a.ref, id, 0, 0.0, 0.0)
                if r != 0 && firstErr == 0 { firstErr = r }
            } else {
                if !primary { continue }                    // wireless: one tap per bounce only
                wLock.lock(); let skip = wBusy; if !skip { wBusy = true }; wLock.unlock()
                if skip { continue }                       // drop, don't queue behind a slow BT tap
                let ref = a.ref, act = actuate
                wirelessQueue.async {
                    _ = act(ref, id, 0, 0.0, 0.0)
                    self.wLock.lock(); self.wBusy = false; self.wLock.unlock()
                }
            }
        }
        return firstErr
    }

    // MARK: - Diagnostics

    /// Print every multitouch device and which one we'd drive.
    static func diagnose() throws {
        let (_, syms) = try loadSyms()
        let devs = try devices(syms)
        print("found \(devs.count) multitouch device(s):")
        for (i, d) in devs.enumerated() {
            var apiID: String = "n/a"
            if let g = syms.getDeviceID {
                var out: UInt64 = 0
                let rc = g(d.dev, &out)
                apiID = rc == 0 ? "\(out)" : "err(\(rc))"
            }
            print("  [\(i)] offset64-id=\(d.id)  builtIn=\(d.builtIn)  MTDeviceGetDeviceID=\(apiID)")
        }
        print("IORegistry Multitouch IDs: \(registryMultitouchIDs())")
        let candidates = candidateIDs(syms, devs: devs)
        if candidates.isEmpty {
            print("→ NO multitouch device found")
            return
        }
        for c in candidates {
            guard let a = syms.actuatorCreate(c.id)?.takeRetainedValue() else {
                print("    \(c.id) builtIn=\(c.builtIn): create failed"); continue
            }
            let r = syms.actuatorOpen(a, 0)
            let taps = c.builtIn ? "all impulses" : "primary impulse only (buffered wireless)"
            print("    \(c.id) builtIn=\(c.builtIn): \(r == 0 ? "OPEN → \(taps)" : "open failed IOReturn \(r)")")
            _ = syms.actuatorClose(a)
        }
    }
}
