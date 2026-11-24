import Foundation

// E12 S31 (decision 33, G62): the automatic level for the guided setup's Level step. A pure decision step: the model
// reads the meter, asks what to do, and applies the answer through the same `SystemSetupLevelPlan` the manual Raise
// uses, so the start level, the LFE start level and the ceiling are the plan's and nothing here can pass them.

struct SystemSetupAutoLevel: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        /// No usable reading yet; look again after the next pause.
        case wait
        /// Raise the noise by this many dB, then look again.
        case raise(byDB: Double)
        /// The meter reads the target (or is above it); stop raising.
        case finished(String)
        /// Stop and say why.
        case stopped(String)
    }

    /// How close to the target counts as reached.
    static let toleranceDB = 1.0
    /// The smallest step; the largest is the plan's manual step.
    static let minimumStepDB = 1.0
    /// A raise must lift the reading by at least this share of the step, or the reading is not following the level.
    static let requiredRiseShare = 0.4
    /// Looks without a reading before giving up.
    static let maximumEmptyLooks = 4

    private var emptyLooks = 0
    private var pendingReading: Double?
    private var pendingStepDB = 0.0

    /// `levelDB` and `atCeiling` come from the level plan, `reading` from the C-weighted meter.
    mutating func decide(
        reading: Double?, atCeiling: Bool, target: Double = SystemSetupLevelPlan.targetSPLdBC
    ) -> Decision {
        guard let reading, reading.isFinite else {
            emptyLooks += 1
            if emptyLooks >= Self.maximumEmptyLooks {
                return .stopped("The meter shows no reading. Check the microphone, then try again or raise the level by hand.")
            }
            return .wait
        }
        emptyLooks = 0
        if reading >= target - Self.toleranceDB {
            let note = reading > target + Self.toleranceDB
                ? "The level is already above the target. Use Lower if it is too loud."
                : "The level reads about \(Int(target)) dB(C). Use it for the sweep when you are ready."
            return .finished(note)
        }
        if atCeiling {
            return .stopped("The noise reached its top level before the meter reached the target. Move the microphone closer or raise the level on the amplifier.")
        }
        if let last = pendingReading, reading < last + pendingStepDB * Self.requiredRiseShare {
            return .stopped("The reading did not rise when the noise was raised. Check that the microphone hears the speakers, then try again or raise the level by hand.")
        }
        let step = min(SystemSetupLevelPlan.rampStepDB, max(Self.minimumStepDB, target - reading))
        pendingReading = reading
        pendingStepDB = step
        return .raise(byDB: step)
    }
}
