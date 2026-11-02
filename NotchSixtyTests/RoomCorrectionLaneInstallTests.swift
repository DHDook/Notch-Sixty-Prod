import XCTest
@testable import NotchSixty

/// E24 S3b: the stored lane form, the engine-owned rate cache and the install through `makeUnifiedProgramDSP`.
@MainActor
final class RoomCorrectionLaneInstallTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func grid(_ db: Double = -2) throws -> RoomCorrectionGridDesign {
        let frequencies = try RoomCorrectionCore.gridFrequencies()
        return RoomCorrectionGridDesign(
            correctionDB: frequencies.map { $0 < 1_000 ? db : 0 },
            correctionPhaseRadians: [Double](repeating: 0, count: frequencies.count),
            coherence: [Double](repeating: 0, count: frequencies.count), seatContribution: [])
    }

    private func install(mode: RoomCorrectionLatencyMode = .video, subs: Int = 1) throws -> RoomCorrectionLaneInstall {
        let g = try grid()
        let design = RoomCorrectionMultiLaneDesign(
            latencyMode: mode, laneCount: 2,
            lanes: [RoomCorrectionLaneDesign(lane: 0, grid: g), RoomCorrectionLaneDesign(lane: 1, grid: g)])
        return RoomCorrectionLaneInstall(
            name: "Test", design: design, laneDelays: [RoomCorrectionLaneDelay(lane: 1, seconds: 0.001)],
            programLaneCount: 2, subwooferCount: subs)
    }

    private func engine(rate: Double = 48_000, unified: Bool = true) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_101, uid: "lane-install-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 6)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "lane-install-out")
        engine.unifiedGraphEnabled = unified
        return engine
    }

    private func shape() throws -> UnifiedGraphLayoutShape {
        try XCTUnwrap(UnifiedGraphLayoutShape(roles: [.frontLeft, .frontRight]))
    }

    func testConfigurationRoundTripsAndOldJSONDecodesWithoutLanes() throws {
        let configuration = RoomCorrectionConfiguration(enabled: true, lanes: try install())
        let data = try JSONEncoder().encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(RoomCorrectionConfiguration.self, from: data), configuration)
        let old = try JSONDecoder().decode(RoomCorrectionConfiguration.self, from: Data(#"{"enabled":false}"#.utf8))
        XCTAssertNil(old.lanes)
        XCTAssertTrue(configuration.enabled && !configuration.isActiveOnStereoKernel)
    }

    func testEnabledWithBothFilterAndLanesIsRefused() throws {
        let engine = try engine()
        var configuration = RoomCorrectionConfiguration(enabled: true, lanes: try install())
        configuration.filter = RoomCorrectionFilter(
            name: "x", sampleRate: 48_000, leftTaps: [1], rightTaps: [1], declaredLatencyFrames: 0)
        XCTAssertThrowsError(try engine.replaceRoomCorrectionConfiguration(configuration))
    }

    func testMainLanePlanInstallsAtEveryRateWithDeclaredLatencyAndAlignmentDelay() throws {
        for rate in Self.rates {
            let engine = try engine(rate: rate)
            var inputs = engine.currentLiveGraphInputs
            let lanes = try install()
            inputs.room = RoomCorrectionConfiguration(enabled: true, lanes: lanes)
            let program = try XCTUnwrap(
                engine.makeUnifiedProgramDSP(
                    sampleRate: rate, shape: try shape(), virtualSpeakers: false, subwooferCount: 1, inputs: inputs),
                "\(rate)")
            let plan = try XCTUnwrap(program.roomLanes, "\(rate)")
            XCTAssertEqual(plan.sampleRate, rate)
            XCTAssertEqual(plan.coveredMask, 0b11, "\(rate)")
            XCTAssertNil(program.stages.roomFIR, "\(rate)")
            XCTAssertEqual(program.laneDelayFrames[1], UInt32((0.001 * rate).rounded()), "\(rate)")
            XCTAssertNil(engine.roomCorrectionInactiveReason, "\(rate)")
        }
    }

    func testCacheMissSynthesisesOnceAndPrecomputeFillsEveryExposedRate() async throws {
        let engine = try engine()
        let lanes = try install()
        try await engine.precomputeRoomCorrectionPlans(for: lanes)
        let after = engine.roomCorrectionRateCache.synthesisCount
        XCTAssertGreaterThan(after, 0)
        var inputs = engine.currentLiveGraphInputs
        inputs.room = RoomCorrectionConfiguration(enabled: true, lanes: lanes)
        for rate in Self.rates {
            _ = try engine.makeUnifiedProgramDSP(
                sampleRate: rate, shape: try shape(), virtualSpeakers: false, subwooferCount: 1, inputs: inputs)
        }
        XCTAssertEqual(engine.roomCorrectionRateCache.synthesisCount, after, "precomputed rates never resynthesise")
    }

    func testLayoutMismatchLeavesCorrectionOffWithItsReason() throws {
        let engine = try engine()
        var inputs = engine.currentLiveGraphInputs
        inputs.room = RoomCorrectionConfiguration(enabled: true, lanes: try install(subs: 2))
        let program = try engine.makeUnifiedProgramDSP(
            sampleRate: 48_000, shape: try shape(), virtualSpeakers: false, subwooferCount: 1, inputs: inputs)
        XCTAssertNil(program?.roomLanes)
        XCTAssertEqual(engine.roomCorrectionInactiveReason, .layoutChanged)
    }

    func testLegacyKernelReportsTheUnifiedGraphIsNeeded() throws {
        let engine = try engine(unified: false)
        var inputs = engine.currentLiveGraphInputs
        inputs.room = RoomCorrectionConfiguration(enabled: true, lanes: try install())
        let program = try engine.makeUnifiedProgramDSP(
            sampleRate: 48_000, shape: try shape(), virtualSpeakers: false, subwooferCount: 1, inputs: inputs)
        XCTAssertNil(program)
        XCTAssertEqual(engine.roomCorrectionInactiveReason, .needsUnifiedGraph)
        XCTAssertThrowsError(try RoomCorrectionRateCache().plan(
            for: try install().design, sampleRate: 48_000, unifiedGraphEnabled: false))
    }

    func testLanesAreNeverCarriedByTheStereoKernel() throws {
        let engine = try engine()
        try engine.replaceRoomCorrectionConfiguration(RoomCorrectionConfiguration(enabled: true, lanes: try install()))
        XCTAssertFalse(engine.roomCorrectionConfiguration.isActiveOnStereoKernel)
        XCTAssertNil(engine.roomCorrectionInactiveReason, "no session is running, so nothing is uncorrected yet")
        XCTAssertTrue(RoomCorrectionInactiveReason.needsSpeakerProfile.message.contains("speaker profile"))
    }

    func testMixedPhaseLatencyPredicateFollowsTheBudget() throws {
        let cache = RoomCorrectionRateCache()
        let music = try install(mode: .defaultMusic)
        let fits = try Self.rates.map {
            RoomCorrectionLaneInstall.latencyFits(try cache.plan(for: music.design, sampleRate: $0), mode: .defaultMusic)
        }
        XCTAssertTrue(fits.allSatisfy { $0 })
        let plan = try cache.plan(for: music.design, sampleRate: 48_000)
        var over = plan
        over.declaredLatencyFrames = UInt32(0.2 * 48_000)
        XCTAssertFalse(RoomCorrectionLaneInstall.latencyFits(over, mode: .defaultMusic))
        XCTAssertTrue(RoomCorrectionLaneInstall.latencyFits(over, mode: .video))
    }
}
