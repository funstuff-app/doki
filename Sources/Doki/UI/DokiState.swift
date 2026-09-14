import AppKit
import SwiftUI

/// UI-facing state. The haptics engine talks to this; the popover observes it.
/// Wire the hooks once at startup. Watching is always on (no toggle), strength is
/// envelope-derived, and per-icon hover cancel / launch-at-login are always on,
/// so there are no tunables here.
@MainActor
final class DokiState: ObservableObject {

    // MARK: engine hooks (assign these from the engine at launch)
    var onStartWatching: () -> Void = {}
    var onTestTap: () -> Void = {}

    // MARK: published state
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    // MARK: accessibility
    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        // TCC grants land asynchronously; poll briefly so the pill flips
        // without reopening the popover.
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                refreshAccessibility()
                if accessibilityGranted { break }
            }
        }
    }
}
