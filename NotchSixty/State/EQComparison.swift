import Combine
import Foundation

// E27 S3b: EQ A/B comparison. Two EQ slots, a toggle that publishes the other slot through the
// normal `replaceStereoEQConfiguration` path, copy and Keep, a per-slot undo history, and an
// optional loudness match. Swift only; nothing here runs on the audio thread, and the engine
// reads no flag (the controller is built inert unless `e27.eq-safety` is on).

enum EQComparisonSlot: String, CaseIterable, Identifiable, Sendable {
    case a, b
    var id: String { rawValue }
    var displayName: String { self == .a ? "A" : "B" }
    var other: EQComparisonSlot { self == .a ? .b : .a }
}

/// The two slots as plain values. The active slot's content is whatever the EQ is now; the
/// inactive slot's content is held here. Bypass belongs to the page, not a slot, so a switch
/// keeps the live bypass state.
struct EQComparisonSlots: Equatable, Sendable {
    private(set) var active: EQComparisonSlot = .a
    private(set) var a: StereoEQConfiguration
    private(set) var b: StereoEQConfiguration

    init(live: StereoEQConfiguration) {
        a = live
        b = live
    }

    func configuration(_ slot: EQComparisonSlot) -> StereoEQConfiguration { slot == .a ? a : b }

    mutating func store(_ configuration: StereoEQConfiguration, in slot: EQComparisonSlot) {
        if slot == .a { a = configuration } else { b = configuration }
    }

    /// Records edits made to the live EQ into the active slot.
    mutating func updateActive(from live: StereoEQConfiguration) {
        store(live, in: active)
    }

    /// Makes `slot` active and returns the configuration to publish (bypass kept from `live`).
    mutating func switchTo(_ slot: EQComparisonSlot, live: StereoEQConfiguration) -> StereoEQConfiguration {
        updateActive(from: live)
        active = slot
        var target = configuration(slot)
        target.bypassed = live.bypassed
        return target
    }

    /// Copies one slot over the other. Copying onto the active slot returns what to publish.
    mutating func copy(from source: EQComparisonSlot, live: StereoEQConfiguration) -> StereoEQConfiguration? {
        updateActive(from: live)
        let destination = source.other
        var value = configuration(source)
        value.bypassed = false
        store(value, in: destination)
        guard destination == active else { return nil }
        value.bypassed = live.bypassed
        return value
    }
}

/// Pink-noise loudness of an EQ: the K-weighted (ITU-R BS.1770-4) power of pink noise through
/// the EQ, so two EQs compare by the 10 log10 of their power ratio.
enum EQLoudnessMatch {
    /// Integration: log-spaced, 1/24 octave, 20 Hz to the lower of 20 kHz and 0.49 fs. The pink
    /// weight 1/f becomes a flat weight in log frequency.
    static let pointsPerOctave = 24.0

    /// BS.1770-4 K-weighting power response |H(f)|^2 at `rate` (stage 1 high shelf, stage 2 high-pass).
    static func kWeightingPower(frequency: Double, rate: Double) -> Double {
        biquadPower(shelf(rate: rate), frequency, rate) * biquadPower(highPass(rate: rate), frequency, rate)
    }

    private typealias Biquad = (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double)

    private static func shelf(rate: Double) -> Biquad {
        let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
        let k = tan(Double.pi * f0 / rate)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return (
            (vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
            2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0
        )
    }

    private static func highPass(rate: Double) -> Biquad {
        let f0 = 38.13547087602444, q = 0.5003270373238773
        let k = tan(Double.pi * f0 / rate)
        let a0 = 1 + k / q + k * k
        return (1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0)
    }

    private static func biquadPower(_ c: Biquad, _ frequency: Double, _ rate: Double) -> Double {
        let w = 2 * Double.pi * frequency / rate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let numRe = c.b0 + c.b1 * c1 + c.b2 * c2, numIm = -(c.b1 * s1 + c.b2 * s2)
        let denRe = 1 + c.a1 * c1 + c.a2 * c2, denIm = -(c.a1 * s1 + c.a2 * s2)
        return (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm)
    }

    /// Relative K-weighted pink-noise power through `configuration` (an arbitrary but common
    /// scale, so only ratios mean anything). Bypassed counts as flat. Dynamic and FIR bands are
    /// taken at their static settings (FIR bands omitted).
    static func power(configuration: StereoEQConfiguration, rate: Double) -> Double {
        guard rate.isFinite, rate > 0 else { return 0 }
        let upper = min(20_000, rate * 0.49)
        guard upper > 20 else { return 0 }
        func lane(_ bands: [EQBand]) -> [N60BiquadCoefficients] {
            configuration.bypassed ? [] : ProductionEQResponseMath.compile(bands: bands, sampleRate: rate)
        }
        let lanes: [[N60BiquadCoefficients]]
        switch configuration.channelMode {
        case .linked: lanes = [lane(configuration.linkedBands)]
        case .independent: lanes = [lane(configuration.leftBands), lane(configuration.rightBands)]
        case .midSide: lanes = [lane(configuration.midBands), lane(configuration.sideBands)]
        }
        let steps = Int((log2(upper / 20) * pointsPerOctave).rounded(.up))
        var total = 0.0
        for index in 0...steps {
            let f = min(upper, 20 * pow(2, Double(index) / pointsPerOctave))
            let weight = kWeightingPower(frequency: f, rate: rate)
            let eq = lanes.reduce(0.0) { $0 + EQHeadroomPredictor.response($1, sampleRate: rate, frequency: f).power }
                / Double(lanes.count)
            total += weight * eq
        }
        return total
    }

    /// 10 log10 of the power ratio a:b, in dB. Positive when `a` is louder.
    static func differenceDB(
        _ a: StereoEQConfiguration, _ b: StereoEQConfiguration, rate: Double
    ) -> Double {
        let pa = power(configuration: a, rate: rate), pb = power(configuration: b, rate: rate)
        guard pa > 0, pb > 0 else { return 0 }
        return 10 * log10(pa / pb)
    }
}

/// Keeps the A/B state for the Equalizer page. Created by the profile controller; inert (every
/// call is a no-op) unless `isAvailable`, which is the `e27.eq-safety` flag decided at launch.
@MainActor
final class EQComparisonController: ObservableObject {
    @Published private(set) var slots: EQComparisonSlots
    /// True from the first toggle until Keep or a reset.
    @Published private(set) var isComparing = false
    @Published private(set) var loudnessMatchEnabled = false
    /// The trim, in dB (zero or negative), currently taken off the louder slot.
    @Published private(set) var matchTrimDB = 0.0

    let isAvailable: Bool
    /// Wired by the content A/B controller: true while a content A/B session is open.
    var contentABActive: () -> Bool = { false }
    private let engine: AudioIOEngine
    private let autoPreamp: EQAutoPreampController
    private let audition: EQAuditionController?
    private var savedSteps: [EQComparisonSlot: EQEditHistory.SlotSteps] = [:]
    /// What the engine's preamp held before the match trim was applied, when auto preamp is off.
    private var appliedManualTrimDB = 0.0
    private var observation: AnyCancellable?

    init(
        engine: AudioIOEngine, autoPreamp: EQAutoPreampController,
        audition: EQAuditionController? = nil, isAvailable: Bool
    ) {
        self.engine = engine
        self.autoPreamp = autoPreamp
        self.audition = audition
        self.isAvailable = isAvailable
        slots = EQComparisonSlots(live: engine.stereoEQConfiguration)
        observation = engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.liveChanged() } }
    }

    var activeSlot: EQComparisonSlot { slots.active }
    private var rate: Double { engine.selectedOutputDevice?.nominalSampleRate ?? 48_000 }

    enum Refusal: Error, LocalizedError {
        case contentABActive
        var errorDescription: String? {
            "Finish the content A/B comparison before comparing EQ slots."
        }
    }

    /// Follows edits to the live EQ (the page, undo, Room Correction): they belong to the active
    /// slot. A profile switch calls `reset()` instead.
    func liveChanged() {
        guard isAvailable, isComparing else { return }
        let live = engine.stereoEQConfiguration
        guard !Self.sameIgnoringBypass(live, slots.configuration(slots.active)) else { return }
        slots.updateActive(from: live)
        reconcileMatch()
    }

    static func sameIgnoringBypass(_ x: StereoEQConfiguration, _ y: StereoEQConfiguration) -> Bool {
        var a = x, b = y
        a.bypassed = false; b.bypassed = false
        a.editChannel = .linked; b.editChannel = .linked
        return a == b
    }

    /// Switches to the other slot.
    func toggle(history: EQEditHistory?) throws { try select(slots.active.other, history: history) }

    func select(_ slot: EQComparisonSlot, history: EQEditHistory?) throws {
        guard isAvailable else { return }
        if !isComparing, contentABActive() { throw Refusal.contentABActive }
        audition?.stop()
        if isComparing, slot == slots.active { return }
        let live = engine.stereoEQConfiguration
        if !isComparing { slots = EQComparisonSlots(live: live) }
        let leaving = slots.active
        savedSteps[leaving] = history?.detachSteps()
        let target = slots.switchTo(slot, live: live)
        isComparing = true
        do {
            try engine.replaceStereoEQConfiguration(target)
        } catch {
            _ = slots.switchTo(leaving, live: live)
            if let steps = savedSteps[leaving] { history?.attachSteps(steps) }
            throw error
        }
        history?.attachSteps(savedSteps[slot] ?? EQEditHistory.SlotSteps())
        reconcileMatch()
    }

    func copy(from source: EQComparisonSlot) throws {
        guard isAvailable, isComparing else { return }
        if let publish = slots.copy(from: source, live: engine.stereoEQConfiguration) {
            try engine.replaceStereoEQConfiguration(publish)
        }
        reconcileMatch()
    }

    /// Keeps `slot`: it becomes the EQ, the other slot is dropped and the comparison ends.
    func keep(_ slot: EQComparisonSlot, history: EQEditHistory?) throws {
        guard isAvailable, isComparing else { return }
        if slot != slots.active { try select(slot, history: history) }
        let live = engine.stereoEQConfiguration
        slots = EQComparisonSlots(live: live)
        savedSteps.removeAll()
        isComparing = false
        reconcileMatch()
    }

    func setLoudnessMatch(_ enabled: Bool) {
        guard isAvailable, loudnessMatchEnabled != enabled else { return }
        loudnessMatchEnabled = enabled
        reconcileMatch()
    }

    /// Ends the comparison without changing the EQ (profile switch, page edit by someone else).
    func reset() {
        guard isComparing || matchTrimDB != 0 else { return }
        slots = EQComparisonSlots(live: engine.stereoEQConfiguration)
        savedSteps.removeAll()
        isComparing = false
        reconcileMatch()
    }

    /// The trim the louder slot needs: negative when the active slot is the louder one.
    func desiredTrimDB() -> Double {
        guard isComparing, loudnessMatchEnabled else { return 0 }
        let difference = EQLoudnessMatch.differenceDB(
            slots.configuration(slots.active), slots.configuration(slots.active.other), rate: rate)
        return difference > 0 ? -difference : 0
    }

    /// Applies the match trim: through the auto-preamp rule when it is active, otherwise as a
    /// delta on the engine's preamp that leaves the user's own edits in place.
    private func reconcileMatch() {
        let desired = desiredTrimDB()
        guard abs(desired - matchTrimDB) > 1e-6 else { return }
        matchTrimDB = desired
        if autoPreamp.isActive {
            autoPreamp.setMatchAttenuation(-desired)
            return
        }
        autoPreamp.setMatchAttenuation(0)
        let range = DSPGainConfiguration.inputPreampRange
        let current = engine.gainConfiguration.inputPreampDB
        let target = min(max(current - appliedManualTrimDB + desired, range.lowerBound), range.upperBound)
        appliedManualTrimDB = desired
        try? engine.setInputPreampDB(target)
    }
}
