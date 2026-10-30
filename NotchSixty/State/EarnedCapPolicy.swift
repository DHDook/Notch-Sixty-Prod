import Foundation

/// E4 S20: where an earned anti-noise cap applies. Output, microphone and nominal rate are the key;
/// the output gain is checked against the stored value with the S12 tolerance.
struct EarnedCapBinding: Codable, Hashable, Sendable {
    var outputDeviceUID: String
    var inputDeviceUID: String
    /// Nominal rate, rounded to the nearest hertz.
    var sampleRate: Int

    init(outputDeviceUID: String, inputDeviceUID: String, sampleRate: Double) {
        self.outputDeviceUID = outputDeviceUID
        self.inputDeviceUID = inputDeviceUID
        self.sampleRate = Int(sampleRate.rounded())
    }
}

struct EarnedCapRecord: Codable, Equatable, Sendable {
    var binding: EarnedCapBinding
    var earnedDBFS: Double
    var outputGainDB: Double
    var earnedAt: Date
}

/// Earned levels, kept across launches. UserDefaults JSON, at most 32 records; the one written
/// longest ago is dropped first. Main actor only; the realtime path never touches it.
final class EarnedCapStore {
    static let maximumRecords = 32
    private let defaults: UserDefaults
    private(set) var records: [EarnedCapRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: PreferenceKeys.quietZoneEarnedCaps)
        records = data.flatMap { try? JSONDecoder().decode([EarnedCapRecord].self, from: $0) } ?? []
        records = records.filter { $0.earnedDBFS.isFinite && $0.outputGainDB.isFinite }
    }

    func record(for binding: EarnedCapBinding) -> EarnedCapRecord? {
        records.first { $0.binding == binding }
    }

    func save(_ record: EarnedCapRecord) {
        records.removeAll { $0.binding == record.binding }
        records.append(record)
        if records.count > Self.maximumRecords { records.removeFirst(records.count - Self.maximumRecords) }
        persist()
    }

    func remove(_ binding: EarnedCapBinding) {
        guard records.contains(where: { $0.binding == binding }) else { return }
        records.removeAll { $0.binding == binding }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: PreferenceKeys.quietZoneEarnedCaps)
        }
    }
}

/// What the policy needs to know about one poll.
struct EarnedCapPollFacts: Sendable {
    var now: TimeInterval
    /// The S18 gate is open and the core is adapting, with no re-solve running.
    var adapting: Bool
    var verdict: DoNoHarmVerdict
    var measurement: DoNoHarmVerifier.Measurement?
    /// An S15 or worker guard trip, or an S21 thermal hold, is in force.
    var guardOrHold: Bool
    /// Largest anti-noise sample played over the last window (linear).
    var playedPeakLinear: Double
    /// A microphone-move recovery (re-solve, ramp-in, step-back) is in progress.
    var moveRecovering: Bool
}

/// E4 S20: the anti-noise cap earned by trust. One owner of the cap in force: starts at -40 dBFS,
/// rises 3 dB after each 60 s of stable improvement while the cap is what limits the reduction,
/// and never passes -18 dBFS. Control plane only (main actor); deterministic given its inputs.
@MainActor
final class EarnedCapPolicy {
    static let floorDBFS = LiveTreatmentSafeguards.defaultPeakCapDBFS
    static let ceilingDBFS = LiveTreatmentSafeguards.hardMaximumPeakCapDBFS
    static let stepDB = 3.0
    static let setTimeSeconds = 60.0
    static let minimumReductionDB = 3.0
    static let maximumIncreaseDB = 0.5
    /// The played peak must be within this of the cap for the cap to be what limits the reduction.
    static let capLimitedWithinDB = 1.0

    private let store: EarnedCapStore
    /// The earned level in force, dBFS.
    private(set) var capDBFS = EarnedCapPolicy.floorDBFS
    private(set) var binding: EarnedCapBinding?
    private var armedGainDB = 0.0
    private var qualifyingSince: TimeInterval?
    private var wasRecovering = false
    var onEvent: ((SafetyEventKind, String) -> Void)?

    init(store: EarnedCapStore) {
        self.store = store
    }

    var capLinear: Double { LiveTreatmentSafeguards.linearPeak(dbfs: capDBFS) }

    var statusText: String {
        let level = Int(capDBFS.rounded())
        return capDBFS <= Self.floorDBFS + 0.01 ? "Anti-noise limit \(level) dBFS" : "Anti-noise limit \(level) dBFS (earned)"
    }

    /// Starts a new arm: the stored level when the key matches and the gain is within the S12
    /// tolerance, otherwise -40 dBFS.
    func beginArm(binding: EarnedCapBinding, outputGainDB: Double) {
        self.binding = binding
        armedGainDB = outputGainDB
        qualifyingSince = nil
        wasRecovering = false
        if let stored = store.record(for: binding),
           abs(stored.outputGainDB - outputGainDB) <= LiveTreatmentSafeguards.outputGainToleranceDB {
            capDBFS = Self.clamp(stored.earnedDBFS)
            if capDBFS > Self.floorDBFS { onEvent?(.cap, "Anti-noise limit restored to \(Int(capDBFS.rounded())) dBFS for this setup.") }
        } else {
            capDBFS = Self.floorDBFS
        }
    }

    /// Any change the arm switch would see makes the cap in force -40 dBFS at once. The stored
    /// record is kept: a returning binding restores it at its next arm.
    func observe(binding current: EarnedCapBinding?, outputGainDB: Double) {
        guard let armed = binding else { return }
        let changed = current != armed || abs(outputGainDB - armedGainDB) > LiveTreatmentSafeguards.outputGainToleranceDB
        if changed {
            if capDBFS > Self.floorDBFS { onEvent?(.cap, "Setup changed: anti-noise limit back to \(Int(Self.floorDBFS)) dBFS.") }
            capDBFS = Self.floorDBFS
            qualifyingSince = nil
        }
    }

    /// Applies the reset rules when an arm ends.
    func noteDisarm(_ reason: LiveTreatmentDisarmReason) {
        defer { binding = nil; qualifyingSince = nil; wasRecovering = false }
        guard let binding else { return }
        switch reason {
        case .seatRegression, .instabilityTrip:
            store.remove(binding)
            onEvent?(.cap, "Anti-noise limit reset to \(Int(Self.floorDBFS)) dBFS after \(reason.rawValue).")
        case .adaptiveFault, .microphoneMoved:
            let lowered = Self.clamp(capDBFS - Self.stepDB)
            if lowered <= Self.floorDBFS {
                store.remove(binding)
            } else if store.record(for: binding) != nil {
                store.save(EarnedCapRecord(binding: binding, earnedDBFS: lowered, outputGainDB: armedGainDB, earnedAt: Date()))
            }
            onEvent?(.cap, "Anti-noise limit lowered one step after \(reason.rawValue).")
        default:
            break
        }
        capDBFS = Self.floorDBFS
    }

    /// One poll. Returns true when the cap rose.
    @discardableResult
    func poll(_ facts: EarnedCapPollFacts) -> Bool {
        guard binding != nil else { return false }
        if facts.moveRecovering {
            wasRecovering = true
            qualifyingSince = nil
            return false
        }
        if wasRecovering {
            // Back at the pre-move level: the set time starts again from zero.
            wasRecovering = false
            qualifyingSince = nil
            onEvent?(.cap, "Anti-noise limit back at \(Int(capDBFS.rounded())) dBFS after the move.")
        }
        guard capDBFS < Self.ceilingDBFS else { qualifyingSince = nil; return false }
        guard qualifies(facts) else { qualifyingSince = nil; return false }
        let since = qualifyingSince ?? facts.now
        qualifyingSince = since
        guard facts.now - since >= Self.setTimeSeconds else { return false }
        capDBFS = Self.clamp(capDBFS + Self.stepDB)
        qualifyingSince = nil
        if let binding {
            store.save(EarnedCapRecord(binding: binding, earnedDBFS: capDBFS, outputGainDB: armedGainDB, earnedAt: Date()))
        }
        onEvent?(.cap, "Anti-noise limit earned: \(Int(capDBFS.rounded())) dBFS.")
        return true
    }

    private func qualifies(_ facts: EarnedCapPollFacts) -> Bool {
        guard facts.adapting, !facts.guardOrHold, facts.verdict == .ok,
              let measurement = facts.measurement,
              let reduction = measurement.minimumToneReductionDB,
              reduction >= Self.minimumReductionDB,
              measurement.worstIncreaseDB <= Self.maximumIncreaseDB else { return false }
        let floorLinear = capLinear * LiveTreatmentSafeguards.linearPeak(dbfs: -Self.capLimitedWithinDB)
        return facts.playedPeakLinear >= floorLinear
    }

    private static func clamp(_ dbfs: Double) -> Double {
        guard dbfs.isFinite else { return floorDBFS }
        return min(max(dbfs, floorDBFS), ceilingDBFS)
    }
}
