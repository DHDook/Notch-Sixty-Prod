import Foundation

/// E4 S30a: the control-plane side of the AMBIENT stage's section trailer (graph ABI v32). The conversation-unmasking
/// planner (`ConversationUnmaskingPlanner`) plans 17 third-octave cuts; this fits 17 live cut-only peaking sections to
/// them, models the realised response for the UI, checks the safety limits, and appends the trailer to the AMBIENT
/// stage's parameter list. Pure maths on numbers: no audio, no file, no engine state. Not called from an audio
/// callback. Nothing in production builds a non-nil cut list until S30c wires the controller (G6, G7).
///
/// Realisation (design note decision 2): peaking sections at the SII centres, Q one third octave, gains from a
/// projected least-squares fit of the realised response (dB, RBJ cookbook peaking) to the planned cuts at the 17
/// centres and the 16 midpoints, three iterations, each gain clamped to -8...0 dB. Cuts only: the overlay never boosts.
enum AmbientUnmaskOverlay {
    static let sectionCount = 17
    static let centersHz: [Double] = SpeechIntelligibilityBands.centersHz
    /// One third octave: Q = 1 / (2^(1/6) - 2^(-1/6)).
    static let sectionQ = 1.0 / (pow(2.0, 1.0 / 6.0) - pow(2.0, -1.0 / 6.0))
    /// Planned cut limit per band (dB, positive), the lower bound of a section gain, and the limit on the realised
    /// cut at any frequency (the sections' skirts add).
    static let maximumPlannedCutDB = 6.0
    static let minimumSectionGainDB = -8.0
    static let maximumRealisedCutDB = 7.0
    /// The core refuses a section above 0.45 fs; the overlay leaves such a section at 0 dB (it is not sent as a cut).
    static let highestSectionFraction = 0.45
    static let fitIterations = 3

    /// The ambient stage's fixed part: level dB, then (Hz, dB, Q) for the low shelf, presence peak and detail shelf.
    static let neutralBase: [Float] = [
        0,
        Float(AmbientCompensationResponseModel.lowShelfFrequencyHz), 0, Float(AmbientCompensationResponseModel.lowShelfQ),
        Float(AmbientCompensationResponseModel.presenceFrequencyHz), 0, Float(AmbientCompensationResponseModel.presenceQ),
        Float(AmbientCompensationResponseModel.detailShelfFrequencyHz), 0, Float(AmbientCompensationResponseModel.detailShelfQ),
    ]

    /// True for 17 finite planned cuts, each 0...6 dB (positive numbers are cuts). The planner's own limits are the
    /// same; this is the re-check before anything reaches the stage.
    static func isValid(plannedCutsDB cuts: [Double]) -> Bool {
        cuts.count == sectionCount
            && cuts.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= maximumPlannedCutDB }
    }

    /// Section gains (dB, each -8...0) realising `plannedCutsDB` (positive cuts) at `sampleRate`, or nil when the
    /// plan is invalid. A section above 0.45 fs (a low device rate) is held at 0 dB and left out of the fit.
    static func sectionGains(plannedCutsDB cuts: [Double], sampleRate: Double) -> [Double]? {
        guard isValid(plannedCutsDB: cuts), sampleRate.isFinite, sampleRate > 0 else { return nil }
        let n = sectionCount
        let usable = centersHz.map { $0 <= sampleRate * highestSectionFraction }
        // Targets at the centres and the 16 midpoints (geometric), in dB. A midpoint takes the mean of its neighbours.
        var points: [Double] = []
        var targets: [Double] = []
        var weights: [Double] = []
        for i in 0..<n {
            points.append(centersHz[i]); targets.append(-cuts[i]); weights.append(1)
            if i + 1 < n {
                points.append((centersHz[i] * centersHz[i + 1]).squareRoot())
                targets.append(-(cuts[i] + cuts[i + 1]) / 2)
                weights.append(0.35)
            }
        }
        var gains = [Double](repeating: 0, count: n)
        for i in 0..<n where usable[i] { gains[i] = max(minimumSectionGainDB, min(0, -cuts[i])) }
        let columns = (0..<n).filter { usable[$0] }
        guard !columns.isEmpty else { return gains }
        for _ in 0..<fitIterations {
            let realised = points.map { response(gainsDB: gains, atHz: $0, sampleRate: sampleRate) }
            let error = zip(targets, realised).map { $0 - $1 }
            // Jacobian: dB response per dB of section gain, at the unit cut (response is close to linear in dB).
            var jacobian = [[Double]](repeating: [Double](repeating: 0, count: columns.count), count: points.count)
            for (c, j) in columns.enumerated() {
                for (r, f) in points.enumerated() {
                    jacobian[r][c] = peakingDB(centreHz: centersHz[j], gainDB: -1, atHz: f, sampleRate: sampleRate) / -1
                }
            }
            // Normal equations with a small ridge so isolated sections stay well conditioned.
            let m = columns.count
            var a = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: m)
            for r in 0..<m {
                for c in 0..<m {
                    var s = 0.0
                    for p in 0..<points.count { s += weights[p] * jacobian[p][r] * jacobian[p][c] }
                    a[r][c] = s + (r == c ? 1e-3 : 0)
                }
                var b = 0.0
                for p in 0..<points.count { b += weights[p] * jacobian[p][r] * error[p] }
                a[r][m] = b
            }
            guard let delta = solve(&a) else { break }
            for (c, j) in columns.enumerated() {
                gains[j] = max(minimumSectionGainDB, min(0, gains[j] + delta[c]))
            }
        }
        // The skirts add: scale the whole set down until no frequency is cut by more than the limit.
        var scale = 1.0
        for _ in 0..<12 {
            let worst = minimumResponseDB(gainsDB: gains.map { $0 * scale }, sampleRate: sampleRate)
            if worst >= -maximumRealisedCutDB { break }
            scale *= (maximumRealisedCutDB / -worst) * 0.98
        }
        return gains.map { $0 * scale }
    }

    /// Realised response (dB) of the sections alone, log-spaced from 20 Hz to 0.45 fs (or 20 kHz).
    static func response(
        sectionGainsDB gains: [Double], sampleRate: Double, pointCount: Int = 160
    ) -> [AmbientCompensationResponsePoint] {
        guard gains.count == sectionCount, sampleRate.isFinite, sampleRate > 400, pointCount >= 8 else { return [] }
        let low = 20.0
        let high = min(20_000.0, sampleRate * highestSectionFraction)
        let ratio = high / low
        return (0..<pointCount).map { index in
            let f = low * pow(ratio, Double(index) / Double(pointCount - 1))
            return AmbientCompensationResponsePoint(
                frequencyHz: f, gainDB: response(gainsDB: gains, atHz: f, sampleRate: sampleRate))
        }
    }

    /// Response of the sections for a planned cut list (UI curve); empty when the plan is invalid.
    static func response(plannedCutsDB cuts: [Double], sampleRate: Double, pointCount: Int = 160)
        -> [AmbientCompensationResponsePoint] {
        guard let gains = sectionGains(plannedCutsDB: cuts, sampleRate: sampleRate) else { return [] }
        return response(sectionGainsDB: gains, sampleRate: sampleRate, pointCount: pointCount)
    }

    /// The AMBIENT stage parameter list with the trailer appended: the fixed ten values (`base`, or neutral bands when
    /// the kernel snapshot left ambient off), then n = 17 and (Hz, dB, Q) per section. nil when the plan is invalid,
    /// `base` is not the ten-value form, or the rate cannot hold the sections; the caller then keeps the plain stage.
    static func stageParameters(base: [Float]?, plannedCutsDB cuts: [Double], sampleRate: Double) -> [Float]? {
        let fixed = base ?? neutralBase
        guard fixed.count == 10, let gains = sectionGains(plannedCutsDB: cuts, sampleRate: sampleRate) else { return nil }
        var params = fixed
        params.append(Float(sectionCount))
        for i in 0..<sectionCount {
            // A section the rate cannot hold sits at the last usable centre's neighbour: 0 dB, inside the legal range.
            let hz = min(centersHz[i], sampleRate * highestSectionFraction)
            params.append(Float(hz))
            params.append(Float(max(minimumSectionGainDB, min(0, gains[i]))))
            params.append(Float(sectionQ))
        }
        return params
    }

    // MARK: Response maths

    static func response(gainsDB gains: [Double], atHz f: Double, sampleRate: Double) -> Double {
        var total = 0.0
        for i in 0..<gains.count where gains[i] != 0 {
            total += peakingDB(centreHz: centersHz[i], gainDB: gains[i], atHz: f, sampleRate: sampleRate)
        }
        return total
    }

    static func minimumResponseDB(gainsDB gains: [Double], sampleRate: Double) -> Double {
        let high = sampleRate * highestSectionFraction
        var worst = 0.0
        for k in 0..<512 {
            let f = 20.0 * pow(high / 20.0, Double(k) / 511.0)
            worst = min(worst, response(gainsDB: gains, atHz: f, sampleRate: sampleRate))
        }
        return worst
    }

    /// RBJ cookbook peaking magnitude in dB; the core designs the same filter.
    static func peakingDB(centreHz: Double, gainDB: Double, atHz f: Double, sampleRate: Double) -> Double {
        guard gainDB != 0, centreHz < sampleRate * 0.5 else { return 0 }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * centreHz / sampleRate
        let alpha = sin(w0) / (2 * sectionQ)
        let cw = cos(w0)
        let b0 = 1 + alpha * a, b1 = -2 * cw, b2 = 1 - alpha * a
        let a0 = 1 + alpha / a, a1 = -2 * cw, a2 = 1 - alpha / a
        let w = 2 * Double.pi * f / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }

    /// Gaussian elimination with partial pivoting on an augmented matrix; nil when singular.
    private static func solve(_ a: inout [[Double]]) -> [Double]? {
        let m = a.count
        for col in 0..<m {
            var pivot = col
            for r in (col + 1)..<max(col + 1, m) where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            for r in 0..<m where r != col {
                let factor = a[r][col] / a[col][col]
                if factor == 0 { continue }
                for c in col...m { a[r][c] -= factor * a[col][c] }
            }
        }
        return (0..<m).map { a[$0][m] / a[$0][$0] }
    }
}
