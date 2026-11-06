import Foundation

// E26 S6b: readiness from the measured sweeps. The seat sweep is rendered through the app's bass-management splitter
// (S2c), played on the real outputs, and its impulse response is analysed per band. Three results feed
// `SubAwareAncReadiness`: the open-preout check (design 10a, G3), per-band feed-forward eligibility (design 5, G4) and
// the splitter-render verification, which now covers the sub bands (G2).
//
// Realtime contract (AGENTS.md section 4): control plane only, allocates and runs for seconds at 384 kHz, so it never
// runs on a realtime thread or the main actor. Sample rate: any; every quantity is in seconds and hertz. Channels:
// mono impulse responses for the left and right feeds. Reset: stateless.

/// The sweep that verifies the splitter render (G2). A 0.5 s sweep leaves up to 1.7 dB of Hann-window bias in the bands
/// below 40 Hz; an 8 s sweep from 15 Hz leaves under 0.2 dB and 0.15 ms there, well inside the verifier's unchanged
/// 1 dB and 0.5 ms tolerance, so no window-bias correction is applied (the owner's insurance step is dropped).
enum SplitterVerificationSweep {
    static let startFrequencyHz = 15.0
    static let endFrequencyHz = 640.0
    static let sweepSeconds = 8.0
    /// Covers the splitter's ring-out and the sub's low-pass tail.
    static let tailSeconds = 1.0
    static let fadeSeconds = 0.01
    static let peak = 0.5

    static func samples(sampleRate: Double) -> [Float] {
        guard sampleRate > 0, sampleRate.isFinite else { return [] }
        let n = Int(sweepSeconds * sampleRate), total = n + Int(tailSeconds * sampleRate)
        let k = log(endFrequencyHz / startFrequencyHz)
        var x = [Float](repeating: 0, count: total)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * startFrequencyHz * sweepSeconds / k * (exp(t / sweepSeconds * k) - 1)
            let fade = min(1, Double(i) / (fadeSeconds * sampleRate), Double(n - i) / (fadeSeconds * sampleRate))
            x[i] = Float(peak * fade * sin(phase))
        }
        return x
    }
}

/// What one measurement through the combined path says about readiness. Stamped with the bass fingerprint it was
/// measured under, so a bass-setting change makes it stale like every other ANC record.
struct SubSweepReport: Equatable, Sendable {
    var fingerprint: AncBassPathFingerprint
    var sampleRate: Double
    /// Measured seat path bands, per feed.
    var leftBands: [CombinedPathBand]
    var rightBands: [CombinedPathBand]
    /// The splitter render against the dry sweep (G2).
    var verification: SplitterRenderVerifier.Result
    /// "" when the declaration is confirmed or does not apply; otherwise the refusal text (G3).
    var openPreoutRefusal: String
    /// Per-band eligibility on the slower of the two feeds (G4).
    var eligibility: PerBandAncEligibility
    /// Why the splitter render cannot be trusted, or nil.
    var renderUnverifiedMessage: String?
    /// E26 S7c (class A): the measured combined seat path per feed, which is the plant the design uses, and the
    /// stored records. Nil and empty elsewhere (the Room Correction position is the plant).
    var seatLeft: RoomCorrectionChannelMeasurement? = nil
    var seatRight: RoomCorrectionChannelMeasurement? = nil
    var records: [CombinedAncPathRecord] = []

    var feedForwardBandCount: Int { eligibility.feedForwardBandsHz.count }
}

enum SubSweepAnalyzer {
    static let renderUnverifiedText = "Notch Sixty could not confirm how your bass split behaves. Measure with your subwoofer again."
    static let asymmetricFeedsText = "Your left and right bass paths differ, so one sweep cannot describe both. Check the bass settings."
    static let preoutNeedsBassManagementText =
        "Open pre-out needs Notch Sixty's bass management on. Turn it on, or choose Calibrated LFE out."

    /// The sweep program to play: the dry program with its samples replaced by the left feed rendered through the
    /// splitter (the combined signal at the listener). The inverse filter and timing are unchanged. Without bass
    /// management there is no splitter, so the dry program stands.
    static func renderedProgram(
        _ program: RoomCorrectionSweepProgram, bass: BassManagementConfiguration
    ) throws -> RoomCorrectionSweepProgram {
        guard bass.enabled else { return program }
        return try ThroughFeedSplitterRenderer.program(program, feed: .left, bass: bass)
    }

    /// `leftImpulse` and `rightImpulse` are the seat impulse responses of the two feeds, analysed against the dry
    /// sweep. Throws only when the splitter cannot be rendered; every judgement is a field of the report.
    static func analyze(
        leftImpulse: [Float], rightImpulse: [Float], sampleRate: Double, bass: BassManagementConfiguration,
        path: AncBassPathState, arrangement: SystemArrangement, conservativePreviewSeconds: Double?
    ) throws -> SubSweepReport {
        let left = CombinedPathBandAnalyzer.analyze(impulseResponse: leftImpulse, sampleRate: sampleRate)
        let right = CombinedPathBandAnalyzer.analyze(impulseResponse: rightImpulse, sampleRate: sampleRate)

        var verification = SplitterRenderVerifier.Result(
            worstGainErrorDB: 0, worstDelayErrorSeconds: 0, bandsCompared: 0, passes: true)
        var expectedLeft: [CombinedPathBand] = [], expectedRight: [CombinedPathBand] = []
        var unverified: String?
        if bass.enabled {
            let seconds = SplitterVerificationSweep.tailSeconds
            let impulseLeft = try ThroughFeedSplitterRenderer.combinedImpulseResponse(
                feed: .left, bass: bass, sampleRate: sampleRate, seconds: seconds)
            let impulseRight = try ThroughFeedSplitterRenderer.combinedImpulseResponse(
                feed: .right, bass: bass, sampleRate: sampleRate, seconds: seconds)
            expectedLeft = CombinedPathBandAnalyzer.analyze(impulseResponse: impulseLeft, sampleRate: sampleRate)
            expectedRight = CombinedPathBandAnalyzer.analyze(impulseResponse: impulseRight, sampleRate: sampleRate)
            let dry = SplitterVerificationSweep.samples(sampleRate: sampleRate)
            let rendered = try ThroughFeedSplitterRenderer.render(dry, feed: .left, bass: bass, sampleRate: sampleRate)
            verification = SplitterRenderVerifier.verify(
                dry: dry, rendered: rendered.combined, impulseBands: expectedLeft, sampleRate: sampleRate)
            if !verification.passes {
                unverified = renderUnverifiedText
            } else if !feedsAgree(expectedLeft, expectedRight, sampleRate: sampleRate) {
                // The sweep is rendered from the left feed only; an asymmetric split would mislabel the right feed.
                unverified = asymmetricFeedsText
            }
        }

        var preout = ""
        if path.path.receiverBass == .openPreout {
            if !bass.enabled {
                preout = preoutNeedsBassManagementText
            } else {
                preout = OpenPreoutCheck.refusal(
                    measured: left, expected: expectedLeft, sampleRate: sampleRate, removingCommonOffset: true)
                    ?? OpenPreoutCheck.refusal(
                        measured: right, expected: expectedRight, sampleRate: sampleRate, removingCommonOffset: true)
                    ?? ""
            }
        }

        // Per band, the slower feed decides (a band the sweep could not measure on either feed has no delay).
        let slower: [CombinedPathBand] = zip(left, right).map { l, r in
            var band = l
            if let a = l.delaySeconds, let b = r.delaySeconds { band.delaySeconds = max(a, b) } else { band.delaySeconds = nil }
            return band
        }
        let eligibility = PerBandAncEligibility.evaluate(
            arrangement: arrangement, bands: slower, conservativePreviewSeconds: conservativePreviewSeconds,
            allowClassA: path.path == .subOutput)
        return SubSweepReport(
            fingerprint: path.fingerprint, sampleRate: sampleRate, leftBands: left, rightBands: right,
            verification: verification, openPreoutRefusal: preout, eligibility: eligibility,
            renderUnverifiedMessage: unverified)
    }

    /// Same level (0.5 dB) and delay (one fd sample) in every band both feeds could measure.
    private static func feedsAgree(_ a: [CombinedPathBand], _ b: [CombinedPathBand], sampleRate: Double) -> Bool {
        let oneSample = 1.0 / min(sampleRate, 48_000)
        for (x, y) in zip(a, b) {
            guard let dx = x.delaySeconds, let dy = y.delaySeconds else { continue }
            if abs(x.gainDB - y.gainDB) > 0.5 || abs(dx - dy) > oneSample { return false }
        }
        return true
    }
}
