import AppKit
import ApplicationServices

/// Reads the Dock's tiles via Accessibility so we know which app's icon the cursor
/// is over (the Dock pauses *that* icon's bounce on hover). Returns the title of the
/// tile under the cursor. Tiles are refreshed periodically; cursor checked live.
final class DockTiles {
    private var tiles: [(title: String, rect: CGRect)] = []
    private var tilesAt = 0.0
    private var dockEl: AXUIElement?

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Fresh (uncached) rect of the dock tile with this exact title, or nil if absent.
    /// Used to confirm a newly-spawned app's tile exists and has stopped moving
    /// before asking it to bounce.
    func tileRect(titled name: String) -> CGRect? {
        guard let dock = dockElement() else { return nil }
        var out: [(String, CGRect)] = []
        collect(dock, 0, into: &out)
        return out.first { $0.0 == name }?.1
    }

    /// Title of the dock tile under the cursor, or nil.
    func appUnderCursor() -> String? {
        let t = nowSec()
        if t - tilesAt > 0.5 { refresh(); tilesAt = t }
        guard let loc = CGEvent(source: nil)?.location else { return nil }   // top-left global
        // Match only the actual dock tile (resting slot) — the dock region you enter
        // to dismiss a bounce. No upward extension (that falsely dismissed when the
        // cursor merely rested above the dock).
        for tile in tiles where tile.rect.contains(loc) { return tile.title }
        return nil
    }

    // MARK: AX plumbing

    private func dockElement() -> AXUIElement? {
        if let d = dockEl { return d }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        dockEl = el
        return el
    }

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }
    private func str(_ el: AXUIElement, _ a: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success else { return nil }
        return v as? String
    }
    private func point(_ el: AXUIElement) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v) == .success,
              let val = v else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(val as! AXValue, .cgPoint, &p) ? p : nil
    }
    private func size(_ el: AXUIElement) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success,
              let val = v else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(val as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Collect every titled+positioned descendant tile (depth ≤ 3).
    private func collect(_ el: AXUIElement, _ depth: Int, into out: inout [(String, CGRect)]) {
        if depth > 3 { return }
        for c in children(el) {
            if let title = str(c, kAXTitleAttribute), !title.isEmpty,
               let p = point(c), let s = size(c), s.width > 4, s.height > 4 {
                out.append((title, CGRect(origin: p, size: s)))
            }
            collect(c, depth + 1, into: &out)
        }
    }

    private func refresh() {
        guard let dock = dockElement() else { tiles = []; return }
        var out: [(String, CGRect)] = []
        collect(dock, 0, into: &out)
        tiles = out
    }
}
