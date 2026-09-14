import AppKit
import SwiftUI

/// Menu-bar app entry. Launch with `DokiMenuBarApp.run(state:)` from your
/// existing main dispatch when no CLI subcommand is given, e.g.:
///
///     // main.swift (Sources/Doki)
///     let args = CommandLine.arguments.dropFirst()
///     switch args.first {
///     case "watch":    runWatch()
///     case "demo":     runDemo()
///     case "tap-test": runTapTest()
///     case "debug":    runDebug()
///     default:
///         let state = DokiState()
///         // wire the engine:
///         state.onStartWatching = { engine.start() }
///         state.onTestTap       = { engine.spawnTestBounce() }
///         DokiMenuBarApp.run(state: state)
///     }
///
/// Info.plist needs LSUIElement = true so no Dock icon appears
/// (Doki watching its own Dock icon would be a little too self-aware).
struct DokiMenuBarApp: App {
    static var sharedState: DokiState!

    /// Hands SwiftUI the state object, then enters the app run loop. Never returns.
    @MainActor
    static func run(state: DokiState) {
        sharedState = state
        state.onStartWatching()          // watching is always on; start at launch
        DokiMenuBarApp.main()
    }

    var body: some Scene {
        MenuBarExtra {
            DokiMenuView(state: Self.sharedState)
        } label: {
            // make-app.sh copies DokiMenuTemplate(@2x).png into Resources;
            // the Template suffix makes AppKit auto-tint for menu bar state.
            if let img = NSImage(named: "DokiMenuTemplate") {
                Image(nsImage: img)
            } else {
                Image(systemName: "dot.radiowaves.up.forward") // dev fallback (swift run)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
