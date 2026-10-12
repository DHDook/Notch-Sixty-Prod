import XCTest
@testable import NotchSixty

final class SpeakerMeasurementLabProtectedExcitationTests:
    XCTestCase {
    private let sampleRate = 48_000.0

    func testBiAmpHighDriverProgramUsesCrossoverAndLimiter()
        throws {
        let compiler =
            SpeakerMeasurementLabProtectedExcitationCompiler()
        let lowTone = tone(
            frequencyHz: 100,
            amplitude: 0.04
        )
        let highTone = tone(
            frequencyHz: 5_000,
            amplitude: 0.04
        )
        let bass = biAmpCrossover()
        let driver = protectedDriver(bus: .leftHigh)

        let low = try compiler.compile(
            monoSamples: lowTone,
            sampleRate: sampleRate,
            targetBus: .leftHigh,
            bassManagement: bass,
            driverProcessing: driver
        )
        let high = try compiler.compile(
            monoSamples: highTone,
            sampleRate: sampleRate,
            targetBus: .leftHigh,
            bassManagement: bass,
            driverProcessing: driver
        )

        XCTAssertTrue(high.preservesMandatoryCrossover)
        XCTAssertTrue(high.preservesConfiguredDriverProcessing)
        XCTAssertTrue(high.limiterProtected)
        XCTAssertFalse(high.canStartPhysicalMeasurement)
        XCTAssertFalse(high.canDeploy)
        XCTAssertGreaterThan(
            rms(high.renderedSamples),
            rms(low.renderedSamples) * 10
        )
        XCTAssertLessThanOrEqual(
            high.renderedPeakDBFS,
            -29.5
        )
        XCTAssertGreaterThan(
            high.renderedSamples.count,
            high.sourceFrameCount
        )
    }

    func testBiAmpLowDriverRejectsHighFrequencyEnergy()
        throws {
        let compiler =
            SpeakerMeasurementLabProtectedExcitationCompiler()
        let bass = biAmpCrossover()
        let driver = protectedDriver(bus: .leftLow)
        let low = try compiler.compile(
            monoSamples: tone(
                frequencyHz: 100,
                amplitude: 0.04
            ),
            sampleRate: sampleRate,
            targetBus: .leftLow,
            bassManagement: bass,
            driverProcessing: driver
        )
        let high = try compiler.compile(
            monoSamples: tone(
                frequencyHz: 5_000,
                amplitude: 0.04
            ),
            sampleRate: sampleRate,
            targetBus: .leftLow,
            bassManagement: bass,
            driverProcessing: driver
        )
        XCTAssertGreaterThan(
            rms(low.renderedSamples),
            rms(high.renderedSamples) * 10
        )
    }

    func testTriAmpMidBusIsSupportedThroughExactProtectedPath()
        throws {
        var bass = biAmpCrossover()
        bass.physicalOutputMode = .triAmp
        bass.frequencyHz = 400
        bass.upperFrequencyHz = 3_000
        let result = try
            SpeakerMeasurementLabProtectedExcitationCompiler()
                .compile(
                    monoSamples: tone(
                        frequencyHz: 1_000,
                        amplitude: 0.04
                    ),
                    sampleRate: sampleRate,
                    targetBus: .rightMid,
                    bassManagement: bass,
                    driverProcessing:
                        protectedDriver(bus: .rightMid)
                )
        XCTAssertGreaterThan(rms(result.renderedSamples), 1.0e-5)
        XCTAssertEqual(
            result.targetDriverConfiguration.bus,
            .rightMid
        )
    }

    func testProtectedCompilerRequiresExactTargetLimiter()
        throws {
        var driver = SpeakerDriverProcessingConfiguration()
        driver.replace(
            SpeakerDriverBusProcessingConfiguration(
                bus: .leftHigh,
                limiterEnabled: false
            )
        )
        XCTAssertThrowsError(
            try SpeakerMeasurementLabProtectedExcitationCompiler()
                .compile(
                    monoSamples: tone(
                        frequencyHz: 5_000,
                        amplitude: 0.04
                    ),
                    sampleRate: sampleRate,
                    targetBus: .leftHigh,
                    bassManagement: biAmpCrossover(),
                    driverProcessing: driver
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    SpeakerMeasurementLabProtectedExcitationError,
                .targetLimiterRequired
            )
        }
    }

    func testProtectedCompilerRejectsFullRangeSubAndMainsSub()
        throws {
        let compiler =
            SpeakerMeasurementLabProtectedExcitationCompiler()
        let samples = tone(
            frequencyHz: 1_000,
            amplitude: 0.04
        )
        for bus: SpeakerOutputBus in [
            .leftFullRange, .rightFullRange, .subMono
        ] {
            XCTAssertThrowsError(
                try compiler.compile(
                    monoSamples: samples,
                    sampleRate: sampleRate,
                    targetBus: bus,
                    bassManagement: biAmpCrossover(),
                    driverProcessing:
                        protectedDriver(bus: .leftHigh)
                )
            )
        }

        var bass = biAmpCrossover()
        bass.physicalOutputMode = .mainsSub
        XCTAssertThrowsError(
            try compiler.compile(
                monoSamples: samples,
                sampleRate: sampleRate,
                targetBus: .leftHigh,
                bassManagement: bass,
                driverProcessing:
                    protectedDriver(bus: .leftHigh)
            )
        ) {
            XCTAssertEqual(
                $0 as?
                    SpeakerMeasurementLabProtectedExcitationError,
                .physicalCrossoverRequired
            )
        }
    }

    func testProtectedCompilerRejectsHotOrNonFiniteExcitation()
        throws {
        let compiler =
            SpeakerMeasurementLabProtectedExcitationCompiler()
        let bass = biAmpCrossover()
        let driver = protectedDriver(bus: .leftHigh)

        XCTAssertThrowsError(
            try compiler.compile(
                monoSamples: tone(
                    frequencyHz: 5_000,
                    amplitude: 0.20
                ),
                sampleRate: sampleRate,
                targetBus: .leftHigh,
                bassManagement: bass,
                driverProcessing: driver
            )
        )
        XCTAssertThrowsError(
            try compiler.compile(
                monoSamples: [0, .nan, 0],
                sampleRate: sampleRate,
                targetBus: .leftHigh,
                bassManagement: bass,
                driverProcessing: driver
            )
        )
    }

    func testCapabilityPlannerStillBlocksLiveProtectedDriverTransport()
        throws {
        let request = SpeakerMeasurementLabRequest(
            mode: .protectedDriverNearField,
            target: .protectedDriverBus(.leftHigh),
            geometry: SpeakerMeasurementLabGeometry(
                distanceMeters: 0.05
            )
        )
        let route = LiveNChannelOutputRoutePlan(
            programLayout: .stereo,
            orderedDeviceUIDs: ["device"],
            referenceDeviceUID: "device",
            physicalChannelCount: 2,
            programPhysicalChannels: [0, 1],
            subwooferPhysicalChannels: [],
            subwooferCount: 0,
            bassManagementEnabled: false,
            speakerCalibrations: [:],
            subwooferCalibrations: [],
            speakerOptimizerPEQ: [:]
        )
        let plan = try SpeakerMeasurementLabCapabilityPlanner()
            .plan(
                request,
                routePlan: route,
                multiOutputRouting: nil,
                speakerDriverProcessing:
                    protectedDriver(bus: .leftHigh)
            )
        XCTAssertFalse(plan.canStartMeasurement)
        XCTAssertEqual(
            plan.blockReasons,
            [.protectedDriverTransportRequired(.leftHigh)]
        )
    }

    private func biAmpCrossover() -> BassManagementConfiguration {
        var configuration = BassManagementConfiguration()
        configuration.enabled = true
        configuration.frequencyHz = 1_000
        configuration.topology = .linkwitzRiley24
        configuration.physicalOutputMode = .biAmp
        return configuration
    }

    private func protectedDriver(
        bus: SpeakerOutputBus
    ) -> SpeakerDriverProcessingConfiguration {
        var configuration = SpeakerDriverProcessingConfiguration()
        configuration.replace(
            SpeakerDriverBusProcessingConfiguration(
                bus: bus,
                enabled: true,
                trimDB: 0,
                polarityInverted: false,
                delayMilliseconds: 2,
                limiterEnabled: true,
                limiterThresholdDBFS: -30
            )
        )
        return configuration
    }

    private func tone(
        frequencyHz: Double,
        amplitude: Float,
        frameCount: Int = 4_800
    ) -> [Float] {
        (0..<frameCount).map { index in
            amplitude * Float(
                sin(
                    2 * Double.pi * frequencyHz
                        * Double(index) / sampleRate
                )
            )
        }
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return sqrt(
            samples.reduce(0.0) {
                $0 + Double($1 * $1)
            } / Double(samples.count)
        )
    }
}
