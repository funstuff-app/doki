import AppKit

// bouncer — a controllable Dock-bounce target for the doki PoC.
//
// Becomes a regular (Dock-visible) app, asks for the user's attention so its
// Dock icon bounces, and broadcasts a DistributedNotification at the instant it
// does — giving the Doki engine a precise t0 to sync Taptic impulses against.
// The Dock and the engine then both follow the same reverse-engineered timing.

let startNotification = Notification.Name("com.doki.bounce.started")
let stopNotification = Notification.Name("com.doki.bounce.stopped")
let goNotification = Notification.Name("com.doki.bounce.go")

setbuf(stdout, nil) // unbuffered so logs survive even if killed
let app = NSApplication.shared
app.setActivationPolicy(.regular) // show in the Dock so it can bounce

// args: "info" → bounce once; absent → critical (bounce until dismissed).
//       "wait" → hold the attention request until the spawner posts a "go"
//                notification (it confirms our Dock tile exists and is at rest
//                first — a blind timer races the tile-add animation and starts
//                the taps before the visible bounce).
//       a path ending .icns/.png → use it as the Dock tile icon.
let bouncerArgs = CommandLine.arguments.dropFirst()
let bounceOnce = bouncerArgs.contains("info")
let waitForGo = bouncerArgs.contains("wait")
let iconPath = bouncerArgs.first { $0.hasSuffix(".icns") || $0.hasSuffix(".png") }
let myName = (CommandLine.arguments[0] as NSString).lastPathComponent

final class Delegate: NSObject, NSApplicationDelegate {
    private var bounceStarted = false
    private var fired = false

    private func fire() {
        guard !fired else { return }
        fired = true
        let type: NSApplication.RequestUserAttentionType = bounceOnce ? .informationalRequest : .criticalRequest
        DistributedNotificationCenter.default().postNotificationName(
            startNotification, object: nil, deliverImmediately: true)
        NSApp.requestUserAttention(type)
        bounceStarted = true
        print("requested \(bounceOnce ? "informational (once)" : "critical (repeat)") attention.")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        print("bouncer running.")
        // Kawaii Dock tile instead of the generic executable icon.
        if let p = iconPath, let img = NSImage(contentsOfFile: p) {
            NSApp.applicationIconImage = img
        }
        // If our parent (Doki) goes away, don't linger as an orphan bouncing in the Dock.
        // An orphaned process is reparented to launchd (pid 1).
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if getppid() == 1 { NSApp.terminate(nil) }
        }
        // Background OURSELVES so the bounce can start the moment we request it,
        // instead of waiting for some other app to come forward.
        NSApp.hide(nil)
        if waitForGo {
            DistributedNotificationCenter.default().addObserver(
                forName: goNotification, object: nil, queue: .main
            ) { [weak self] n in
                guard (n.object as? String) == myName else { return }
                self?.fire()
            }
            // Safety net: if the go never arrives (spawner died, no AX), bounce anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in self?.fire() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.fire() }
        }
    }

    func applicationDidBecomeActive(_ note: Notification) {
        // The activation that can fire at launch isn't a dismiss — ignore until bouncing.
        guard bounceStarted else { return }
        // The user clicked the bouncing icon → dismissed. Tell the engine, then quit so
        // the Dock tile goes away (a critical bounce otherwise repeats until dismissed).
        DistributedNotificationCenter.default().postNotificationName(
            stopNotification, object: nil, deliverImmediately: true)
        NSApp.terminate(nil)
    }
}

let delegate = Delegate()
app.delegate = delegate
app.run()
