import Foundation

/// E4 S7: where a Quiet Zone round trip was measured. Latency depends on all
/// four: the output interface, the microphone interface, the rate and the
/// output buffer size.
struct QuietZoneLatencyKey: Codable, Hashable, Sendable {
    var outputDeviceUID: String
    var microphoneDeviceUID: String
    /// Nominal rate, rounded to the nearest hertz.
    var sampleRate: Int
    var bufferFrames: UInt32

    init(outputDeviceUID: String, microphoneDeviceUID: String, sampleRate: Double, bufferFrames: UInt32) {
        self.outputDeviceUID = outputDeviceUID
        self.microphoneDeviceUID = microphoneDeviceUID
        self.sampleRate = Int(sampleRate.rounded())
        self.bufferFrames = bufferFrames
    }
}

struct QuietZoneMeasuredLatency: Codable, Equatable, Sendable {
    var key: QuietZoneLatencyKey
    /// Sum of the four physical stage medians (the budget's nominal path).
    var roundTripSeconds: Double
    var upperBoundSeconds: Double
    var measuredAt: Date
}

/// The user's own measured round trips, kept across launches. Bench results
/// that ship with the app live in `ANCSupportedHardware` instead.
final class QuietZoneMeasuredLatencyStore {
    private let defaults: UserDefaults
    private var entries: [QuietZoneLatencyKey: QuietZoneMeasuredLatency]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: PreferenceKeys.quietZoneMeasuredLatency)
        let decoded = data.flatMap { try? JSONDecoder().decode([QuietZoneMeasuredLatency].self, from: $0) }
        entries = Dictionary((decoded ?? []).map { ($0.key, $0) }, uniquingKeysWith: { _, newer in newer })
    }

    var all: [QuietZoneMeasuredLatency] {
        entries.values.sorted { $0.measuredAt < $1.measuredAt }
    }

    func latency(for key: QuietZoneLatencyKey) -> QuietZoneMeasuredLatency? {
        entries[key]
    }

    /// Records a physical latency report measured at `bufferFrames`. The
    /// newest measurement for a key replaces the older one.
    @discardableResult
    func record(
        _ report: QuietZonePhysicalLatencyReport,
        bufferFrames: UInt32
    ) -> QuietZoneMeasuredLatency? {
        guard let first = report.stageEvidence.first,
              report.nominalPathSeconds.isFinite, report.nominalPathSeconds > 0 else { return nil }
        let entry = QuietZoneMeasuredLatency(
            key: QuietZoneLatencyKey(
                outputDeviceUID: first.outputDeviceID,
                microphoneDeviceUID: first.microphoneDeviceID,
                sampleRate: first.sampleRate,
                bufferFrames: bufferFrames
            ),
            roundTripSeconds: report.nominalPathSeconds,
            upperBoundSeconds: report.upperBoundPathSeconds,
            measuredAt: report.stageEvidence.map(\.capturedAt).max() ?? first.capturedAt
        )
        record(entry)
        return entry
    }

    func record(_ entry: QuietZoneMeasuredLatency) {
        entries[entry.key] = entry
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: PreferenceKeys.quietZoneMeasuredLatency)
        }
    }
}
