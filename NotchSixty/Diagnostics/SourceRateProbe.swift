import Foundation
import Observation

/// E15 S5 (design note 14): a read-only developer probe. It records the tap format rate and the output device's
/// nominal rate, and every change of either (or of the lifecycle state), with a timestamp, so the bench can show
/// whether the tap ever reports a rate other than the device's.
///
/// The probe never sets anything and never guesses the source rate from the signal (owner Q7 recommendation). It is
/// main-actor only and never touched from an audio callback; the engine is read through its observable lifecycle
/// state, so there is no new listener on the render path.
struct SourceRateSample: Equatable, Sendable {
    let time: Date
    let lifecycle: AudioLifecycleState
    let tapRate: Double?
    let deviceRate: Double?

    /// The tap carries a rate that differs from the device's nominal rate while running: the only observation that
    /// would justify a follow-on slice (entry rule, design note 14).
    var tapDiffersFromDevice: Bool {
        guard lifecycle == .running, let tapRate, let deviceRate else { return false }
        return abs(tapRate - deviceRate) > 0.5
    }
}

@MainActor
final class SourceRateProbe {
    static let capacity = 64

    private(set) var samples: [SourceRateSample] = []
    private(set) var tapDifferedFromDeviceCount = 0
    private(set) var droppedSamples = 0

    /// Records a sample when the lifecycle state or either rate differs from the last one. Returns whether it did.
    @discardableResult
    func record(lifecycle: AudioLifecycleState, tapRate: Double?, deviceRate: Double?, at time: Date = Date()) -> Bool {
        let sample = SourceRateSample(time: time, lifecycle: lifecycle, tapRate: tapRate, deviceRate: deviceRate)
        if let last = samples.last,
           last.lifecycle == sample.lifecycle, last.tapRate == sample.tapRate, last.deviceRate == sample.deviceRate {
            return false
        }
        if sample.tapDiffersFromDevice { tapDifferedFromDeviceCount += 1 }
        samples.append(sample)
        if samples.count > Self.capacity {
            samples.removeFirst()
            droppedSamples += 1
        }
        return true
    }

    func diagnosticsLines() -> [String] {
        var lines = ["Source Rate Probe (read-only, E15 S5):"]
        lines.append("  Tap rate differed from device rate while running: \(tapDifferedFromDeviceCount) time(s)")
        if samples.isEmpty {
            lines.append("  no samples")
            return lines
        }
        let stamp = ISO8601DateFormatter()
        for sample in samples {
            lines.append(
                "  \(stamp.string(from: sample.time))  \(sample.lifecycle.rawValue)  tap \(Self.text(sample.tapRate))"
                    + "  device \(Self.text(sample.deviceRate))")
        }
        if droppedSamples > 0 { lines.append("  (\(droppedSamples) older sample(s) dropped)") }
        return lines
    }

    private static func text(_ rate: Double?) -> String {
        guard let rate else { return "none" }
        return String(format: "%.1f kHz", rate / 1_000)
    }
}

/// Builds the probe and its subscription to the engine. Off unless `e15.follow-output` is on and developer tools are
/// shown, so a normal build builds nothing.
@MainActor
enum SourceRateProbeWiring {
    static func make(
        engine: AudioIOEngine, flagEnabled: Bool, developerToolsShown: Bool
    ) -> (probe: SourceRateProbe, subscription: ObservationSubscription)? {
        guard flagEnabled, developerToolsShown else { return nil }
        let probe = SourceRateProbe()
        func sample() {
            let snapshot = engine.diagnosticsSnapshot()
            probe.record(
                lifecycle: engine.lifecycleState, tapRate: snapshot.tapSampleRate,
                deviceRate: engine.selectedOutputDevice?.nominalSampleRate)
        }
        sample()
        let subscription = ObservationSubscription(
            track: { _ = engine.lifecycleState; _ = engine.sampleRateChangesHandled },
            onChange: { sample() })
        return (probe, subscription)
    }
}
