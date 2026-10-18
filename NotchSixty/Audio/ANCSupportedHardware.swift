import Foundation

/// E4 S7: interfaces and reference microphones bench-tested for speaker ANC,
/// with their measured round trip. Mirrors `docs/ANC_SUPPORTED_HARDWARE.md`;
/// keep the two in step. Compiled in rather than a bundle resource: it is one
/// small table. Empty until the S8 bench campaign measures real hardware.
enum ANCSupportedHardware {
    struct Entry: Equatable, Sendable {
        var name: String
        var latency: QuietZoneMeasuredLatency
    }

    static let tested: [Entry] = []

    enum LatencyStatus: Equatable, Sendable {
        case benchMeasured(name: String, roundTripSeconds: Double)
        case measuredHere(roundTripSeconds: Double, measuredAt: Date)
        case notYetMeasured

        var displayText: String {
            switch self {
            case let .benchMeasured(name, seconds):
                return String(format: "%.2f ms round trip (bench-tested: %@)", seconds * 1000, name)
            case let .measuredHere(seconds, _):
                return String(format: "%.2f ms round trip (measured on this Mac)", seconds * 1000)
            case .notYetMeasured:
                return "Not yet measured"
            }
        }
    }

    /// The bench table first, then the user's own measurements.
    static func latency(
        for key: QuietZoneLatencyKey,
        table: [Entry] = tested,
        store: QuietZoneMeasuredLatencyStore? = nil
    ) -> LatencyStatus {
        if let entry = table.first(where: { $0.latency.key == key }) {
            return .benchMeasured(name: entry.name, roundTripSeconds: entry.latency.roundTripSeconds)
        }
        if let own = store?.latency(for: key) {
            return .measuredHere(roundTripSeconds: own.roundTripSeconds, measuredAt: own.measuredAt)
        }
        return .notYetMeasured
    }
}
