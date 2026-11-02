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
