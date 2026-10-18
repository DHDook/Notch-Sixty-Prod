import Foundation

/// Two sample-aligned microphone channels of one device (E4 S9b1 pair mode).
protocol QuietZoneFeedForwardPairCapturing: AnyObject {
    var sampleRate: Double { get }
    func start() throws
    func readPair(maximumFrames: Int) throws -> (reference: [N60FeedForwardReferenceFrame], error: [Float])
    func close()
}

extension FeedForwardReferenceTransport: QuietZoneFeedForwardPairCapturing {}

/// E4 S9b2: feeds the survey core (`N60FeedForwardSurvey`) from a pair
/// capture and reads out the bands. Not thread-safe: one queue for every call.
/// A jump in the capture's sample time (a lost callback) marks a
/// discontinuity, so no Welch segment spans it.
final class QuietZoneFeedForwardNoiseSurvey {
    let sampleRate: Double
    let frequenciesHz: [Double]
    private let core: OpaquePointer
    private var nextSampleTime: Double?
    private(set) var capturedFrames = 0
    private var reference: [Float] = []
    private var error: [Float] = []

    init?(sampleRate: Double, frequenciesHz: [Double] = QuietZoneFeedForwardSurveyGrid.frequenciesHz) {
        var config = N60FeedForwardSurveyConfigDefault(sampleRate)
        guard frequenciesHz.count <= Int(N60_FF_SURVEY_MAX_BANDS) else { return nil }
        config.bandCount = UInt32(frequenciesHz.count)
        withUnsafeMutableBytes(of: &config.bandHz) { raw in
            let hz = raw.bindMemory(to: Float.self)
            for (k, f) in frequenciesHz.enumerated() { hz[k] = Float(f) }
        }
        guard let core = N60FeedForwardSurveyCreate(&config) else { return nil }
        self.core = core
        self.sampleRate = sampleRate
        self.frequenciesHz = frequenciesHz
    }

    deinit { N60FeedForwardSurveyDestroy(core) }

    func ingest(reference frames: [N60FeedForwardReferenceFrame], error samples: [Float]) {
        precondition(frames.count == samples.count)
        reference.removeAll(keepingCapacity: true)
        error.removeAll(keepingCapacity: true)
        for (frame, sample) in zip(frames, samples) {
            let time = frame.firstFrameSampleTime + Double(frame.frameOffset)
            if let expected = nextSampleTime, abs(time - expected) > 0.5 {
                flush()
                N60FeedForwardSurveyMarkDiscontinuity(core)
            }
            nextSampleTime = time + 1
            reference.append(frame.sample)
            error.append(sample)
        }
        flush()
        capturedFrames += frames.count
    }

    var segments: Int { Int(N60FeedForwardSurveyRead(core).segments) }
    var gaps: Int { Int(N60FeedForwardSurveyRead(core).gaps) }

    func bands() -> [QuietZoneFeedForwardSurveyBand] {
        let result = N60FeedForwardSurveyRead(core)
        let transfer = withUnsafeBytes(of: result.transfer) { Array($0.bindMemory(to: N60AncComplex.self)) }
        let coherence = withUnsafeBytes(of: result.coherence) { Array($0.bindMemory(to: Float.self)) }
        return frequenciesHz.enumerated().map { k, f in
            QuietZoneFeedForwardSurveyBand(
                frequencyHz: f,
                referenceToSeat: ActiveQuietZoneComplex(
                    real: Double(transfer[k].re), imaginary: Double(transfer[k].im)
                ),
                coherence: Double(coherence[k])
            )
        }
    }

    private func flush() {
        guard !reference.isEmpty else { return }
        N60FeedForwardSurveyProcess(core, reference, error, UInt32(reference.count))
        reference.removeAll(keepingCapacity: true)
        error.removeAll(keepingCapacity: true)
    }
}

/// One timed noise survey: owns the capture and the survey, on a serial
/// queue. `pump` drains whatever the capture holds.
final class QuietZoneFeedForwardNoiseSurveyRun: @unchecked Sendable {
    let targetFrames: Int
    let sampleRate: Double
    private let queue = DispatchQueue(label: "notchsixty.feed-forward.survey", qos: .userInitiated)
    private let capture: QuietZoneFeedForwardPairCapturing
    private let survey: QuietZoneFeedForwardNoiseSurvey

    init(capture: QuietZoneFeedForwardPairCapturing, survey: QuietZoneFeedForwardNoiseSurvey,
         durationSeconds: Double) {
        self.capture = capture
        self.survey = survey
        sampleRate = survey.sampleRate
        targetFrames = Int((durationSeconds * survey.sampleRate).rounded())
    }

    func start() throws { try queue.sync { try capture.start() } }

    /// Returns the progress, 0 to 1. A capture fault throws `.captureFault`.
    func pump() throws -> Double {
        try queue.sync {
            while survey.capturedFrames < targetFrames {
                let chunk: (reference: [N60FeedForwardReferenceFrame], error: [Float])
                do {
                    chunk = try capture.readPair(
                        maximumFrames: min(16_384, targetFrames - survey.capturedFrames)
                    )
                } catch {
                    throw QuietZoneFeedForwardSurveyError.captureFault
                }
                if chunk.reference.isEmpty { break }
                survey.ingest(reference: chunk.reference, error: chunk.error)
            }
            return min(Double(survey.capturedFrames) / Double(max(targetFrames, 1)), 1)
        }
    }

    func finish() -> (bands: [QuietZoneFeedForwardSurveyBand], segments: Int, gaps: Int) {
        queue.sync {
            capture.close()
            return (survey.bands(), survey.segments, survey.gaps)
        }
    }

    func cancel() { queue.sync { capture.close() } }
}
