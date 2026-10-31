import Accelerate
import Foundation

/// What the upstream (reference) input channel is. Any input channel with a type label works; there is
/// no driver or special path (E4 S24).
enum QuietZoneReferenceInputKind: String, Codable, CaseIterable, Sendable {
    case microphone
    case contactMicrophone
    case accelerometer

    var label: String {
        switch self {
        case .microphone: return "Microphone"
        case .contactMicrophone: return "Contact microphone"
        case .accelerometer: return "Accelerometer"
        }
    }
}

/// E4 S24: estimates how long the noise takes to reach the seat monitor after it passes the upstream
/// reference. Both channels are low-passed and decimated to about 4 kHz with the same linear-phase FIR (so
/// the filter delay cancels), then cross-correlated. The lead is the lag of the correlation peak, refined
/// by a parabola through the peak and its neighbours. Control plane only: it allocates and is not
/// thread-safe; feed it from the survey queue, never from an audio callback.
final class QuietZoneUpstreamLeadEstimator {
    static let targetRate = 4_000.0
    /// Low-pass edge. Only the 25-150 Hz noise matters; this leaves headroom for the filter skirt.
    static let cutoffHz = 400.0
    static let maximumLagSeconds = 0.3

    let sampleRate: Double
    let decimation: Int
    var decimatedRate: Double { sampleRate / Double(decimation) }
    private let taps: [Float]
    private var referenceRing: [Float]
    private var errorRing: [Float]
    private var ringPosition = 0
    private var sinceOutput = 0
    private(set) var reference: [Float] = []
    private(set) var error: [Float] = []

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        decimation = max(1, Int((sampleRate / Self.targetRate).rounded()))
        // Hann-windowed sinc, eight output periods long, unity DC gain.
        let length = 8 * decimation + 1
        let edge = Self.cutoffHz / sampleRate
        var h = [Double](repeating: 0, count: length)
        let centre = Double(length - 1) / 2
        for n in 0..<length {
            let t = Double(n) - centre
            let sinc = t == 0 ? 2 * edge : sin(2 * Double.pi * edge * t) / (Double.pi * t)
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(length - 1))
            h[n] = sinc * window
        }
        let sum = h.reduce(0, +)
        taps = h.map { Float($0 / sum) }
        referenceRing = [Float](repeating: 0, count: length)
        errorRing = [Float](repeating: 0, count: length)
    }

    var decimatedCount: Int { reference.count }
    var decimatedSeconds: Double { Double(reference.count) / decimatedRate }

    /// A lost callback: forget the filter history so no output spans the gap.
    func markDiscontinuity() {
        for k in referenceRing.indices { referenceRing[k] = 0; errorRing[k] = 0 }
        ringPosition = 0
        sinceOutput = 0
    }

    func ingest(reference samples: [Float], error seat: [Float]) {
        precondition(samples.count == seat.count)
        let length = taps.count
        for i in 0..<samples.count {
            referenceRing[ringPosition] = samples[i]
            errorRing[ringPosition] = seat[i]
            ringPosition = (ringPosition + 1) % length
            sinceOutput += 1
            if sinceOutput == decimation {
                sinceOutput = 0
                // ringPosition is the oldest sample; the taps are symmetric, so order does not matter.
                var r: Float = 0
                var e: Float = 0
                var p = ringPosition
                for k in 0..<length {
                    r += taps[k] * referenceRing[p]
                    e += taps[k] * errorRing[p]
                    p += 1
                    if p == length { p = 0 }
                }
                reference.append(r)
                error.append(e)
            }
        }
    }

    struct Estimate: Equatable, Sendable {
        /// Seconds the seat monitor hears the noise after the reference does (negative: before).
        var leadSeconds: Double
        /// Normalised correlation at the peak, 0 to 1.
        var peakCorrelation: Double
        /// Half the decimated sample period, an upper bound on the interpolation error.
        var resolutionSeconds: Double
    }

    /// nil when there is too little signal (under 2 s) or no energy.
    func estimate() -> Estimate? {
        let n = reference.count
        let fs = decimatedRate
        guard n >= Int(2 * fs) else { return nil }
        let maxLag = min(Int(Self.maximumLagSeconds * fs), n / 4)
        var x = reference
        var d = error
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(n)); var negative = -mean
        vDSP_vsadd(x, 1, &negative, &x, 1, vDSP_Length(n))
        vDSP_meanv(d, 1, &mean, vDSP_Length(n)); negative = -mean
        vDSP_vsadd(d, 1, &negative, &d, 1, vDSP_Length(n))
        var xx: Float = 0, dd: Float = 0
        vDSP_svesq(x, 1, &xx, vDSP_Length(n))
        vDSP_svesq(d, 1, &dd, vDSP_Length(n))
        guard xx > 0, dd > 0 else { return nil }
        let norm = Double(xx * dd).squareRoot()
        // r[k] = sum x[i] d[i + k]: d lags x by k.
        var r = [Double](repeating: 0, count: 2 * maxLag + 1)
        for k in -maxLag...maxLag {
            let overlap = n - abs(k)
            var dot: Float = 0
            x.withUnsafeBufferPointer { xp in
                d.withUnsafeBufferPointer { dp in
                    vDSP_dotpr(xp.baseAddress! + max(0, -k), 1, dp.baseAddress! + max(0, k), 1, &dot, vDSP_Length(overlap))
                }
            }
            // Unbiased in the overlap, so a long lag is not penalised.
            r[k + maxLag] = Double(dot) / norm * Double(n) / Double(overlap)
        }
        guard let peak = r.indices.max(by: { r[$0] < r[$1] }) else { return nil }
        var offset = 0.0
        if peak > 0, peak < r.count - 1 {
            let a = r[peak - 1], b = r[peak], c = r[peak + 1]
            let denominator = a - 2 * b + c
            if denominator < 0 { offset = min(max(0.5 * (a - c) / denominator, -0.5), 0.5) }
        }
        return Estimate(
            leadSeconds: (Double(peak - maxLag) + offset) / fs,
            peakCorrelation: min(max(r[peak], 0), 1),
            resolutionSeconds: 0.5 / fs
        )
    }
}

enum QuietZoneUpstreamVerdict: String, Codable, Equatable, Sendable {
    /// The upstream position gives enough lead and coherence.
    case suitable
    /// The noise reaches the seat monitor too soon after the reference: place it further out.
    case moveFurtherOut
    /// The two signals do not follow each other: the reference is not hearing the same noise.
    case lowCoherence
    /// No usable correlation peak: nothing common was heard.
    case noCommonNoise

    var message: String {
        switch self {
        case .suitable: return "This position gives enough warning. Quiet Zone can use it as a reference."
        case .moveFurtherOut: return "Move the microphone further out: the noise must reach it earlier than the processing and sound path need."
        case .lowCoherence: return "The microphones hear different noise. Place the reference where the noise to cancel passes first (doorway, party wall, window or duct)."
        case .noCommonNoise: return "No noise common to both microphones was found. Measure while the noise to cancel is present."
        }
    }
}

/// E4 S24: the step 2 result of the one-microphone, two-step setup survey, and the prediction.
struct QuietZoneUpstreamAssessment: Equatable, Sendable {
    struct Band: Equatable, Sendable {
        var frequencyHz: Double
        var coherence: Double
        var predictedReductionDB: Double
    }

    static let lowestBandHz = 25.0
    static let highestBandHz = 150.0
    static let minimumCoherence = 0.85
    /// Margin added to the budget (S2).
    static let marginSeconds = 0.001
    /// The coherence bound is capped here: no setup earns more than this, whatever the estimate says.
    static let maximumPredictedReductionDB = 30.0
    static let minimumPeakCorrelation = 0.2

    var verdict: QuietZoneUpstreamVerdict
    var leadSeconds: Double
    var leadUncertaintySeconds: Double
    var budgetSeconds: Double
    var meanCoherence: Double
    var bands: [Band]
    /// Mean of the per-band bounds over 25-150 Hz; nil unless the setup is suitable.
    var predictedReductionDB: Double?
    var referenceKind: QuietZoneReferenceInputKind

    /// The coherence bound on feed-forward cancellation: -10 log10(1 - gamma^2) (Nelson and Elliott,
    /// Active Control of Sound, ch. 7), capped.
    static func reductionBoundDB(coherence: Double) -> Double {
        let g = min(max(coherence, 0), 1)
        guard g < 1 else { return maximumPredictedReductionDB }
        return min(-10 * log10(1 - g), maximumPredictedReductionDB)
    }

    /// - Parameters:
    ///   - latencySeconds: measured round trip of the speaker path (the S7 store).
    ///   - flightSeconds: speaker-to-seat flight time (path onset).
    ///   - clockOffsetErrorSeconds: the S23 offset error between the two devices; 0 for one device.
    static func assess(
        estimate: QuietZoneUpstreamLeadEstimator.Estimate?,
        bands survey: [QuietZoneFeedForwardSurveyBand],
        latencySeconds: Double,
        flightSeconds: Double,
        clockOffsetErrorSeconds: Double = 0,
        referenceKind: QuietZoneReferenceInputKind = .microphone
    ) -> QuietZoneUpstreamAssessment {
        let inBand = survey.filter { $0.frequencyHz >= lowestBandHz && $0.frequencyHz <= highestBandHz }
        let rows = inBand.map {
            Band(frequencyHz: $0.frequencyHz, coherence: $0.coherence,
                 predictedReductionDB: reductionBoundDB(coherence: $0.coherence))
        }
        let meanCoherence = rows.isEmpty ? 0 : rows.map(\.coherence).reduce(0, +) / Double(rows.count)
        let budget = latencySeconds + flightSeconds + marginSeconds
        let lead = estimate?.leadSeconds ?? 0
        let uncertainty = hypot(estimate?.resolutionSeconds ?? 0, clockOffsetErrorSeconds)

        var verdict = QuietZoneUpstreamVerdict.suitable
        if let estimate, estimate.peakCorrelation >= minimumPeakCorrelation {
            if lead - uncertainty <= budget {
                verdict = .moveFurtherOut
            } else if meanCoherence < minimumCoherence {
                verdict = .lowCoherence
            }
        } else {
            verdict = .noCommonNoise
        }
        let predicted = verdict == .suitable && !rows.isEmpty
            ? rows.map(\.predictedReductionDB).reduce(0, +) / Double(rows.count) : nil
        return QuietZoneUpstreamAssessment(
            verdict: verdict, leadSeconds: lead, leadUncertaintySeconds: uncertainty,
            budgetSeconds: budget, meanCoherence: meanCoherence, bands: rows,
            predictedReductionDB: predicted, referenceKind: referenceKind)
    }
}

/// E4 S24 step 2 run: feeds one pair capture (the moved microphone beside the seat monitor, through S23's
/// `CrossDevicePairCapture` or one device's two channels) into the S9b2 survey for coherence and into the
/// lead estimator, then assesses. Measurement only: no output. One queue; not thread-safe.
final class QuietZoneUpstreamSurveyRun {
    let sampleRate: Double
    private let survey: QuietZoneFeedForwardNoiseSurvey
    private let lead: QuietZoneUpstreamLeadEstimator
    private var nextSampleTime: Double?

    init?(sampleRate: Double) {
        guard let survey = QuietZoneFeedForwardNoiseSurvey(sampleRate: sampleRate) else { return nil }
        self.sampleRate = sampleRate
        self.survey = survey
        lead = QuietZoneUpstreamLeadEstimator(sampleRate: sampleRate)
    }

    var capturedFrames: Int { survey.capturedFrames }

    func ingest(reference frames: [N60FeedForwardReferenceFrame], error samples: [Float]) {
        if let first = frames.first {
            let time = first.firstFrameSampleTime + Double(first.frameOffset)
            if let expected = nextSampleTime, abs(time - expected) > 0.5 { lead.markDiscontinuity() }
        }
        if let last = frames.last { nextSampleTime = last.firstFrameSampleTime + Double(last.frameOffset) + 1 }
        survey.ingest(reference: frames, error: samples)
        lead.ingest(reference: frames.map(\.sample), error: samples)
    }

    func assess(
        latencySeconds: Double, flightSeconds: Double, clockOffsetErrorSeconds: Double = 0,
        referenceKind: QuietZoneReferenceInputKind = .microphone
    ) -> QuietZoneUpstreamAssessment {
        QuietZoneUpstreamAssessment.assess(
            estimate: lead.estimate(), bands: survey.bands(), latencySeconds: latencySeconds,
            flightSeconds: flightSeconds, clockOffsetErrorSeconds: clockOffsetErrorSeconds,
            referenceKind: referenceKind)
    }
}
