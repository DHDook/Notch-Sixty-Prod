import Combine
import Foundation

// E12 S27 / S13 (behind `e12.blind-listening`): the remote panel's level-matched before/after button (G9), and the
// request that opens the Blind Listening page with A and B filled in. Control plane, main actor. "Before" is processing
// off (EQ, preamp and dynamics), "After" is the current settings; the louder side is trimmed by the shared level match,
// and the applied settings are restored on Done, stop, output change or any engine refusal. Allocation: allocates
// (offline). Synchronisation: none. Sample rate: any rate to 384 kHz (the level model uses the output rate).

@MainActor
final class BeforeAfterModel: ObservableObject {
    enum Side: Equatable { case before, after }

    private let player: ContentAuditionPlaying
    /// E13 S12: the headphone session's processing, switched with the content settings ("before" is everything off).
    private let headphone: HeadphoneCompareSupporting?
    private var headphoneInUse = false
    private var baseline: ContentABAuditionState?
    private var before: ContentABAuditionState?
    private var trims: (before: Double, after: Double) = (0, 0)
    private let clock: () -> Date
    private var holdUntil: Date?

    @Published private(set) var side: Side?
    @Published private(set) var message: String?
    @Published private(set) var levelSummary: String?

    init(player: ContentAuditionPlaying, headphone: HeadphoneCompareSupporting? = nil, clock: @escaping () -> Date = { Date() }) {
        self.player = player
        self.headphone = headphone
        self.clock = clock
    }

    var isComparing: Bool { side != nil }
    /// A switch takes the same fixed time in either direction (decision 24).
    var isSwitching: Bool {
        if let holdUntil, clock() < holdUntil { return true }
        return player.isSwitching
    }

    func show(_ target: Side) {
        guard !isSwitching else { return }
        if let reason = player.unavailableReason ?? (baseline == nil ? headphone?.unavailableReason : nil) {
            message = reason
            return
        }
        do {
            if baseline == nil { try begin() }
            guard let baseline, let before else { return }
            switch target {
            case .before: try player.apply(before, attenuationDB: trims.before)
            case .after: try player.apply(baseline, attenuationDB: trims.after)
            }
            if headphoneInUse { try headphone?.apply(bypassed: target == .before) }
            side = target
            message = nil
            holdUntil = clock().addingTimeInterval(ComparisonSwitchTiming.fixedSeconds)
        } catch {
            message = error.localizedDescription
            if side == nil { baseline = nil }
        }
    }

    /// Back to the applied settings.
    func done() {
        guard let baseline else { return }
        do {
            try player.apply(baseline, attenuationDB: 0)
            if headphoneInUse { try headphone?.apply(bypassed: false) }
            message = nil
        } catch { message = error.localizedDescription }
        headphoneInUse = false
        self.baseline = nil
        side = nil
        levelSummary = nil
    }

    /// Polled by the panel: ends the comparison when playback stopped or the output changed.
    func refresh() {
        guard side != nil, let reason = player.unavailableReason else { return }
        done()
        message = reason
    }

    private func begin() throws {
        let current = player.currentContentState()
        let candidates = ComparisonCandidates.list(current: current, presets: [])
        let off = candidates[1].state
        let hp = headphone?.hasEffect == true ? headphone : nil
        guard off != current || hp != nil else { throw BlindLiveComparisonError.identicalSides }
        let level = try BlindLiveComparison.match(
            a: off, b: current, sampleRate: player.outputSampleRate,
            extraADB: hp?.levelDB(bypassed: true) ?? 0, extraBDB: hp?.levelDB(bypassed: false) ?? 0)
        let floor = DSPGainConfiguration.inputPreampRange.lowerBound
        guard level.trimADB >= -24, level.trimBDB >= -24,
              off.inputPreampDB + level.trimADB >= floor, current.inputPreampDB + level.trimBDB >= floor else {
            throw BlindLiveComparisonError.levelsTooFarApart
        }
        baseline = current
        before = off
        trims = (level.trimADB, level.trimBDB)
        headphoneInUse = hp != nil
        levelSummary = hp?.levelIsApproximate == true
            ? level.summary + " Virtual Speakers level is not matched." : level.summary
    }
}

/// "Compare blind..." from the remote panel: the page opens with A (current settings) and B (processing off) filled in.
@MainActor
final class BlindListeningRequest: ObservableObject {
    static let shared = BlindListeningRequest()
    @Published var pending = false
    func request() { pending = true }
    func take() { pending = false }
}
