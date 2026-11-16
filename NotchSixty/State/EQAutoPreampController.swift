import Combine
import Foundation

/// E27 S3a: keeps the engine's input preamp at `trim - predicted EQ boost` while auto preamp is
/// on, whoever edits the EQ (the page, undo, a profile switch, Room Correction).
///
/// The toggle and trim are plain stored values that travel with the content profile.
///
/// Threading: main actor only; it publishes through the normal gain setter, so the engine
/// reads no flag and gains no new realtime state. A reconcile runs one main-queue hop after an
/// EQ change (the engine publishes the EQ first, then the gain).
@MainActor
final class EQAutoPreampController: ObservableObject {
    /// E33 S3: the one preamp model. Stored toggle and trim (the manual term) live there.
    let preamp: EQPreampModel
    /// Stored toggle, as saved in the profile.
    var isOn: Bool { preamp.autoOn }
    /// Stored trim (the manual term), as saved in the profile.
    var trimDB: Double { preamp.manualDB }
    /// The last prediction, for the badge.
    @Published private(set) var prediction = EQHeadroomPrediction.none

    /// E27 S3b: extra attenuation, in dB (zero or positive), from the A/B loudness match.
    var matchAttenuationDB: Double { -preamp.matchDB }

    /// E32 S1: why the last automatic preamp change failed; nil when it applied. The page shows it.
    @Published private(set) var lastError: String?

    private let engine: AudioIOEngine
    /// Writes the input preamp. The engine's setter in production; tests inject a failing one.
    var preampWriter: (Double) throws -> Void {
        get { preamp.writer }
        set { preamp.writer = newValue }
    }
    private var preampSink: AnyCancellable?
    private var observation: ObservationSubscription?
    private var cacheKey: (configuration: StereoEQConfiguration, sampleRate: Double)?

    init(engine: AudioIOEngine) {
        self.engine = engine
        preamp = EQPreampModel(engine: engine)
        preampSink = preamp.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        refreshPrediction()
        observation = ObservationSubscription(
            track: { [engine] in
                _ = engine.stereoEQConfiguration
                _ = engine.gainConfiguration
                _ = engine.selectedOutputDevice
            },
            onChange: { [weak self] in self?.reconcile() }
        )
    }

    /// True when the controller is driving the preamp.
    var isActive: Bool { isOn }

    /// The output sample rate the prediction uses.
    var sampleRate: Double { engine.selectedOutputDevice?.nominalSampleRate ?? 48_000 }

    /// The preamp the rule asks for now.
    var targetPreampDB: Double {
        EQPreampModel.total(manualDB: preamp.manualDB, autoTrimDB: -autoAttenuationDB, matchDB: preamp.matchDB)
    }

    private var autoAttenuationDB: Double { EQAutoPreamp.attenuationDB(forBoost: prediction.boostDB) }

    /// Sets the loudness-match attenuation; the total follows at once. Failures are surfaced as `lastError`.
    func setMatchAttenuation(_ value: Double) {
        do {
            try applyMatch(trimDB: -max(0, value.isFinite ? value : 0))
            if lastError != nil { lastError = nil }
        } catch {
            lastError = "Auto preamp could not set the input preamp: \(error.localizedDescription)"
        }
    }

    /// The A/B loudness match (zero or negative dB) as the model's match term; one publish.
    func applyMatch(trimDB: Double) throws {
        preamp.adoptOutsideWrite()
        try preamp.setMatch(trimDB)
    }

    /// Sets the manual term (the page's preamp control); one publish of the total.
    func setManual(_ value: Double) throws {
        preamp.adoptOutsideWrite()
        try preamp.setManual(value)
    }

    /// Turns the rule on or off. On: the current preamp becomes the trim. Off: the preamp returns
    /// to the trim, so switching it off undoes the compensation.
    func setOn(_ on: Bool) throws {
        guard on != isOn else { return }
        preamp.adoptOutsideWrite()
        refreshPrediction()
        try preamp.setAuto(on: on, trimDB: -autoAttenuationDB)
    }

    /// Edits the trim; while the rule is active the preamp follows at once.
    func setTrim(_ value: Double) throws {
        try setManual(value)
    }

    /// Sets the stored values from a profile or a rollback. Does not touch the engine: the
    /// profile's own preamp value is applied with the rest of the content state.
    func restore(isOn: Bool, trimDB: Double) {
        preamp.restore(manualDB: trimDB, autoOn: isOn)
    }

    /// Brings the preamp to the target if it is not there (idempotent).
    func reconcile() {
        do {
            try reconcileThrowing()
            if lastError != nil { lastError = nil }
        } catch {
            lastError = "Auto preamp could not set the input preamp: \(error.localizedDescription)"
        }
    }

    private func reconcileThrowing() throws {
        preamp.adoptOutsideWrite()
        refreshPrediction()
        guard isActive else { return }
        try preamp.setAutoTrim(-autoAttenuationDB)
    }

    /// Shared with the Equalizer page by default; a test passes its own.
    var responseCache = EQResponseCache.shared

    private func refreshPrediction() {
        let configuration = engine.stereoEQConfiguration
        let rate = sampleRate
        if let cacheKey, cacheKey.sampleRate == rate, cacheKey.configuration == configuration { return }
        cacheKey = (configuration, rate)
        prediction = EQHeadroomPredictor.predict(configuration: configuration, sampleRate: rate) { bands, rate in
            self.responseCache.program(bands: bands, sampleRate: rate)
        }
    }
}
