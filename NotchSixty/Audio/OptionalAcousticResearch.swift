import Foundation

// MARK: - Optional research: bounded offline mixed-phase FIR proposals

enum OptionalAcousticResearchError: Error, Equatable, LocalizedError {
    case invalidEvidence
    case unsupportedRate
    case insufficientCoverage
    case excessiveFileSize
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidEvidence: return "Research input is unqualified, malformed, or non-finite."
        case .unsupportedRate: return "Sample rate must be 44.1–384 kHz and must match the selected device."
        case .insufficientCoverage: return "Measured directions do not cover the requested HRTF position."
        case .excessiveFileSize: return "Research document exceeds the bounded import size."
        case .unsupportedFormat: return "Unsupported research document schema or filter format."
        }
    }
}

struct MixedPhaseResearchResult: Sendable {
    var sampleRate: Double
    var amount: Double
    var declaredLatencyFrames: Int
    var maximumMagnitudeDeviationDB: Double
    var maximumPositiveGainDB: Double
    var recommendedHeadroomDB: Double
    var preRingingEnergyFraction: Double
    var leftTaps: [Float]
    var rightTaps: [Float]
    var blockingReasons: [String]
    var canDeploy: Bool { false }
    var isMeasuredVerification: Bool { false }
    var previewOnly: Bool { true }
}

/// Creates a bounded, causal, symmetrical component blended with an existing
/// *measured-source-derived* minimum-phase FIR, then audits its ACTUAL taps.
/// This deliberately does not replace the approved room-correction engine,
/// attach an Apply button, or claim measured improvement.
struct MixedPhaseResearchDesigner: Sendable {
    func design(
        left minimumLeft: [Float],
        right minimumRight: [Float],
        sampleRate: Double,
        linearPhaseShare: Double = 0.15,
        latencyBudgetMilliseconds: Double = 12
    ) throws -> MixedPhaseResearchResult {
        guard sampleRate.isFinite,
              (44_100...384_000).contains(sampleRate) else {
            throw OptionalAcousticResearchError.unsupportedRate
        }
        let count = minimumLeft.count
        guard (128...Int(N60_CONVOLUTION_MAX_TAPS)).contains(count),
              minimumRight.count == count,
              minimumLeft.allSatisfy(\.isFinite),
              minimumRight.allSatisfy(\.isFinite),
              linearPhaseShare.isFinite, (0...0.4).contains(linearPhaseShare),
              latencyBudgetMilliseconds.isFinite,
              (0...30).contains(latencyBudgetMilliseconds) else {
            throw OptionalAcousticResearchError.invalidEvidence
        }
        let delay = min(count / 4, Int((latencyBudgetMilliseconds * sampleRate / 1000).rounded(.down)))
        guard delay >= 1 else { throw OptionalAcousticResearchError.invalidEvidence }
        let left = blend(minimumLeft, amount: linearPhaseShare, delay: delay)
        let right = blend(minimumRight, amount: linearPhaseShare, delay: delay)
        let auditL = audit(reference: minimumLeft, proposed: left, delay: delay)
        let auditR = audit(reference: minimumRight, proposed: right, delay: delay)
        let deviation = max(auditL.deviation, auditR.deviation)
        let gain = max(auditL.peakGain, auditR.peakGain)
        let preRing = max(auditL.preRing, auditR.preRing)
        let headroom = max(0, ceil((gain + 0.25) * 2) / 2)
        var reasons = [String]()
        if deviation > 1.0 {
            reasons.append("Actual mixed-phase FIR differs by over 1 dB from the source minimum-phase transfer; review response and ringing.")
        }
        if preRing > 0.15 {
            reasons.append("Pre-ringing energy exceeds 15% of the measured filter impulse energy.")
        }
        if headroom > 6 {
            reasons.append("Modeled positive filter gain needs more than 6 dB of attenuation.")
        }
        if Double(delay) / sampleRate * 1000 > 30 {
            reasons.append("The candidate exceeds the A/V latency review budget.")
        }
        return MixedPhaseResearchResult(
            sampleRate: sampleRate,
            amount: linearPhaseShare,
            declaredLatencyFrames: delay,
            maximumMagnitudeDeviationDB: deviation,
            maximumPositiveGainDB: gain,
            recommendedHeadroomDB: headroom,
            preRingingEnergyFraction: preRing,
            leftTaps: left, rightTaps: right,
            blockingReasons: reasons
        )
    }

    private func blend(_ taps: [Float], amount: Double, delay: Int) -> [Float] {
        var output = [Float](repeating: 0, count: taps.count)
        // Delayed min-phase impulse with a constrained even-symmetric tail
        // around the delay: a direct time-domain, phase-bounded proposal.
        for i in 0..<min(taps.count - delay, taps.count) {
            output[delay + i] += Float(1 - amount) * taps[i]
        }
        output[delay] += Float(amount) * taps[0]
        for i in 1...min(delay, taps.count - delay - 1) {
            let part = Float(amount * 0.5) * taps[i]
            output[delay - i] += part
            output[delay + i] += part
        }
        return output
    }

    private func audit(
        reference: [Float], proposed: [Float], delay: Int
    ) -> (deviation: Double, peakGain: Double, preRing: Double) {
        var worst = 0.0
        var peak = 0.0
        // The same direct Fourier sum is applied to BOTH actual float tap
        // vectors. No design frequency curve is trusted as final evidence.
        for bin in 0...96 {
            let omega = Double.pi * Double(bin) / 96
            func level(_ taps: [Float]) -> Double {
                var real = 0.0, imaginary = 0.0
                for (i, tap) in taps.enumerated() {
                    let phase = omega * Double(i)
                    real += Double(tap) * cos(phase)
                    imaginary -= Double(tap) * sin(phase)
                }
                return 20 * log10(max(hypot(real, imaginary), 1e-10))
            }
            let expected = level(reference)
            let actual = level(proposed)
            worst = max(worst, abs(actual - expected))
            peak = max(peak, actual)
        }
        let total = proposed.reduce(0.0) { $0 + Double($1) * Double($1) }
        let early = proposed.prefix(delay).reduce(0.0) {
            $0 + Double($1) * Double($1)
        }
        return (worst, peak, total > 0 ? early / total : 0)
    }
}

// MARK: - Optional binaural: measured directional coverage + interpolation

struct HRTFResearchPreview: Sendable {
    var azimuthDegrees: Double
    var elevationDegrees: Double
    var nearestAngularDistanceDegrees: Double
    var sourceMeasurementCount: Int
    var leftIR: [Float]
    var rightIR: [Float]
    var maximumAbsoluteTap: Double
    var notes: [String]
    var canDeploy: Bool { false }
    var personalizedAccuracyVerified: Bool { false }
}

struct HRTFDirectionalResearchDesigner: Sendable {
    func interpolate(
        asset: BinauralProfileAsset,
        azimuthDegrees: Double,
        elevationDegrees: Double,
        maximumGapDegrees: Double = 30
    ) throws -> HRTFResearchPreview {
        try asset.validate()
        guard azimuthDegrees.isFinite, elevationDegrees.isFinite,
              (-180...180).contains(azimuthDegrees),
              (-90...90).contains(elevationDegrees),
              maximumGapDegrees.isFinite,
              (1...60).contains(maximumGapDegrees),
              asset.measurements.count <= 8192 else {
            throw OptionalAcousticResearchError.invalidEvidence
        }
        func direction(_ a: Double, _ e: Double) -> [Double] {
            let az = a * .pi / 180, el = e * .pi / 180
            return [cos(el) * cos(az), cos(el) * sin(az), sin(el)]
        }
        let target = direction(azimuthDegrees, elevationDegrees)
        let entries = asset.measurements.map { m -> (m: BinauralMeasurement, distance: Double) in
            let v = direction(m.azimuthDegrees, m.elevationDegrees)
            let dot = zip(target, v).reduce(0.0) { $0 + $1.0 * $1.1 }
            return (m, acos(max(-1, min(1, dot))) * 180 / .pi)
        }.sorted { $0.distance < $1.distance }
        guard let closest = entries.first,
              closest.distance <= maximumGapDegrees else {
            throw OptionalAcousticResearchError.insufficientCoverage
        }
        if closest.distance < 0.000001 {
            return HRTFResearchPreview(
                azimuthDegrees: azimuthDegrees,
                elevationDegrees: elevationDegrees,
                nearestAngularDistanceDegrees: closest.distance,
                sourceMeasurementCount: 1,
                leftIR: closest.m.leftIR, rightIR: closest.m.rightIR,
                maximumAbsoluteTap: Double((closest.m.leftIR + closest.m.rightIR)
                    .map { abs($0) }.max() ?? 0),
                notes: ["Exact recorded direction. Perceptual suitability is not verified."]
            )
        }
        let selected = Array(entries.prefix(3).filter {
            $0.distance <= maximumGapDegrees
        })
        // If only one measurement covers this direction, use the original
        // unmodified sample; no invented spatial detail can fill a hole.
        if selected.count == 1 {
            return HRTFResearchPreview(
                azimuthDegrees: azimuthDegrees,
                elevationDegrees: elevationDegrees,
                nearestAngularDistanceDegrees: closest.distance,
                sourceMeasurementCount: 1,
                leftIR: closest.m.leftIR, rightIR: closest.m.rightIR,
                maximumAbsoluteTap: Double((closest.m.leftIR + closest.m.rightIR)
                    .map { abs($0) }.max() ?? 0),
                notes: ["Only one measured direction covers this request; nearest neighbor used."]
            )
        }
        let unscaled = selected.map { 1.0 / max(1.0, $0.distance * $0.distance) }
        let total = unscaled.reduce(0,+)
        let weights = unscaled.map { $0 / total }
        func blend(_ ear: KeyPath<BinauralMeasurement,[Float]>) -> [Float] {
            var taps = [Float](repeating: 0, count: asset.tapCount)
            // Preserve peak/onset timing by aligning each ear to a weighted
            // onset; no invented HRTF cues or measurements are introduced.
            func onset(_ a: [Float]) -> Int {
                let peak = a.map { abs($0) }.max() ?? 0
                return a.firstIndex { abs($0) >= peak * 0.25 } ?? 0
            }
            let centers = selected.map { onset($0.m[keyPath: ear]) }
            let targetOnset = Int(zip(centers, weights).reduce(0.0) {
                $0 + Double($1.0) * $1.1
            }.rounded())
            for (i, entry) in selected.enumerated() {
                let tapsIn = entry.m[keyPath: ear]
                let shift = targetOnset - centers[i]
                for j in tapsIn.indices where (0..<taps.count).contains(j + shift) {
                    taps[j + shift] += Float(weights[i]) * tapsIn[j]
                }
            }
            return taps
        }
        let left = blend(\.leftIR), right = blend(\.rightIR)
        let peak = Double((left+right).map { abs($0) }.max() ?? 0)
        guard peak.isFinite, peak <= 8,
              left.allSatisfy(\.isFinite), right.allSatisfy(\.isFinite) else {
            throw OptionalAcousticResearchError.invalidEvidence
        }
        return HRTFResearchPreview(
            azimuthDegrees: azimuthDegrees,
            elevationDegrees: elevationDegrees,
            nearestAngularDistanceDegrees: closest.distance,
            sourceMeasurementCount: selected.count,
            leftIR: left, rightIR: right,
            maximumAbsoluteTap: peak,
            notes: [
                "Offline direction interpolation only; no realtime HRTF replacement.",
                "Onset alignment and angular proximity do not establish individual localization accuracy.",
                "Listener audition and independent headphone SPL testing remain required."
            ]
        )
    }
}

/// Non-personal biometric preference: a human listens and picks their own
/// locally imported SOFA profile. The preference is not an ear-shape model.
struct HRTFAuditionRecord: Codable, Equatable, Sendable {
    var assetID: UUID
    var sourceName: String
    var listenerRating: Int
    var notes: String
    var createdAt: Date

    func validate() throws {
        guard (1...5).contains(listenerRating),
              !sourceName.isEmpty,
              notes.count <= 1000 else {
            throw OptionalAcousticResearchError.invalidEvidence
        }
    }
}


/// Minimal, offline and private preference journal. This records a listener's
/// explicit audition rating, not geometry, biometric identity or measured HRTF
/// compatibility. No sync/upload, no automatic DSP Apply.
struct HRTFAuditionPreferenceStore: Sendable {
    var rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
            .appendingPathComponent("Notch Sixty", isDirectory: true)
            .appendingPathComponent("HRTF Auditions", isDirectory: true)
    }

    func save(_ record: HRTFAuditionRecord) throws {
        try record.validate()
        try FileManager.default.createDirectory(
            at: rootURL, withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: rootURL.appendingPathComponent(
            record.assetID.uuidString + ".json"
        ), options: .atomic)
    }

    func load(assetID: UUID) throws -> HRTFAuditionRecord? {
        let url = rootURL.appendingPathComponent(assetID.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attrs[.size] as? NSNumber)?.intValue,
              size <= 8_192 else {
            throw OptionalAcousticResearchError.excessiveFileSize
        }
        let record = try JSONDecoder().decode(
            HRTFAuditionRecord.self, from: Data(contentsOf: url)
        )
        try record.validate()
        guard record.assetID == assetID else {
            throw OptionalAcousticResearchError.invalidEvidence
        }
        return record
    }
}
