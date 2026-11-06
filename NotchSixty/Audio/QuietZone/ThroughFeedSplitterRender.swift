import Foundation

// E26 S2c: renders a pre-split feed (the sweep, or any programme) through the app's bass-management splitter, so the
// secondary-path and leakage models describe the path the anti-noise really plays: mains plus the sub lane. Control
// plane only. It calls the production splitter through `N60SpeakerBusRenderFeed` (the same splitter the stereo
// session runs), with fresh state per call, and never runs on an audio callback.
//
// Realtime contract (AGENTS.md section 4): allocates, so control plane only. Sample rate: any the splitter accepts
// (the crossover must sit below Nyquist). Channels: one mono feed in, `busCount` buses out. Reset: fresh zeroed
// splitter state on every call. Latency: the splitter's own group delay is part of the result, which is the point.

enum ThroughFeedSplitterRenderer {
    static let busCount = Int(N60SpeakerOutputBusCount.rawValue)

    enum Feed: Equatable, Sendable {
        case left, right

        var recordSource: CombinedAncPathRecord.Source { self == .left ? .feedLeft : .feedRight }
    }

    enum RenderError: Error, Equatable, LocalizedError {
        case splitterDisabled
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .splitterDisabled: return "Bass management is off, so there is no splitter to render through."
            case .renderFailed: return "The bass-management splitter could not render the measurement sweep."
            }
        }
    }

    /// What one feed reaches: every bus of the splitter, and the acoustic sum a single microphone hears when the
    /// mains and the sub play together (the combined path).
    struct Rendered: Equatable, Sendable {
        /// Frame-major, `busCount` values per frame.
        var interleaved: [Float]
        var frameCount: Int
        /// Sum of every split bus (low, mid, high, sub). Equals the input where the splitter is flat and the sub is
        /// at unity; the room adds its own delays on top.
        var combined: [Float]

        func bus(_ bus: N60SpeakerOutputBus) -> [Float] {
            let index = Int(bus.rawValue)
            return (0..<frameCount).map { interleaved[$0 * ThroughFeedSplitterRenderer.busCount + index] }
        }
    }

    static func render(
        _ input: [Float], feed: Feed, bass: BassManagementConfiguration, sampleRate: Double
    ) throws -> Rendered {
        guard bass.enabled else { throw RenderError.splitterDisabled }
        guard !input.isEmpty else { throw RenderError.renderFailed }
        let splitter = try bass.makeSpeakerBusSplitterSnapshot(sampleRate: sampleRate)
        var interleaved = [Float](repeating: 0, count: input.count * busCount)
        let ok = input.withUnsafeBufferPointer { i in
            interleaved.withUnsafeMutableBufferPointer { o in
                N60SpeakerBusRenderFeed(
                    i.baseAddress!, UInt32(i.count), feed == .left, splitter,
                    N60SpeakerDriverProcessingSnapshot(), o.baseAddress!)
            }
        }
        guard ok else { throw RenderError.renderFailed }
        var combined = [Float](repeating: 0, count: input.count)
        let first = Int(N60SpeakerOutputBusLeftLow.rawValue)
        for n in 0..<input.count {
            var sum: Float = 0
            for b in first..<busCount { sum += interleaved[n * busCount + b] }
            combined[n] = sum
        }
        return Rendered(interleaved: interleaved, frameCount: input.count, combined: combined)
    }

    /// The combined path's impulse response for a feed: a unit impulse rendered through the splitter, `seconds` long.
    static func combinedImpulseResponse(
        feed: Feed, bass: BassManagementConfiguration, sampleRate: Double, seconds: Double
    ) throws -> [Float] {
        var impulse = [Float](repeating: 0, count: max(1, Int((seconds * sampleRate).rounded())))
        impulse[0] = 1
        return try render(impulse, feed: feed, bass: bass, sampleRate: sampleRate).combined
    }

    /// A sweep program whose samples are the sweep rendered through the splitter (the combined signal at the
    /// listener). The inverse filter and timing are unchanged, so the analyzer recovers the combined path.
    static func program(
        _ program: RoomCorrectionSweepProgram, feed: Feed, bass: BassManagementConfiguration
    ) throws -> RoomCorrectionSweepProgram {
        var rendered = program
        rendered.sweepSamples = try render(
            program.sweepSamples, feed: feed, bass: bass, sampleRate: program.sampleRate).combined
        return rendered
    }
}
