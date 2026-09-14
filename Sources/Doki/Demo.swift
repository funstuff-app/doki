import Foundation

/// Self-contained demo: spawns bouncers with DISTINCT Dock names (so each is a
/// separate, individually-hoverable tile), staggered by random phase offsets.
///
/// Each bouncer is launched in "wait" mode: it holds its attention request until
/// we post a per-name "go", which we only do once its Dock tile exists AND has
/// stopped moving (AX poll). A blind post-launch timer races the Dock's tile-add
/// animation — the LSWantsAttention flag then flips before the icon visibly
/// bounces and the taps run permanently early.
final class Demo {
    static let goNotification = Notification.Name("com.doki.bounce.go")

    private var procs: [Process] = []
    private var temps: [URL] = []
    private var polls: [Timer] = []
    private var named: [String: Process] = [:]
    private let tiles = DockTiles()

    static let names = ["Doki Demo 1", "Doki Demo 2", "Doki Demo 3",
                        "Doki Demo 4", "Doki Demo 5"]

    /// Spawn ONE more bouncer (test tap adds one per click), reusing the slot of any
    /// bouncer the user has since dismissed. No-op at 5 concurrent.
    func spawnOne(iconPath: String? = nil) {
        guard let src = Demo.bouncerURL() else { print("test tap: bouncer helper not found"); return }
        named = named.filter { $0.value.isRunning }
        guard let name = Demo.names.first(where: { named[$0] == nil }) else { return } // cap 5
        launch(src, as: name, info: false, iconPath: iconPath)
    }

    static func bouncerURL() -> URL? {
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        var candidates = [exeDir.appendingPathComponent("bouncer")]
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "bouncer") { candidates.append(aux) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `info: true` → each bouncer asks for informational (single-bounce) attention;
    /// false → critical (bounces until dismissed). `duration` cleans them up after that
    /// many seconds; pass `nil` to leave them until dismissed. `iconPath` sets the tile icon.
    func start(count: Int = 2, duration: TimeInterval? = 15, info: Bool = false, iconPath: String? = nil) {
        guard let src = Demo.bouncerURL() else { print("self-demo: bouncer helper not found"); return }
        let names = Demo.names
        launch(src, as: names[0], info: info, iconPath: iconPath)
        for n in 1..<min(count, names.count) {
            let offset = Double(Int.random(in: 300...1500)) / 1000.0
            let nm = names[n]
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) { [weak self] in self?.launch(src, as: nm, info: info, iconPath: iconPath) }
            print(String(format: "self-demo: \(nm) offset %.0f ms", offset * 1000))
        }
        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in self?.stop() }
        }
    }

    func stop() {
        polls.forEach { $0.invalidate() }; polls.removeAll()
        procs.forEach { if $0.isRunning { $0.terminate() } }
        temps.forEach { try? FileManager.default.removeItem(at: $0) }
        procs.removeAll(); temps.removeAll(); named.removeAll()
    }

    /// Poll the Dock (AX) until `name`'s tile exists at the same rect on two
    /// consecutive reads — i.e. the tile-add animation is done — then tell that
    /// bouncer to request attention. Without AX the bouncer's own 5s fallback fires.
    private func releaseWhenTileSettles(_ name: String) {
        var lastRect: CGRect?
        let deadline = nowSec() + 4.0
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let rect = self.tiles.tileRect(titled: name)
            let settled = rect != nil && rect == lastRect
            lastRect = rect
            if settled || nowSec() > deadline {
                timer.invalidate()
                DistributedNotificationCenter.default().postNotificationName(
                    Demo.goNotification, object: name, deliverImmediately: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        polls.append(t)
    }

    /// Copy the bouncer to a uniquely-named temp file so its Dock tile shows that name.
    private func launch(_ src: URL, as name: String, info: Bool = false, iconPath: String? = nil) {
        let dst = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
            let p = Process(); p.executableURL = dst
            var a = ["wait"]                 // hold the bounce for our tile-settled "go"
            if info { a.append("info") }
            if let iconPath { a.append(iconPath) }
            p.arguments = a
            try p.run()
            procs.append(p); temps.append(dst); named[name] = p
            releaseWhenTileSettles(name)
        } catch { print("self-demo: launch \(name) failed: \(error)") }
    }
}
