import Cocoa

/// Monotonic seconds.
@inline(__always) func nowSec() -> Double { ProcessInfo.processInfo.systemUptime }

/// One bouncing app: a decaying-envelope source on a real-time phase clock.
/// Hovering its Dock tile DISMISSES it (the real bounce doesn't resume after hover),
/// so once `dismissing` is set it fires one final impulse (the bounce it's finishing)
/// and is then removed — it never resumes.
final class Voice {
    let label: String
    private let m: BounceModel
    private let startReal: Double
    var lastPhase = -1.0
    var dismissing = false       // hovered → finish the CURRENT cycle's burst, then stop
    var dismissCycle = -1.0      // cycle index in progress when hover was first seen
    var hoverSince: Double?      // when continuous hover began (for debounce)

    init(label: String, model: BounceModel, now: Double) {
        self.label = label; self.m = model; self.startReal = now
    }

    func phase(_ now: Double) -> Double { now - startReal - m.startDelayMs / 1000.0 }

    func amplitude(at e: Double) -> Double {
        let p = m.periodMs / 1000.0, tau = m.decayTauMs / 1000.0
        if e < 0 || p <= 0 || tau <= 0 { return 0 }
        let cutoff = 6.0 * tau, cyc = floor(e / p)
        var amp = 0.0
        for c in [cyc - 1, cyc] where c >= 0 {
            for i in m.impulseOffsetsMs.indices {
                let dt = e - (c * p + m.impulseOffsetsMs[i] / 1000.0)
                if dt >= 0 && dt < cutoff { amp += (i < m.impulseGains.count ? m.impulseGains[i] : 1) * exp(-dt / tau) }
            }
        }
        return amp
    }
}

/// Mixes voices and renders impulses. The voice whose Dock tile is under the cursor
/// is marked dismissing (hover = dismiss, permanent — matching the Dock not resuming
/// the bounce when you leave). One tap fires per impulse crossing; strength from the
/// summed envelope.
final class Synth {
    private let haptics: Haptics
    private var m: BounceModel
    private let q = DispatchQueue(label: "impulse.synth", qos: .userInteractive)
    private var voices: [pid_t: Voice] = [:]
    private var timer: DispatchSourceTimer?
    private var ticking = false
    private let tiles = DockTiles()
    private let tickHz = 120.0

    init(haptics: Haptics, model: BounceModel) {
        self.haptics = haptics; self.m = model
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .distantFuture)   // parked until a voice exists
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// The 120 Hz zero-leeway tick forces constant CPU wakeups, so it only runs
    /// while something is bouncing; otherwise the timer is parked (rescheduled to
    /// the far future — suspend/resume is a crash if the source is ever released
    /// suspended). Both must be called on `q`.
    private func startTicking() {
        guard !ticking else { return }
        ticking = true
        timer?.schedule(deadline: .now(), repeating: 1.0 / tickHz, leeway: .nanoseconds(0))
    }
    private func stopTicking() {
        guard ticking else { return }
        ticking = false
        timer?.schedule(deadline: .distantFuture)
    }

    var count: Int { q.sync { voices.count } }

    func add(_ pid: pid_t, label: String) {
        q.async {
            self.voices[pid] = Voice(label: label, model: self.m, now: nowSec())
            self.startTicking()
        }
    }
    func remove(_ pid: pid_t) {
        q.async {
            self.voices[pid] = nil
            if self.voices.isEmpty { self.stopTicking() }
        }
    }
    /// Live-update tunable params (Debug sliders).
    func update(_ model: BounceModel) { q.async { self.m = model } }

    private func level(_ now: Double) -> Double {
        voices.values.reduce(0) { $0 + $1.amplitude(at: $1.phase(now)) }
    }

    private static func hovered(_ label: String, _ h: String?) -> Bool {
        guard let h = h?.lowercased(), !h.isEmpty else { return false }
        return label.lowercased() == h     // exact: watcher name == AX tile title
    }

    private func tick() {
        if voices.isEmpty { stopTicking(); return }
        let now = nowSec()
        let P = m.periodMs / 1000.0
        let lastOff = (m.impulseOffsetsMs.max() ?? 0) / 1000.0

        // Per-icon hover cancel (optional). When on, the cursor must stay on the icon for
        // a tunable `debounceMs` before it counts as a cancel (so a quick pass-over doesn't
        // stop it); once it counts, the in-flight cycle's burst finishes and the voice
        // stops. When off, hover is ignored entirely (no AX query, no cancel).
        if m.hoverCancelEnabled {
            let hov = tiles.appUnderCursor()
            let debounce = m.debounceMs / 1000.0
            for v in voices.values {
                if Synth.hovered(v.label, hov) {
                    if v.hoverSince == nil { v.hoverSince = now }
                    if !v.dismissing && now - (v.hoverSince ?? now) >= debounce {
                        v.dismissing = true
                        v.dismissCycle = floor(v.phase(now) / P)
                    }
                } else {
                    v.hoverSince = nil
                }
            }
        } else {
            for v in voices.values where v.dismissing {
                v.dismissing = false; v.dismissCycle = -1; v.hoverSince = nil
            }
        }

        var deadPids: [pid_t] = []
        for (pid, v) in voices {
            let cur = v.phase(now)
            let prev = v.lastPhase
            v.lastPhase = cur
            if cur >= 0 && cur > prev {
                for (i, off) in m.impulseOffsetsMs.enumerated() {
                    let o = off / 1000.0
                    let cHigh = Int(floor((cur - o) / P))
                    if cHigh < 0 { continue }
                    let cLow = max(0, Int(floor((max(prev, 0) - o) / P)))
                    for c in cLow...max(cLow, cHigh) {
                        let T = Double(c) * P + o
                        if T <= prev || T > cur { continue }
                        if v.dismissing && Double(c) > v.dismissCycle { continue } // suppress next launch onward
                        if !m.impulseActive(at: T) { continue }      // icon is resting between reminder bursts
                        // strength tracks the bounce decay; primary = first arc (wireless
                        // trackpads only get that one, to stay in phase over Bluetooth).
                        haptics.tap(m.strength(cycle: c, impulse: i), primary: i == 0)
                    }
                }
            }
            // Current cycle's burst has finished → stop for good.
            if v.dismissing && cur > v.dismissCycle * P + lastOff + 0.05 { deadPids.append(pid) }
        }
        for pid in deadPids { voices[pid] = nil }
        if voices.isEmpty { stopTicking() }
    }
}
