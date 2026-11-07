import Combine
import Foundation

/// E27 S3a: keeps the engine's input preamp at `trim - predicted EQ boost` while auto preamp is
/// on, whoever edits the EQ (the page, undo, a profile switch, Room Correction).
///
/// The toggle and trim are plain stored values that travel with the content profile. They only
/// act when `isAvailable` (the `e27.eq-safety` flag, decided by Swift at launch): with the flag
/// off the controller never writes a gain, so a profile saved with auto preamp on loads inert.
///
/// Threading: main actor only; it publishes through the normal gain setter, so the engine
/// reads no flag and gains no new realtime state. A reconcile runs one main-queue hop after an
/// EQ change (the engine publishes the EQ first, then the gain).
@MainActor
final class EQAutoPreampController: ObservableObject {
    /// Stored toggle and trim, as saved in the profile.
    @Published private(set) var isOn = false
    @Published private(set) var trimDB = 0.0
    /// The last prediction, for the badge.
    @Published private(set) var prediction = EQHeadroomPrediction.none

    /// E27 S3b: extra attenuation, in dB (zero or positive), from the A/B loudness match.
    @Published private(set) var matchAttenuationDB = 0.0

    let isAvailable: Bool
    private let engine: AudioIOEngine
    private var observation: AnyCancellable?
    private var cacheKey: (configuration: StereoEQConfiguration, sampleRate: Double)?

    init(engine: AudioIOEngine, isAvailable: Bool) {
        self.engine = engine
        self.isAvailable = isAvailable
        refreshPrediction()
        observation = engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
    }

    /// True when the controller is allowed to drive the preamp.
    var isActive: Bool { isAvailable && isOn }

    /// The output sample rate the prediction uses.
    var sampleRate: Double { engine.selectedOutputDevice?.nominalSampleRate ?? 48_000 }

    /// The preamp the rule asks for now.
    var targetPreampDB: Double {
        let range = DSPGainConfiguration.inputPreampRange
        let base = EQAutoPreamp.preampDB(trimDB: trimDB, boostDB: prediction.boostDB)
        return min(max(base - matchAttenuationDB, range.lowerBound), range.upperBound)
    }

    /// Sets the loudness-match attenuation; while the rule is active the preamp follows at once.
    func setMatchAttenuation(_ value: Double) {
        let clamped = max(0, value.isFinite ? value : 0)
        guard clamped != matchAttenuationDB else { return }
        matchAttenuationDB = clamped
        if isActive { reconcile() }
    }

    /// Turns the rule on or off. On: the current preamp becomes the trim. Off: the preamp returns
    /// to the trim, so switching it off undoes the compensation.
    func setOn(_ on: Bool) throws {
        guard on != isOn else { return }
        if on {
            trimDB = engine.gainConfiguration.inputPreampDB
            isOn = true
            try reconcileThrowing()
        } else {
            isOn = false
            if isAvailable { try engine.setInputPreampDB(clampedTrim) }
        }
    }

    /// Edits the trim; while the rule is active the preamp follows at once.
    func setTrim(_ value: Double) throws {
        let range = DSPGainConfiguration.inputPreampRange
        trimDB = min(max(value, range.lowerBound), range.upperBound)
        if isActive { try reconcileThrowing() }
    }

    /// Sets the stored values from a profile or a rollback. Does not touch the engine: the
    /// profile's own preamp value is applied with the rest of the content state.
    func restore(isOn: Bool, trimDB: Double) {
        self.isOn = isOn
        self.trimDB = trimDB.isFinite ? trimDB : 0
    }

    /// Brings the preamp to the target if it is not there (idempotent).
    func reconcile() {
        try? reconcileThrowing()
    }

    private var clampedTrim: Double {
        let range = DSPGainConfiguration.inputPreampRange
        return min(max(trimDB, range.lowerBound), range.upperBound)
    }

    private func reconcileThrowing() throws {
        refreshPrediction()
        guard isActive else { return }
        let target = targetPreampDB
        guard abs(target - engine.gainConfiguration.inputPreampDB) > 1e-9 else { return }
        try engine.setInputPreampDB(target)
    }

    private func refreshPrediction() {
        let configuration = engine.stereoEQConfiguration
        let rate = sampleRate
        if let cacheKey, cacheKey.sampleRate == rate, cacheKey.configuration == configuration { return }
        cacheKey = (configuration, rate)
        prediction = EQHeadroomPredictor.predict(configuration: configuration, sampleRate: rate)
    }
}
