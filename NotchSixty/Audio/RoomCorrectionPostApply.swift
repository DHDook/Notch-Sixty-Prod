import Foundation

// E10 S8 (design note 9): the post-apply check of a room-correction design and the `canDeploy` gate.
// Pure value types and math here; the controller is in `RoomCorrectionDeployController.swift`.

/// Acceptance limits of design note 9.
struct RoomCorrectionPostApplyCriteria: Equatable, Codable, Sendable {
    /// 1/6-octave magnitude, measured against the prediction, after removing the mean level difference.
    var magnitudeToleranceDB = 1.5
    /// Excess group delay may exceed the prediction by this much.
    var groupDelayMarginSeconds = 0.002
    var lowHz = 30.0
    var highHz = 16_000.0
    var bandsPerOctave = 6
    /// Seconds of deconvolved impulse response analysed after the direct arrival.
    var analysisSeconds = 0.3

    /// 1/6-octave centres on the 1 kHz base inside the range, limited to 0.4 of the sample rate.
    func centres(sampleRate: Double) -> [Double] {
        let top = min(highHz, 0.4 * sampleRate)
        var result: [Double] = []
        var k = Int((log2(lowHz / 1_000) * Double(bandsPerOctave)).rounded(.up))
        while true {
            let f = 1_000 * pow(2.0, Double(k) / Double(bandsPerOctave))
            if f > top { break }
            result.append(f)
            k += 1
        }
        return result
    }
}

/// A response on the verifier's centres: smoothed magnitude and group delay (seconds).
struct RoomCorrectionBandedResponse: Equatable, Codable, Sendable {
    var centres: [Double]
    var magnitudeDB: [Double]
    var groupDelaySeconds: [Double]

    /// Largest deviation of the group delay from its median over the range.
    var excessGroupDelaySeconds: Double {
        guard !groupDelaySeconds.isEmpty else { return 0 }
        let sorted = groupDelaySeconds.sorted()
        let median = sorted[sorted.count / 2]
        return groupDelaySeconds.map { abs($0 - median) }.max() ?? 0
    }
}

enum RoomCorrectionPostApplyOutcome: String, Codable, Sendable {
    case passed, magnitudeMismatch, groupDelayMismatch, timedOut, cancelled, captureFailed, analysisFailed
}

/// The stored evidence of a post-apply check.
struct RoomCorrectionPostApplyReport: Equatable, Codable, Sendable {
    var designID: String
    var sampleRate: Double
    var outcome: RoomCorrectionPostApplyOutcome
    var detail: String
    var centres: [Double]
    var predictedDB: [Double]
    var measuredDB: [Double]
    var maxMagnitudeErrorDB: Double
    var predictedExcessGroupDelaySeconds: Double
    var measuredExcessGroupDelaySeconds: Double
    var criteria: RoomCorrectionPostApplyCriteria
    var date: Date

    var passed: Bool { outcome == .passed }
}

enum RoomCorrectionPostApplyError: Error, Equatable {
    case invalidImpulse
}

enum RoomCorrectionPostApplyVerifier {
    /// The banded response of an impulse response. `originFrame` is the direct arrival (sub-sample); the analysis window
    /// starts `preFrames` before it. Group delay is `Re{DFT[n h] / DFT[h]}` about the origin, so it needs no unwrapping.
    static func bandedResponse(
        impulse: [Float], originFrame: Double, preFrames: Int, sampleRate: Double,
        criteria: RoomCorrectionPostApplyCriteria
    ) throws -> RoomCorrectionBandedResponse {
        let start = max(0, Int(originFrame.rounded(.down)) - preFrames)
        let end = min(impulse.count, Int(originFrame) + Int(criteria.analysisSeconds * sampleRate))
        guard end - start > 16, impulse.allSatisfy({ $0.isFinite }) else { throw RoomCorrectionPostApplyError.invalidImpulse }
        let centres = criteria.centres(sampleRate: sampleRate)
        let sub = 4
        let halfBand = pow(2.0, 1.0 / Double(2 * criteria.bandsPerOctave))
        var magnitude: [Double] = []
        var delay: [Double] = []
        let count = end - start
        let times = (0..<count).map { Double(start + $0) - originFrame }
        impulse.withUnsafeBufferPointer { x in
            for centre in centres {
                var power = 0.0
                var gd = 0.0
                for j in 0..<sub {
                    let f = centre / halfBand * pow(halfBand * halfBand, (Double(j) + 0.5) / Double(sub))
                    let w = 2 * Double.pi * f / sampleRate
                    let stepRe = cos(w), stepIm = -sin(w)
                    var re = 0.0, im = 0.0, nRe = 0.0, nIm = 0.0
                    var phRe = cos(w * times[0]), phIm = -sin(w * times[0])
                    for i in 0..<count {
                        let v = Double(x[start + i])
                        re += v * phRe; im += v * phIm
                        nRe += v * times[i] * phRe; nIm += v * times[i] * phIm
                        let r = phRe * stepRe - phIm * stepIm
                        phIm = phRe * stepIm + phIm * stepRe
                        phRe = r
                    }
                    let p = re * re + im * im
                    power += p
                    if p > 0 { gd += (nRe * re + nIm * im) / p }
                }
                magnitude.append(10 * log10(max(power / Double(sub), 1e-30)))
                delay.append(gd / Double(sub) / sampleRate)
            }
        }
        return RoomCorrectionBandedResponse(centres: centres, magnitudeDB: magnitude, groupDelaySeconds: delay)
    }

    /// The prediction at the main seat: the room (its impulse response) through the published stage.
    static func prediction(
        roomImpulse: [Float], roomArrivalFrames: Double, stage: RoomCorrectionLaneStage, declaredLatencyFrames: UInt32,
        sampleRate: Double, criteria: RoomCorrectionPostApplyCriteria
    ) throws -> RoomCorrectionBandedResponse {
        let room = try bandedResponse(
            impulse: roomImpulse, originFrame: roomArrivalFrames, preFrames: 0, sampleRate: sampleRate, criteria: criteria)
        let centres = room.centres
        let eps = 0.002
        let lower = centres.map { $0 * (1 - eps) }, upper = centres.map { $0 * (1 + eps) }
        let both = try RoomCorrectionCore.filterResponse(
            sampleRate: sampleRate, taps: stage.taps, twoBand: stage.twoBand, declaredLatencyFrames: declaredLatencyFrames,
            frequencies: centres + lower + upper)
        let n = centres.count
        var magnitude: [Double] = [], delay: [Double] = []
        for i in 0..<n {
            magnitude.append(room.magnitudeDB[i] + both.magnitudeDB[i])
            var dphi = both.phaseRadians[2 * n + i] - both.phaseRadians[n + i]
            dphi = atan2(sin(dphi), cos(dphi))
            let filterDelay = -dphi / (2 * Double.pi * (upper[i] - lower[i]))
            delay.append(room.groupDelaySeconds[i] + filterDelay)
        }
        return RoomCorrectionBandedResponse(centres: centres, magnitudeDB: magnitude, groupDelaySeconds: delay)
    }

    /// The deconvolved impulse response of a capture of the generator's sweep (synchronised ESS, level 0 dBFS peak) and the
    /// sub-sample position of its direct arrival.
    static func impulseResponse(
        capture: [Float], sweepStartHz: Double, sweepEndHz: Double, sweepFrames: Int, sampleRate: Double
    ) throws -> (impulse: [Float], arrivalFrames: Double) {
        let sweep = try MeasurementCore.makeSweep(
            sampleRate: sampleRate, startFrequencyHz: sweepStartHz, endFrequencyHz: sweepEndHz,
            durationSeconds: Double(sweepFrames) / sampleRate, levelDBFS: 0, fadeSeconds: 0.05, synchronised: true)
        let ir = try MeasurementCore.deconvolve(excitation: sweep.samples, observed: capture, regularizationRatio: 1e-6)
        // The linear impulse is the largest peak in the first half; harmonic impulses sit at negative (circular) time.
        let half = max(2, ir.count / 2)
        var best = 0
        for i in 0..<half where abs(ir[i]) > abs(ir[best]) { best = i }
        let arrival = try MeasurementCore.peakPosition(in: ir, range: max(0, best - 4)..<min(ir.count, best + 5))
        return (ir, arrival)
    }

    /// Design note 9 acceptance: measured against predicted at the main seat.
    static func evaluate(
        designID: String, sampleRate: Double, predicted: RoomCorrectionBandedResponse, measured: RoomCorrectionBandedResponse,
        criteria: RoomCorrectionPostApplyCriteria, date: Date = Date()
    ) -> RoomCorrectionPostApplyReport {
        guard predicted.centres == measured.centres, !predicted.centres.isEmpty else {
            return failure(designID, sampleRate, .analysisFailed, "bands differ", criteria, date)
        }
        let n = predicted.centres.count
        // The generator level is not known to the verifier: compare shapes about the mean level.
        let offset = (0..<n).map { measured.magnitudeDB[$0] - predicted.magnitudeDB[$0] }.reduce(0, +) / Double(n)
        let errors = (0..<n).map { measured.magnitudeDB[$0] - predicted.magnitudeDB[$0] - offset }
        let worst = errors.map { abs($0) }.max() ?? 0
        let predictedExcess = predicted.excessGroupDelaySeconds
        let measuredExcess = measured.excessGroupDelaySeconds
        var outcome = RoomCorrectionPostApplyOutcome.passed
        var detail = "Worst 1/6-octave error \(String(format: "%.2f", worst)) dB."
        if worst > criteria.magnitudeToleranceDB {
            outcome = .magnitudeMismatch
        } else if measuredExcess > predictedExcess + criteria.groupDelayMarginSeconds {
            outcome = .groupDelayMismatch
            detail = "Excess group delay \(String(format: "%.2f", measuredExcess * 1_000)) ms against a predicted "
                + "\(String(format: "%.2f", predictedExcess * 1_000)) ms."
        }
        return RoomCorrectionPostApplyReport(
            designID: designID, sampleRate: sampleRate, outcome: outcome, detail: detail, centres: predicted.centres,
            predictedDB: predicted.magnitudeDB, measuredDB: measured.magnitudeDB.map { $0 - offset },
            maxMagnitudeErrorDB: worst, predictedExcessGroupDelaySeconds: predictedExcess,
            measuredExcessGroupDelaySeconds: measuredExcess, criteria: criteria, date: date)
    }

    static func failure(
        _ designID: String, _ sampleRate: Double, _ outcome: RoomCorrectionPostApplyOutcome, _ detail: String,
        _ criteria: RoomCorrectionPostApplyCriteria, _ date: Date = Date()
    ) -> RoomCorrectionPostApplyReport {
        RoomCorrectionPostApplyReport(
            designID: designID, sampleRate: sampleRate, outcome: outcome, detail: detail, centres: [], predictedDB: [],
            measuredDB: [], maxMagnitudeErrorDB: 0, predictedExcessGroupDelaySeconds: 0, measuredExcessGroupDelaySeconds: 0,
            criteria: criteria, date: date)
    }
}

/// Part (a) of design note 9: the checks on the published filter before anything is played.
struct RoomCorrectionPredictionCheck: Equatable, Codable, Sendable {
    var passed: Bool
    var rmsErrorDB: Double
    var reasons: [String]

    static let maximumRMSErrorDB = 2.5

    /// The stage against the design's grid: magnitude agreement over the correction range, finite taps, and a declared
    /// latency that covers the filter's main tap (no pre-ringing beyond the budget).
    static func check(
        stage: RoomCorrectionLaneStage, grid: RoomCorrectionGridDesign, sampleRate: Double,
        declaredLatencyFrames: UInt32, latencyMode: RoomCorrectionLatencyMode, criteria: RoomCorrectionPostApplyCriteria
    ) throws -> RoomCorrectionPredictionCheck {
        var reasons: [String] = []
        if !stage.taps.allSatisfy({ $0.isFinite }) || !(stage.twoBand?.lowTaps.allSatisfy { $0.isFinite } ?? true) {
            reasons.append("The filter contains non-finite taps.")
        }
        let budgetFrames = latencyMode.budgetSeconds * sampleRate
        if Double(declaredLatencyFrames) > budgetFrames + 1 {
            reasons.append("The declared latency exceeds the \(latencyMode) budget.")
        }
        if stage.twoBand == nil, let peak = stage.taps.indices.max(by: { abs(stage.taps[$0]) < abs(stage.taps[$1]) }),
           Double(peak) > Double(declaredLatencyFrames) + 1 {
            reasons.append("The main tap sits after the declared latency.")
        }
        let all = try RoomCorrectionCore.gridFrequencies()
        let top = min(criteria.highHz, 0.4 * sampleRate)
        let indices = all.indices.filter { all[$0] >= criteria.lowHz && all[$0] <= top }
        let measured = try RoomCorrectionCore.filterResponse(
            sampleRate: sampleRate, taps: stage.taps, twoBand: stage.twoBand, declaredLatencyFrames: declaredLatencyFrames,
            frequencies: indices.map { all[$0] })
        var sum = 0.0
        for (k, index) in indices.enumerated() {
            let e = measured.magnitudeDB[k] - grid.correctionDB[index]
            sum += e * e
        }
        let rms = (sum / Double(max(indices.count, 1))).squareRoot()
        if rms > maximumRMSErrorDB { reasons.append("The filter departs from the design by \(String(format: "%.2f", rms)) dB RMS.") }
        return RoomCorrectionPredictionCheck(passed: reasons.isEmpty, rmsErrorDB: rms, reasons: reasons)
    }
}
