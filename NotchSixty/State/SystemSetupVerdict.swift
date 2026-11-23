import Foundation

// E12 S11: one plain verdict per measured seat, and the correction limit that applies when the microphone has no
// calibration file. Pure functions over the existing measurement quality record; control plane only, nothing here runs
// on an audio thread. Active only under `e12.setup-flow` (the model decides; these types do not read flags).

/// How far a measurement can be trusted. Ordered best to worst so the worst of several checks wins.
enum MeasurementVerdictLevel: Int, Codable, Comparable, CaseIterable, Sendable {
    case good, usable, limited, measureAgain

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .good: "Good"
        case .usable: "Usable"
        case .limited: "Limited"
        case .measureAgain: "Measure again"
        }
    }
}

struct MeasurementVerdict: Codable, Equatable, Sendable {
    var level: MeasurementVerdictLevel
    /// One line saying why.
    var reason: String
}

/// A seat's verdict as the flow stores it.
struct SeatMeasurementVerdict: Codable, Equatable, Sendable, Identifiable {
    var seatName: String
    var verdict: MeasurementVerdict
    var id: String { seatName }
}

enum MeasurementVerdictRules {
    /// Sweep-to-noise ratio (dB) below which a measurement is refused, limited, or only usable.
    static let snrRefuseDB = 20.0, snrLimitedDB = 30.0, snrUsableDB = 40.0
    /// Capture peak (dBFS): below the first the sweep is lost in the noise; above the last it is close to clipping.
    static let peakRefuseDBFS = -50.0, peakLimitedDBFS = -40.0, peakHotDBFS = -3.0
    /// Clock drift between the microphone and the output (parts per million).
    static let driftLimitedPPM = 200.0, driftUsablePPM = 50.0

    /// The verdict for one channel measurement: the worst of the individual checks, with that check's reason.
    static func verdict(for quality: RoomCorrectionMeasurementQuality) -> MeasurementVerdict {
        var worst = MeasurementVerdict(level: .good, reason: "Clean sweep with plenty of signal above the noise.")
        func consider(_ level: MeasurementVerdictLevel, _ reason: @autoclosure () -> String) {
            if level > worst.level { worst = MeasurementVerdict(level: level, reason: reason()) }
        }
        if !quality.sweepComplete {
            consider(.measureAgain, "The sweep did not finish, so part of it is missing.")
        }
        if quality.clipped {
            consider(.measureAgain, "The microphone clipped. Lower the sweep level or the microphone gain.")
        }
        if let total = quality.repeatCount, total > 1 {
            let kept = total - (quality.rejectedRepeats ?? []).count
            if kept * 2 < total {
                consider(.measureAgain, "Only \(kept) of \(total) repeats agreed. Hold the microphone still and keep the room quiet.")
            } else if kept * 4 < total * 3 {
                consider(.limited, "\(kept) of \(total) repeats agreed; the others were left out.")
            } else if kept < total {
                consider(.usable, "\(kept) of \(total) repeats agreed; the others were left out.")
            }
        }
        if let snr = quality.estimatedSNRDB {
            let text = String(format: "%.0f", snr)
            if snr < snrRefuseDB {
                consider(.measureAgain, "Too much noise: the sweep is only \(text) dB above it.")
            } else if snr < snrLimitedDB {
                consider(.limited, "Noisy room: the sweep is \(text) dB above the noise.")
            } else if snr < snrUsableDB {
                consider(.usable, "The sweep is \(text) dB above the noise; a quieter room would help.")
            }
        }
        if let peak = quality.capturePeakDBFS {
            if peak < peakRefuseDBFS {
                consider(.measureAgain, "The signal is far too quiet. Raise the sweep level or move the microphone closer.")
            } else if peak < peakLimitedDBFS {
                consider(.limited, "The signal is quiet. Raise the sweep level a little.")
            } else if peak > peakHotDBFS {
                consider(.limited, "The signal is very close to clipping. Lower the sweep level a little.")
            }
        }
        if let drift = quality.driftPPM {
            if abs(drift) > driftLimitedPPM {
                consider(.limited, "The microphone clock drifted by \(String(format: "%.0f", abs(drift))) ppm during the sweep.")
            } else if abs(drift) > driftUsablePPM {
                consider(.usable, "The microphone clock drifted slightly during the sweep.")
            }
        }
        return worst
    }

    /// The worst verdict over every source measured at one seat; the reason names the speaker when there are several.
    static func verdict(forSeat measurements: [(source: String, quality: RoomCorrectionMeasurementQuality)]) -> MeasurementVerdict? {
        var worst: (source: String, verdict: MeasurementVerdict)?
        for entry in measurements {
            let verdict = verdict(for: entry.quality)
            if let current = worst, current.verdict.level >= verdict.level { continue }
            worst = (entry.source, verdict)
        }
        guard let worst else { return nil }
        if measurements.count > 1, worst.verdict.level != .good {
            return MeasurementVerdict(level: worst.verdict.level, reason: "\(worst.source): \(worst.verdict.reason)")
        }
        return worst.verdict
    }

    /// Why a set of seat verdicts blocks the flow, or nil when none says Measure again.
    static func blockingReason(_ verdicts: [SeatMeasurementVerdict]?) -> String? {
        guard let bad = verdicts?.first(where: { $0.verdict.level == .measureAgain }) else { return nil }
        return "\(bad.seatName): Measure again. \(bad.verdict.reason)"
    }
}

/// Without a calibration file the microphone's own response is unknown, so correction stays in the bass range.
enum SystemSetupCorrectionLimit {
    static let defaultHz = 300.0
    static let overrideRangeHz = 60.0...1_000.0
    /// The correction fades to nothing over this many octaves, ending exactly at the limit.
    static let taperOctaves = 1.0 / 3.0

    /// The upper edge of correction, or nil when a calibration file lifts the limit. `overrideHz` is the expert setting.
    static func limitHz(calibrationFile: String?, overrideHz: Double? = nil) -> Double? {
        if let file = calibrationFile, !file.isEmpty { return nil }
        guard let overrideHz, overrideHz.isFinite else { return defaultHz }
        return min(overrideRangeHz.upperBound, max(overrideRangeHz.lowerBound, overrideHz))
    }

    static func note(limitHz: Double?) -> String {
        guard let limitHz else { return "A calibration file is loaded, so correction covers the full range." }
        return "No calibration file, so correction stops at \(Int(limitHz.rounded())) Hz. A built-in or uncalibrated microphone is not trustworthy above that. Load a calibration file to lift the limit."
    }

    /// Fades a designed correction (magnitude and phase) to zero above `limitHz`, in place. Full strength below
    /// `limitHz / 2^taperOctaves`; exactly zero from `limitHz` up.
    static func apply(to design: inout RoomCorrectionGridDesign, frequenciesHz: [Double], limitHz: Double) {
        let start = limitHz / pow(2, taperOctaves)
        for index in design.correctionDB.indices where index < frequenciesHz.count {
            let f = frequenciesHz[index]
            if f <= start { continue }
            let weight: Double
            if f >= limitHz {
                weight = 0
            } else {
                let t = log2(f / start) / taperOctaves
                weight = 0.5 * (1 + cos(Double.pi * t))
            }
            design.correctionDB[index] *= weight
            if index < design.correctionPhaseRadians.count { design.correctionPhaseRadians[index] *= weight }
        }
    }
}
