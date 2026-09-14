import Foundation
import AppKit
import ServiceManagement

// Doki — fire trackpad Taptic taps in sync with apps' Dock icon bounces.
//
// Launched as the .app (or with no command) → menu-bar app.
// CLI:
//   Doki watch [--only A,B] [--ignore X]   tap for ANY app that bounces
//   Doki demo                              self-contained 2-bouncer demo
//   Doki ramp                              feel one bounce in isolation
//   Doki run [model.json]                  single-bounce demo via the bouncer signal
//   Doki tap-test | debug                  haptic diagnostics

setbuf(stdout, nil)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
// No command, or an app-launch flag (e.g. -psn / -NSDocument…) → menu-bar app.
let command = (args.count > 1 && !args[1].hasPrefix("-")) ? args[1] : "menu"

if command == "menu" {
    // Top-level code runs on the main thread; the menu-bar setup is @MainActor.
    MainActor.assumeIsolated { launchMenuBar() }
}

// `debug` must run even if normal init would fail, so handle it before constructing Haptics.
if command == "debug" {
    do { try Haptics.diagnose() } catch { fail("diagnose failed: \(error)") }
    let haptics: Haptics
    do { haptics = try Haptics() } catch { fail("haptics init failed: \(error)") }
    print("sweeping actuation IDs on trackpad(s) \(haptics.deviceIDs) — feel for each:")
    for id: Int32 in [1, 2, 3, 4, 5, 6, 15, 16] {
        print("  id \(id)  IOReturn=\(haptics.actuate(id: id))")
        Thread.sleep(forTimeInterval: 1.0)
    }
    print("done.")
    exit(0)
}

let haptics: Haptics
do { haptics = try Haptics() } catch { fail("haptics init failed: \(error)") }

switch command {
case "tap-test":
    print("cycling Taptic patterns on trackpad(s) \(haptics.deviceIDs):")
    for pattern in Haptics.Pattern.allCases {
        print("  [\(pattern.rawValue)] \(pattern.label)  (IOReturn=\(haptics.tap(pattern)))")
        Thread.sleep(forTimeInterval: 0.8)
    }
    print("done.")

case "ramp":
    // Feel ONE bounce in isolation (3 decaying arcs), no bouncer needed.
    let modelPath = args.indices.contains(2) ? args[2] : "bounce-model.json"
    let model = BounceModel.resolve(modelPath)
    let synth = Synth(haptics: haptics, model: model)
    synth.add(0, label: "ramp")
    print("ramp: one bounce (impulses \(model.impulseOffsetsMs.map { Int($0) })ms, τ=\(Int(model.decayTauMs))ms)")
    Thread.sleep(forTimeInterval: (model.impulseOffsetsMs.last ?? 1038) / 1000.0 + model.decayTauMs / 1000.0 * 6 + 0.3)
    print("done.")

case "run":
    // Single-bounce demo driven by the test bouncer's DistributedNotification.
    let modelPath = (args.indices.contains(2) && !args[2].hasPrefix("--")) ? args[2] : "bounce-model.json"
    let model = BounceModel.resolve(modelPath)
    let synth = Synth(haptics: haptics, model: model)
    Engine(synth: synth, model: model).start()
    print("config: impulses \(model.impulseOffsetsMs.map { Int($0) })ms, period \(Int(model.periodMs))ms")
    RunLoop.main.run()

case "watch":
    // Detect ANY app's Dock bounce (any number at once) and tap each, phase-correct.
    // [--only A,B] / [--ignore X,Y] filter by app name or bundle id.
    var modelPath = "bounce-model.json"
    var only: [String] = [], ignore: [String] = []
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--only":   i += 1; if args.indices.contains(i) { only = args[i].lowercased().split(separator: ",").map(String.init) }
        case "--ignore": i += 1; if args.indices.contains(i) { ignore = args[i].lowercased().split(separator: ",").map(String.init) }
        default: if !args[i].hasPrefix("--") { modelPath = args[i] }
        }
        i += 1
    }
    let model = BounceModel.resolve(modelPath)
    let watcher: AttentionWatcher
    do { watcher = try AttentionWatcher() } catch { fail("watcher init failed: \(error)") }
    func matches(_ app: NSRunningApplication, _ needles: [String]) -> Bool {
        let hay = [(app.localizedName ?? ""), (app.bundleIdentifier ?? "")].joined(separator: " ").lowercased()
        return needles.contains { hay.contains($0) }
    }
    watcher.shouldTrack = { app in
        if !only.isEmpty { return matches(app, only) }
        if !ignore.isEmpty { return !matches(app, ignore) }
        return true
    }
    let synth = Synth(haptics: haptics, model: model)
    watcher.onStart = { pid, name in synth.add(pid, label: name); print("🔵 \(name) (pid \(pid)) bouncing — \(synth.count) active") }
    watcher.onStop = { pid in synth.remove(pid); print("⚪︎ pid \(pid) stopped — \(synth.count) active") }
    if !only.isEmpty { print("filter: only \(only)") }
    if !ignore.isEmpty { print("filter: ignoring \(ignore)") }
    watcher.start()
    RunLoop.main.run()

case "demo":
    // Self-contained: watch + spawn two bouncers (random phase offset).
    let model = BounceModel.resolve(args.indices.contains(2) ? args[2] : nil)
    let synth = Synth(haptics: haptics, model: model)
    let watcher: AttentionWatcher
    do { watcher = try AttentionWatcher() } catch { fail("watcher init failed: \(error)") }
    watcher.onStart = { pid, name in synth.add(pid, label: name); print("🔵 \(name) bouncing") }
    watcher.onStop = { pid in synth.remove(pid); print("⚪︎ pid \(pid) stopped") }
    watcher.start()
    let demo = Demo()
    demo.start(count: 2, duration: 13)
    print("self-demo running ~15s…")
    DispatchQueue.main.asyncAfter(deadline: .now() + 16) { exit(0) }
    RunLoop.main.run()

default:
    fail("unknown command '\(command)'. use: menu | watch | demo | ramp | run | tap-test | debug")
}

// MARK: - Menu-bar GUI

/// Build the engine, wire it to the SwiftUI popover's `DokiState`, and enter the
/// menu-bar run loop. Runs with no CLI subcommand (the normal .app launch).
@MainActor
func launchMenuBar() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)        // menu-bar only, no Dock icon (also LSUIElement)

    let haptics: Haptics
    do { haptics = try Haptics() } catch {
        let a = NSAlert(); a.messageText = "Doki can't reach the trackpad"
        a.informativeText = "\(error)"; a.runModal(); exit(1)
    }
    let watcher: AttentionWatcher
    do { watcher = try AttentionWatcher() } catch {
        let a = NSAlert(); a.messageText = "Doki can't watch the Dock"
        a.informativeText = "\(error)"; a.runModal(); exit(1)
    }

    let model = BounceModel.resolve()   // hover cancel always on; debounce stays at the model default
    let synth = Synth(haptics: haptics, model: model)
    let state = DokiState()
    let demo = Demo()

    // Kawaii icon for the test bouncer's Dock tile (bundle resource, else dev iconset).
    let iconPath = Bundle.main.url(forResource: "Doki", withExtension: "icns")?.path
        ?? ["packaging/icon/Doki.iconset/icon_512x512.png",
            "packaging/icon/Doki.iconset/icon_256x256.png"].first {
            FileManager.default.fileExists(atPath: $0)
        }

    try? SMAppService.mainApp.register()   // always launch at login

    watcher.onStart = { pid, name in synth.add(pid, label: name) }
    watcher.onStop  = { pid in synth.remove(pid) }

    state.onStartWatching = { watcher.start(pollMs: 25) }   // invoked once by DokiMenuBarApp.run
    state.onTestTap = {
        // Each click adds ONE more kawaii Dock bouncer (cap 5 concurrent); the watch
        // pipeline taps them in sync and each bounces until dismissed (click it).
        demo.spawnOne(iconPath: iconPath)
    }

    DokiMenuBarApp.run(state: state)   // starts watching, then enters the run loop; never returns
}
