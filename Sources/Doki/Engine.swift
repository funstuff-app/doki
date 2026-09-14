import Foundation

/// Bounce signal model. Impulse schedule (offsets/gains/period) is the exact
/// `Tile::updateBouncing` pattern from the Dock binary; `decayTauMs` is the
/// per-impulse envelope decay; the `amp*` thresholds map the combined envelope
/// level to a discrete Taptic strength. All overridable in bounce-model.json.
struct BounceModel: Decodable {
    var startDelayMs: Double
    var impulseOffsetsMs: [Double]   // binary: 500 / 826 / 1038
    var impulseGains: [Double]       // binary arc heights: 1.0 / 0.5 / 0.25
    var periodMs: Double            // binary: 2000

    var decayTauMs: Double          // impulse decay time constant (interference window)
    var ampLight: Double            // level → strength bands
    var ampMed: Double
    var ampStrong: Double
    var debounceMs: Double          // cursor must stay on the icon this long before a hover cancels

    // Long-period attention schedule (DockGlobals, seconds): the Dock bounces
    // continuously for `attentionInitialS`, then re-reminds with a short burst
    // every `attentionIntervalS` (first burst at initial+interval) while the
    // LSWantsAttention flag stays true. Taps must follow the VISIBLE bounce,
    // not the flag — the flag stays up long after the icon goes quiet.
    var attentionInitialS: Double   // bounce-duration: 60
    var attentionBurstS: Double     // bounce-secondary-duration: 3
    var attentionIntervalS: Double  // bounce-secondary-interval: 60

    // Per-icon hover cancel is always on; this gate stays for the engine's internal use.
    var hoverCancelEnabled = true

    private enum K: String, CodingKey {
        case startDelayMs, impulseOffsetsMs, impulseGains, periodMs, decayTauMs, ampLight, ampMed, ampStrong, debounceMs
        case attentionInitialS, attentionBurstS, attentionIntervalS
    }
    init(from d: Decoder) throws {
        let c = try? d.container(keyedBy: K.self)
        func dbl(_ k: K, _ def: Double) -> Double { (try? c?.decodeIfPresent(Double.self, forKey: k) ?? nil) ?? def }
        func arr(_ k: K, _ def: [Double]) -> [Double] { (try? c?.decodeIfPresent([Double].self, forKey: k) ?? nil) ?? def }
        startDelayMs    = dbl(.startDelayMs, -3)
        impulseOffsetsMs = arr(.impulseOffsetsMs, [500, 826, 1038])
        impulseGains     = arr(.impulseGains, [1.0, 0.5, 0.25])
        periodMs        = dbl(.periodMs, 2000)
        decayTauMs      = dbl(.decayTauMs, 130)
        ampLight        = dbl(.ampLight, 0.10)
        ampMed          = dbl(.ampMed, 0.40)
        ampStrong       = dbl(.ampStrong, 0.75)
        debounceMs      = dbl(.debounceMs, 500)
        attentionInitialS  = dbl(.attentionInitialS, 60)
        attentionBurstS    = dbl(.attentionBurstS, 3)
        attentionIntervalS = dbl(.attentionIntervalS, 60)
    }

    /// Is the icon visibly bouncing at phase time `T` (seconds since bounce start)?
    /// Mirrors the Dock's schedule: continuous for the initial window, then a short
    /// burst every interval. (60s and the 2s bounce period divide evenly, so burst
    /// starts stay phase-aligned with the cycle grid.)
    func impulseActive(at T: Double) -> Bool {
        if T < attentionInitialS { return true }
        let firstBurst = attentionInitialS + attentionIntervalS
        guard T >= firstBurst else { return false }
        let intoBurst = (T - firstBurst).truncatingRemainder(dividingBy: attentionIntervalS)
        return intoBurst < attentionBurstS
    }

    /// Taptic strength for a bounce cycle + impulse, tracking the icon's decaying
    /// bounce: cycle 0 → 6/4/2, cycle 1 → each −1 → 5/3/1, cycle 2+ → all 1 forever.
    func strength(cycle: Int, impulse: Int) -> Haptics.Pattern {
        let base = [6, 4, 2]
        let id = cycle >= 2 ? 1 : max(1, (impulse < base.count ? base[impulse] : 1) - cycle)
        return Haptics.Pattern(rawValue: Int32(id)) ?? .weakClick
    }

    /// Map a combined envelope level to a discrete Taptic strength. The tap family
    /// (IDs 4/5/6) feels near-identical on this trackpad, so the bands are spread
    /// across patterns that are actually discriminable: 6 / 4 / 2 / 1.
    func pattern(for L: Double) -> Haptics.Pattern {
        if L >= ampStrong { return .strongTap }
        if L >= ampMed { return .lightTap }
        if L >= ampLight { return .strongClick }
        return .weakClick
    }

    static func load(_ path: String) throws -> BounceModel {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(BounceModel.self, from: data)
    }

    /// Resolve a model from an explicit path, else the app bundle's resource,
    /// else all-defaults (every field is optional in the decoder).
    static func resolve(_ path: String? = nil) -> BounceModel {
        if let p = path, let m = try? load(p) { return m }
        if let url = Bundle.main.url(forResource: "bounce-model", withExtension: "json"),
           let m = try? load(url.path) { return m }
        return (try? JSONDecoder().decode(BounceModel.self, from: Data("{}".utf8)))
            ?? BounceModel.allDefaults
    }

    private static let allDefaults = try! JSONDecoder().decode(BounceModel.self, from: Data("{}".utf8))
}

/// Single-bounce demo driver: adds one voice to the synth in response to the test
/// `bouncer`'s DistributedNotification. (General any-app path is `watch`.)
final class Engine {
    static let startNotification = Notification.Name("com.doki.bounce.started")
    static let stopNotification = Notification.Name("com.doki.bounce.stopped")

    private let synth: Synth
    private let model: BounceModel

    init(synth: Synth, model: BounceModel) { self.synth = synth; self.model = model }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Engine.startNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.synth.add(0, label: "demo")
        }
        dnc.addObserver(forName: Engine.stopNotification, object: nil, queue: .main) { [weak self] _ in
            self?.synth.remove(0)
        }
        print("engine ready — waiting for bounce.")
    }
}
