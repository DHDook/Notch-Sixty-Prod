import Combine
import Foundation

/// E33 S3 (design 6): the one model of the Equalizer's input preamp. The engine's input preamp is
/// the clamped sum of three terms:
///
/// - `manualDB`: the user's own level. Stored in the profile (as the trim while auto preamp is on).
/// - `autoTrimDB`: zero or negative; the auto-preamp rule's attenuation for the EQ's predicted boost
///   (E27 decision 5). Zero while auto preamp is off.
/// - `matchDB`: zero or negative; the A/B loudness-match trim (E27 decision 4). Session-only.
///
/// This is the only writer of `setInputPreampDB` for the page, `EQAutoPreampController` and
/// `EQComparisonController`. Every change to a term publishes the new total at most once, through the
/// normal gain setter; the engine reads no flag and gains no state. Main actor only.
@MainActor
final class EQPreampModel: ObservableObject {
    @Published private(set) var manualDB = 0.0
    @Published private(set) var autoOn = false
    @Published private(set) var autoTrimDB = 0.0
    @Published private(set) var matchDB = 0.0

    /// Writes the input preamp. The engine's setter in production; tests inject a failing one.
    var writer: (Double) throws -> Void
    private let engine: AudioIOEngine
    /// The engine's preamp as this model last saw it, to tell an outside write from its own.
    private var lastSeenEngineDB: Double

    init(engine: AudioIOEngine) {
        self.engine = engine
        writer = { [engine] in try engine.setInputPreampDB($0) }
        lastSeenEngineDB = engine.gainConfiguration.inputPreampDB
        manualDB = lastSeenEngineDB
    }

    /// The clamped sum of the three terms.
    static func total(manualDB: Double, autoTrimDB: Double, matchDB: Double) -> Double {
        let range = DSPGainConfiguration.inputPreampRange
        let sum = manualDB + autoTrimDB + matchDB
        guard sum.isFinite else { return 0 }
        return min(max(sum, range.lowerBound), range.upperBound)
    }

    var totalDB: Double { Self.total(manualDB: manualDB, autoTrimDB: autoTrimDB, matchDB: matchDB) }

    /// Follows a write made outside the model (the old gain panel, a profile or an import) while auto
    /// preamp is off: the engine's value minus the match trim becomes the manual term. While auto is on
    /// the rule owns the value and the next reconcile puts it back.
    func adoptOutsideWrite() {
        let current = engine.gainConfiguration.inputPreampDB
        guard current != lastSeenEngineDB else { return }
        lastSeenEngineDB = current
        guard !autoOn, abs(current - totalDB) > 1e-9 else { return }
        manualDB = clampedManual(current - matchDB)
    }

    func setManual(_ value: Double) throws {
        manualDB = clampedManual(value)
        try publish()
    }

    func setAuto(on: Bool, trimDB: Double) throws {
        autoOn = on
        autoTrimDB = on ? min(0, trimDB.isFinite ? trimDB : 0) : 0
        try publish()
    }

    func setAutoTrim(_ trimDB: Double) throws {
        guard autoOn else { return }
        autoTrimDB = min(0, trimDB.isFinite ? trimDB : 0)
        try publish()
    }

    func setMatch(_ value: Double) throws {
        matchDB = min(0, value.isFinite ? value : 0)
        try publish()
    }

    /// Sets the stored terms from a profile or a rollback without touching the engine: the profile's
    /// own gain is applied with the rest of the content state.
    func restore(manualDB: Double, autoOn: Bool) {
        self.manualDB = clampedManual(manualDB.isFinite ? manualDB : 0)
        self.autoOn = autoOn
        if !autoOn { autoTrimDB = 0 }
    }

    /// Writes the total when the engine is not already there (idempotent: one write per change).
    private func publish() throws {
        let target = totalDB
        let current = engine.gainConfiguration.inputPreampDB
        guard abs(target - current) > 1e-9 else { lastSeenEngineDB = current; return }
        try writer(target)
        lastSeenEngineDB = engine.gainConfiguration.inputPreampDB
    }

    private func clampedManual(_ value: Double) -> Double {
        let range = DSPGainConfiguration.inputPreampRange
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
