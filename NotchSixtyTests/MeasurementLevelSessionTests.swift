import XCTest
@testable import NotchSixty

/// E24 S1: the level session's control plane against the offline pump (the production C process function renders;
/// only the Core Audio aggregate is replaced).
@MainActor
final class MeasurementLevelSessionTests: XCTestCase {
    private func request(rate: Double, lanes: [LevelSessionLane]) -> LevelSessionRequest {
        let uid = "level-test-output"
        let plan = LiveNChannelOutputRoutePlan(
            programLayout: .threeOne, orderedDeviceUIDs: [uid], referenceDeviceUID: uid, physicalChannelCount: 6,
            programPhysicalChannels: lanes.map(\.physicalChannel), subwooferPhysicalChannels: [], subwooferCount: 0,
            bassManagementEnabled: false, speakerCalibrations: [:], subwooferCalibrations: [])
        let input = AudioInputDevice(
            deviceID: 1, uid: "level-test-mic", name: "Mic", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)])
        return LevelSessionRequest(routePlan: plan, outputs: [], input: input, inputChannel: 0, sampleRate: rate, lanes: lanes)
    }

    private let lanes = [
        LevelSessionLane(roleIndex: 0, name: "Front left", physicalChannel: 0, isLFE: false),
        LevelSessionLane(roleIndex: 1, name: "Front right", physicalChannel: 1, isLFE: false),
        LevelSessionLane(roleIndex: 3, name: "LFE", physicalChannel: 2, isLFE: true),
    ]

    private func settings(rate: Double) throws -> SignalGeneratorSettings {
        try SystemSetupLevelPlan().validatedGeneratorSettings(sampleRate: rate)
    }

    func testPlaysOnlyTheSelectedRoleAtEveryRateAndStopsCleanly() throws {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let transports = OfflineLevelTransportFactory()
            let session = MeasurementLevelSession(transport: transports.factory)
            // Role index 1 is graph lane 1 (front right).
            try session.start(request(rate: rate, lanes: lanes), settings: try settings(rate: rate), selection: .lane(1))
            XCTAssertTrue(session.isRunning, "\(rate)")
            XCTAssertNotNil(session.ring, "\(rate)")
            let pump = try XCTUnwrap(transports.pumps.first)
            Thread.sleep(forTimeInterval: 0.4)
            let peaks = pump.lanePeaks
            XCTAssertGreaterThan(peaks[1], 1e-5, "\(rate): selected lane silent")
            XCTAssertEqual(peaks[0], 0, "\(rate)")
            XCTAssertEqual(peaks[2], 0, "\(rate)")
            XCTAssertLessThan(peaks[1], 1, "\(rate)")
            session.stop()
            XCTAssertFalse(session.isRunning, "\(rate)")
            XCTAssertTrue(pump.cancelled, "\(rate)")
        }
    }

    func testRoleWithoutAPhysicalChannelIsRefusedWithAClearText() throws {
        let transports = OfflineLevelTransportFactory()
        let session = MeasurementLevelSession(transport: transports.factory)
        XCTAssertThrowsError(try session.start(request(rate: 48_000, lanes: lanes), settings: try settings(rate: 48_000), selection: .lane(2))) {
            XCTAssertEqual($0 as? MeasurementLevelSessionError, .laneUnavailable)
            XCTAssertFalse(($0 as? LocalizedError)?.errorDescription?.contains("graph renderer") ?? true)
        }
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(transports.pumps.isEmpty)
    }

    func testDeviceFailureIsReportedAndLeavesNothingRunning() throws {
        let transports = OfflineLevelTransportFactory()
        transports.failure = MeasurementLevelSessionError.deviceFailure("busy")
        let session = MeasurementLevelSession(transport: transports.factory)
        XCTAssertThrowsError(try session.start(request(rate: 48_000, lanes: lanes), settings: try settings(rate: 48_000), selection: .lane(0))) {
            XCTAssertEqual($0 as? MeasurementLevelSessionError, .deviceFailure("busy"))
        }
        XCTAssertFalse(session.isRunning)
    }

    func testLiveUpdateChangesLaneWithoutRestart() throws {
        let transports = OfflineLevelTransportFactory()
        let session = MeasurementLevelSession(transport: transports.factory)
        try session.start(request(rate: 48_000, lanes: lanes), settings: try settings(rate: 48_000), selection: .lane(0))
        try session.update(try settings(rate: 48_000), selection: .lane(1))
        XCTAssertEqual(transports.pumps.count, 1)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertGreaterThan(transports.pumps[0].lanePeaks[1], 1e-5)
        session.stop()
    }

    func testAutoStopEndsTheSession() async throws {
        let transports = OfflineLevelTransportFactory()
        let session = MeasurementLevelSession(transport: transports.factory)
        var ended: LevelSessionEnd?
        session.onEnded = { ended = $0 }
        var short = try settings(rate: 48_000)
        short.autoStopSeconds = 0.2
        try session.start(request(rate: 48_000, lanes: lanes), settings: short, selection: .lane(0))
        for _ in 0..<40 where session.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(ended, .autoStopped)
    }

    func testErrorTextsAreSpecific() {
        let all: [MeasurementLevelSessionError] = [
            .outputRequired, .microphoneRequired, .microphonePermissionRequired, .routeUnavailable("x"),
            .noPlayableLane, .laneUnavailable, .invalidSettings, .sessionBusy, .deviceFailure("x"), .graphRejected("x"),
        ]
        let texts = all.compactMap(\.errorDescription)
        XCTAssertEqual(Set(texts).count, all.count)
        XCTAssertFalse(texts.contains { $0.contains("graph renderer") })
    }
}
