import Foundation

// E19 S10b (G36): per-way captures in the E24 seat flow. The room treatment of a routed setup designs per speaker over its
// in-band ways (design note 10), so it needs each in-band driver played alone at every included seat with the way's own crossover,
// EQ, delay and limiter bypassed from the analysis (the Lab's protected excitation plays through the way chain; this is the same
// raw measurement the planner expects). Control plane only.

/// One analysed capture of one way at one seat. Stored beside `MultichannelCalibrationMeasurement` (per role or sub): the
/// per-source measurements keep their meaning and a routed setup adds these.
struct MultichannelWayCapture: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var speakerID: UUID
    var wayID: UUID
    var seatID: UUID
    var sampleRate: Double
    var channel: RoomCorrectionChannelMeasurement
}

/// One (speaker, way, seat) the routed design still needs.
struct MultichannelWayTarget: Equatable, Sendable {
    var speakerID: UUID
    var speakerName: String
    var wayID: UUID
    var wayName: String
    var seatID: UUID
}

enum MultichannelWayCaptureTargets {
    /// Every in-band way (over the speaker's override window or the default one) at every seat that has no capture yet.
    /// Speakers in `excluded` need none.
    static func missing(
        routing: SpeakerRoutingConfiguration, seatIDs: [UUID], captures: [MultichannelWayCapture],
        overrides: [UUID: ClosedRange<Double>] = [:], excluded: Set<UUID> = [], sampleRate: Double
    ) -> [MultichannelWayTarget] {
        guard routing.enabled else { return [] }
        var result: [MultichannelWayTarget] = []
        for speaker in routing.speakers where !excluded.contains(speaker.id) {
            let window = overrides[speaker.id] ?? MIMORoutedTreatmentPlanner.defaultSupportHz
            for way in MIMORoutedTreatmentPlanner.inBandWays(of: speaker, lowHz: window.lowerBound, highHz: window.upperBound) {
                for seat in seatIDs where !captures.contains(where: {
                    $0.speakerID == speaker.id && $0.wayID == way.id && $0.seatID == seat
                        && abs($0.sampleRate - sampleRate) < 0.5 && !$0.channel.impulseResponse.isEmpty
                }) {
                    result.append(MultichannelWayTarget(
                        speakerID: speaker.id, speakerName: speaker.name, wayID: way.id, wayName: way.name, seatID: seat))
                }
            }
        }
        return result
    }
}

extension MultichannelCalibrationController {
    /// The raw way impulse responses the routed planner consumes (`MIMOTreatmentController` reads these).
    func routedWayCaptures() -> [MIMORoutedWayCapture] {
        wayCaptures.map {
            MIMORoutedWayCapture(
                speakerID: $0.speakerID, wayID: $0.wayID, seatID: $0.seatID, sampleRate: $0.sampleRate,
                impulseResponse: $0.channel.impulseResponse, includesChain: true)
        }
    }

    /// Stores a whole way pass at once (every seat of one way, or none), replacing earlier captures of the same way and seat.
    func storeWayCaptures(
        _ items: [(speakerID: UUID, wayID: UUID, seatID: UUID, channel: RoomCorrectionChannelMeasurement)], sampleRate: Double
    ) throws {
        try replaceWayCaptures(items, sampleRate: sampleRate)
    }
}
