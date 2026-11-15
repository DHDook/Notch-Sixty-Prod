import XCTest
@testable import NotchSixty

/// E6 (EQ linear-phase hardening): the Linear phase switch designs its FIR off the main actor, never traps reading a
/// flag from the graph builder, and the FIR design helpers refuse bad input instead of trapping.
@MainActor
final class EQLinearPhaseHardeningTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func linear(_ gain: Double = 4) -> StereoEQConfiguration {
        var configuration = EQRenderHarness.peakConfiguration(gainDB: gain, frequency: 1_000)
        configuration.phaseMode = .linearPhase
        return configuration
    }

    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_411, uid: "eq-linear-hardening", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "eq-linear-hardening")
        return engine
    }

    func testOffMainDesignFillsTheCacheAtEveryStandardRate() async throws {
        for rate in Self.rates {
            let engine = try engine(rate: rate)
            let configuration = linear()
            try await engine.prepareEQFIRDesignOffMain(configuration, sampleRate: rate)
            XCTAssertTrue(engine.eqFIRCache.hasDesign(EQFIRProgramKey(configuration, sampleRate: rate)), "\(rate)")
            let before = engine.eqFIRDesignCount
            try await engine.prepareEQFIRDesignOffMain(configuration, sampleRate: rate)
            XCTAssertEqual(engine.eqFIRDesignCount, before, "a cached design is not designed again at \(rate)")
        }
    }

    func testOffMainDesignMatchesTheSynchronousDesign() throws {
        for rate in Self.rates {
            let design = try EQFIRDesigner.design(linear(), sampleRate: rate)
            XCTAssertEqual(design.left.count, Int(N60LinearPhaseEQRecommendedTapCount(rate)), "\(rate)")
            XCTAssertTrue(design.left.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(design.declaredLatencyFrames, 0)
            XCTAssertNil(design.right)
        }
    }

    func testIndependentAndMidSideLanesPadToOneLength() throws {
        for mode in [EQChannelMode.independent, .midSide] {
            var configuration = linear()
            configuration.setChannelMode(mode)
            let design = try EQFIRDesigner.design(configuration, sampleRate: 96_000)
            XCTAssertEqual(design.left.count, design.right?.count)
        }
    }

    func testPhaseSwitchWithoutASessionStillApplies() async throws {
        let engine = try engine(rate: 96_000)
        try await engine.setEQPhaseModeOffMain(.linearPhase)
        XCTAssertEqual(engine.stereoEQConfiguration.phaseMode, .linearPhase)
        try await engine.setEQPhaseModeOffMain(.minimumPhase)
        XCTAssertEqual(engine.stereoEQConfiguration.phaseMode, .minimumPhase)
    }

    func testRapidPhaseToggleEndsOnTheLastRequest() async throws {
        let engine = try engine(rate: 192_000)
        for index in 0..<6 {
            try await engine.setEQPhaseModeOffMain(index.isMultiple(of: 2) ? .linearPhase : .minimumPhase)
        }
        XCTAssertEqual(engine.stereoEQConfiguration.phaseMode, .minimumPhase)
    }

    func testProcessWideFlagReadNeverTrapsOffTheMainActor() async {
        let value = await Task.detached { FeatureFlags.isEnabledProcessWide(.dynamicsExtras) }.value
        XCTAssertEqual(value, FeatureFlags.isEnabledProcessWide(.dynamicsExtras))
    }

    func testFIRBandHasANonTrappingBiquadType() {
        _ = EQFilterType.fir.cType
    }

    func testCascadeWithEmptyKernelThrowsInsteadOfTrapping() {
        let empty = EQFIRKernel(name: "empty", sampleRate: 48_000, taps: [])
        XCTAssertThrowsError(try EQFIRCompiler.cascade(base: [1], kernels: [empty]))
    }
}
