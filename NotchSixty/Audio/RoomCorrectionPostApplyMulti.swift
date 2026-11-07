import Foundation

// E24 S3c (design note 8): the post-apply prediction when more than one lane reaches the main seat (joint bass).
//
// A lane-0 sweep enters ahead of bass management, so the main seat hears the mains and the subwoofers together. The
// prediction sums each path's complex response at the main seat: the room (that source's impulse response there), through
// its lane stage (delay-removed, like every lane of a plan), its extra delay, its gain and its polarity. Magnitude is the
// 1/6-octave power average of the sum, as for a single path; group delay comes from the sum's phase.
//
// Realtime: none (control thread, offline). Allocation: allocates freely. Sample rate: any rate to 384 kHz. Channels: one
// path per contributing source. Reset: pure function.

/// One source's contribution at the main seat.
struct RoomCorrectionPredictionPath: Sendable {
    /// The source's room impulse response at the main seat and its direct arrival (sub-sample).
    var roomImpulse: [Float]
    var arrivalFrames: Double
    /// The lane's stage in the installed plan; nil when the lane carries no correction.
    var stage: RoomCorrectionLaneStage?
    /// Delay added on the path (a sub's calibrated delay, a main's alignment delay).
    var delaySeconds = 0.0
    var gainDB = 0.0
    var polarityInverted = false
}

extension RoomCorrectionPostApplyVerifier {
    /// The summed prediction at the main seat. The time origin is the first path's arrival.
    static func prediction(
        paths: [RoomCorrectionPredictionPath], declaredLatencyFrames: UInt32, sampleRate: Double,
        criteria: RoomCorrectionPostApplyCriteria
    ) throws -> RoomCorrectionBandedResponse {
        guard let first = paths.first else { throw RoomCorrectionPostApplyError.invalidImpulse }
        let origin = first.arrivalFrames
        let centres = criteria.centres(sampleRate: sampleRate)
        let sub = 4
        let eps = 0.002
        let halfBand = pow(2.0, 1.0 / Double(2 * criteria.bandsPerOctave))
        // Evaluation frequencies: per centre, per sub-frequency: f, f (1 - eps), f (1 + eps).
        var frequencies: [Double] = []
        for centre in centres {
            for j in 0..<sub {
                let f = centre / halfBand * pow(halfBand * halfBand, (Double(j) + 0.5) / Double(sub))
                frequencies += [f, f * (1 - eps), f * (1 + eps)]
            }
        }
        var totalRe = [Double](repeating: 0, count: frequencies.count)
        var totalIm = [Double](repeating: 0, count: frequencies.count)
        for path in paths {
            let impulse = path.roomImpulse
            let start = max(0, Int(path.arrivalFrames.rounded(.down)) - 64)
            let end = min(impulse.count, Int(path.arrivalFrames) + Int(criteria.analysisSeconds * sampleRate))
            guard end - start > 16, impulse.allSatisfy({ $0.isFinite }) else { throw RoomCorrectionPostApplyError.invalidImpulse }
            var stageMagnitude: [Double]?, stagePhase: [Double]?
            if let stage = path.stage {
                let response = try RoomCorrectionCore.filterResponse(
                    sampleRate: sampleRate, taps: stage.taps, twoBand: stage.twoBand,
                    declaredLatencyFrames: declaredLatencyFrames, frequencies: frequencies)
                stageMagnitude = response.magnitudeDB
                stagePhase = response.phaseRadians
            }
            let gain = pow(10.0, path.gainDB / 20) * (path.polarityInverted ? -1 : 1)
            let count = end - start
            let t0 = Double(start) - origin
            impulse.withUnsafeBufferPointer { x in
                for (index, f) in frequencies.enumerated() {
                    let w = 2 * Double.pi * f / sampleRate
                    let stepRe = cos(w), stepIm = -sin(w)
                    var re = 0.0, im = 0.0
                    var phRe = cos(w * t0), phIm = -sin(w * t0)
                    for i in 0..<count {
                        let v = Double(x[start + i])
                        re += v * phRe; im += v * phIm
                        let r = phRe * stepRe - phIm * stepIm
                        phIm = phRe * stepIm + phIm * stepRe
                        phRe = r
                    }
                    // Extra delay, gain and polarity, then the stage's delay-removed response.
                    var magnitude = gain
                    var phase = -w * path.delaySeconds * sampleRate
                    if let m = stageMagnitude, let p = stagePhase {
                        magnitude *= pow(10.0, m[index] / 20)
                        phase += p[index]
                    }
                    let cr = cos(phase) * magnitude, ci = sin(phase) * magnitude
                    totalRe[index] += re * cr - im * ci
                    totalIm[index] += re * ci + im * cr
                }
            }
        }
        var magnitude: [Double] = [], delay: [Double] = []
        for c in 0..<centres.count {
            var power = 0.0, gd = 0.0
            for j in 0..<sub {
                let base = (c * sub + j) * 3
                let re = totalRe[base], im = totalIm[base]
                power += re * re + im * im
                // Phase advance between f (1 - eps) and f (1 + eps): conj(H_lo) * H_hi.
                let lo = base + 1, hi = base + 2
                let pr = totalRe[lo] * totalRe[hi] + totalIm[lo] * totalIm[hi]
                let pi = totalRe[lo] * totalIm[hi] - totalIm[lo] * totalRe[hi]
                let dphi = atan2(pi, pr)
                gd += -dphi / (2 * Double.pi * (frequencies[hi] - frequencies[lo]))
            }
            magnitude.append(10 * log10(max(power / Double(sub), 1e-30)))
            delay.append(gd / Double(sub))
        }
        return RoomCorrectionBandedResponse(centres: centres, magnitudeDB: magnitude, groupDelaySeconds: delay)
    }
}

/// One source of the joint-bass design as the main seat measured it (E24 S11): the speakers first, then the subwoofers, in
/// the bass design's channel order. A source without a usable measurement carries nil `impulse`.
struct RoomCorrectionJointBassSource: Sendable {
    var isSubwoofer: Bool
    var impulse: [Float]?
    var directArrivalSeconds: Double?
    /// The subwoofer's calibrated gain, delay and polarity (ignored for a speaker).
    var gainDB = 0.0
    var delayMilliseconds = 0.0
    var polarityInverted = false
}

extension RoomCorrectionPostApplyVerifier {
    /// The prediction paths for a sweep on `measuredLane` with the joint bass installed: that lane's main and every
    /// subwoofer, one path each, from the main seat's own measurements (the generator sits ahead of bass management).
    /// `mainLanes` and `subLanes` are the bass plan's lanes in source order; `laneDelays` are the installed alignment delays.
    /// A source with no measurement is skipped. The bass-management crossover is not modelled (an E22 bench item).
    static func jointBassPaths(
        sources: [RoomCorrectionJointBassSource], mainLanes: [Int], subLanes: [Int],
        plan: RoomCorrectionLanePlan, measuredLane: Int, laneDelays: [RoomCorrectionLaneDelay], sampleRate: Double
    ) -> [RoomCorrectionPredictionPath] {
        func stage(_ lane: Int) -> RoomCorrectionLaneStage? {
            plan.stages.first { $0.laneMask & (1 << UInt64(lane)) != 0 }
        }
        var paths: [RoomCorrectionPredictionPath] = []
        var mainIndex = 0, subIndex = 0
        for source in sources {
            let isSub = source.isSubwoofer
            let mainLane = isSub ? nil : (mainIndex < mainLanes.count ? mainLanes[mainIndex] : nil)
            let subLane = isSub ? (subIndex < subLanes.count ? subLanes[subIndex] : nil) : nil
            if isSub { subIndex += 1 } else { mainIndex += 1 }
            guard let impulse = source.impulse, let arrival = source.directArrivalSeconds else { continue }
            var path = RoomCorrectionPredictionPath(roomImpulse: impulse, arrivalFrames: arrival * sampleRate)
            if isSub {
                guard let lane = subLane else { continue }
                let range = PhysicalSubwooferCalibration.gainRangeDB
                path.stage = stage(lane)
                path.gainDB = min(range.upperBound, max(range.lowerBound, source.gainDB))
                path.delaySeconds = min(PhysicalSubwooferCalibration.delayRangeMilliseconds.upperBound,
                                        max(0, source.delayMilliseconds)) / 1_000
                path.polarityInverted = source.polarityInverted
            } else {
                guard mainLane == measuredLane else { continue }
                path.stage = stage(measuredLane)
                path.delaySeconds = laneDelays.first { $0.lane == measuredLane }?.seconds ?? 0
            }
            paths.append(path)
        }
        return paths
    }
}
