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


    func testProtectedRouteBindingRequiresExactBusCrossoverAndLimiter()
        throws {
        let routing = sameDeviceRouting()
        let outputs = [
            AudioOutputDevice(
                deviceID: 1,
                uid: "protected-device",
                name: "Protected Device",
                nominalSampleRate: sampleRate,
                availableSampleRateRanges: [
                    AudioSampleRateRange(
                        minimum: sampleRate,
                        maximum: sampleRate
                    )
                ],
                outputChannelCount: 2
            )
        ]
        let binding = try
            SpeakerMeasurementLabProtectedDriverRoutePlanner()
                .plan(
                    targetBus: .leftHigh,
                    routing: routing,
                    bassManagement: biAmpCrossover(),
                    driverProcessing:
                        protectedDriver(bus: .leftHigh),
                    availableOutputs: outputs,
                    sampleRate: sampleRate,
                    selectedOutputUID: "protected-device"
                )
        XCTAssertEqual(binding.physicalOutputChannelIndex, 1)
        XCTAssertEqual(
            binding.physicalDestination,
            PhysicalOutputEndpoint(
                deviceUID: "protected-device",
                channelIndex: 1
            )
        )
        XCTAssertTrue(
            binding.matchesCurrentState(
                routing: routing,
                bassManagement: biAmpCrossover(),
                driverProcessing:
                    protectedDriver(bus: .leftHigh)
            )
        )

        var unprotected = SpeakerDriverProcessingConfiguration()
        unprotected.replace(
            SpeakerDriverBusProcessingConfiguration(
                bus: .leftHigh,
                limiterEnabled: false
            )
        )
        XCTAssertThrowsError(
            try SpeakerMeasurementLabProtectedDriverRoutePlanner()
                .plan(
                    targetBus: .leftHigh,
                    routing: routing,
                    bassManagement: biAmpCrossover(),
                    driverProcessing: unprotected,
                    availableOutputs: outputs,
                    sampleRate: sampleRate,
                    selectedOutputUID: "protected-device"
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    SpeakerMeasurementLabProtectedDriverRouteError,
                .targetLimiterRequired
            )
        }
    }

    func testProtectedRouteBindingRejectsMissingOrAmbiguousTargetRoute()
        throws {
        let outputs = [
            AudioOutputDevice(
                deviceID: 1,
                uid: "protected-device",
                name: "Protected Device",
                nominalSampleRate: sampleRate,
                availableSampleRateRanges: [
                    AudioSampleRateRange(
                        minimum: sampleRate,
                        maximum: sampleRate
                    )
                ],
                outputChannelCount: 4
            )
        ]
        var missing = sameDeviceRouting()
        missing.routes[1].bus = .rightHigh
        XCTAssertThrowsError(
            try SpeakerMeasurementLabProtectedDriverRoutePlanner()
                .plan(
                    targetBus: .leftHigh,
                    routing: missing,
                    bassManagement: biAmpCrossover(),
                    driverProcessing:
                        protectedDriver(bus: .leftHigh),
                    availableOutputs: outputs,
                    sampleRate: sampleRate,
                    selectedOutputUID: "protected-device"
                )
        )

        var ambiguous = sameDeviceRouting()
        ambiguous.routes.append(
            SpeakerOutputRoute(
                name: "Duplicate Left High",
                bus: .leftHigh,
                destination: PhysicalOutputEndpoint(
                    deviceUID: "protected-device",
                    channelIndex: 2
                )
            )
        )
        XCTAssertThrowsError(
            try SpeakerMeasurementLabProtectedDriverRoutePlanner()
                .plan(
                    targetBus: .leftHigh,
                    routing: ambiguous,
                    bassManagement: biAmpCrossover(),
                    driverProcessing:
                        protectedDriver(bus: .leftHigh),
                    availableOutputs: outputs,
                    sampleRate: sampleRate,
                    selectedOutputUID: "protected-device"
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    SpeakerMeasurementLabProtectedDriverRouteError,
                .targetRouteAmbiguous
            )
        }
    }

    func testProtectedAnalysisProgramKeepsOriginalESSAndExtendsOnlyTail()
        throws {
        let settings = RoomCorrectionSweepSettings(
            sampleRate: sampleRate,
            startFrequencyHz: 100,
            endFrequencyHz: 10_000,
            durationSeconds: 0.20,
            levelDBFS: -30,
            leadInSeconds: 0.05,
            tailSeconds: 0.10,
            fadeSeconds: 0.01
        )
        let sourceProgram = try RoomCorrectionSweepGenerator()
            .makeProgram(settings: settings)
        let excitation = try
            SpeakerMeasurementLabProtectedExcitationCompiler()
                .compile(
                    monoSamples: sourceProgram.sweepSamples,
                    sampleRate: sampleRate,
                    targetBus: .leftHigh,
                    bassManagement: biAmpCrossover(),
                    driverProcessing:
                        protectedDriver(bus: .leftHigh)
                )
        let analysis = try excitation.makeAnalysisProgram(
            from: sourceProgram
        )

        XCTAssertEqual(
            analysis.sweepSamples,
            sourceProgram.sweepSamples
        )
        XCTAssertEqual(
            analysis.inverseFilter,
            sourceProgram.inverseFilter
        )
        XCTAssertEqual(
            analysis.tailFrames,
            sourceProgram.tailFrames
                + excitation.renderedSamples.count
                - sourceProgram.sweepSamples.count
        )
        XCTAssertEqual(
            analysis.captureFrameCount,
            sourceProgram.leadInFrames
                + excitation.renderedSamples.count
                + sourceProgram.tailFrames
        )
    }

    private func sameDeviceRouting()
        -> MultiOutputRoutingConfiguration {
        MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Left Low",
                    bus: .leftLow,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "protected-device",
                        channelIndex: 0
                    )
                ),
                SpeakerOutputRoute(
                    name: "Left High",
                    bus: .leftHigh,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "protected-device",
                        channelIndex: 1
                    )
                ),
            ],
            synchronizationMode: .automatic,
            referenceDeviceUID: "protected-device"
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


// PR111 Slice 1: original, measurement-only, cut-only driver optimizer.
final class ProtectedDriverPEQRecommendationTests: XCTestCase {
    private let systemID = UUID(uuidString:
        "11100000-0000-0000-0000-000000000001")!
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr111-calibrated-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr111-mic-cal"
    )
    private let analyzer = ProtectedDriverPEQRecommendationAnalyzer()

    private func provenance(
        bus: SpeakerOutputBus = .leftHigh,
        limiter: Bool = true,
        activeCrossover: Bool = true
    ) -> SpeakerMeasurementLabProtectedDriverCaptureProvenance {
        var bass = BassManagementConfiguration()
        bass.enabled = activeCrossover
        bass.frequencyHz = 1_000
        bass.physicalOutputMode = .biAmp
        let route = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Left Low", bus: .leftLow,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "PR111 Device", channelIndex: 0
                    )
                ),
                SpeakerOutputRoute(
                    name: "Left High", bus: .leftHigh,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "PR111 Device", channelIndex: 1
                    )
                )
            ],
            referenceDeviceUID: "PR111 Device"
        )
        return SpeakerMeasurementLabProtectedDriverCaptureProvenance(
            targetBus: bus,
            physicalDestination: PhysicalOutputEndpoint(
                deviceUID: "PR111 Device", channelIndex: 1
            ),
            routingConfiguration: route,
            bassManagementConfiguration: bass,
            targetDriverConfiguration:
                SpeakerDriverBusProcessingConfiguration(
                    bus: bus, limiterEnabled: limiter,
                    limiterThresholdDBFS: -30
                ),
            inputPeakDBFS: -30,
            renderedPeakDBFS: -32,
            sourceFrameCount: 4_800,
            renderedFrameCount: 16_800
        )
    }

    private func fixture(
        peakDB: Double = 5,
        snrDB: Double = 55,
        repeats: Int = 3,
        limiter: Bool = true,
        crossover: Bool = true,
        protectedBus: SpeakerOutputBus = .leftHigh
    ) -> (SpeakerMeasurementLabSession, UUID) {
        let labProtocol = SpeakerMeasurementLabProtocol(
            name: "PR111 Protected High",
            request: SpeakerMeasurementLabRequest(
                mode: .protectedDriverNearField,
                target: .protectedDriverBus(protectedBus),
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: 0.05
                )
            ),
            excitationLevelDBFS: -30
        )
        let grid = (0..<100).map { i in
            400.0 * pow(35, Double(i) / 99)
        }
        let receipt = provenance(
            bus: protectedBus,
            limiter: limiter,
            activeCrossover: crossover
        )
        var captures: [SpeakerMeasurementLabCapture] = []
        for repeatIndex in 0..<repeats {
            let magnitudes = grid.map { hz in
                let broadPeak = peakDB * exp(
                    -0.5 * pow(log2(hz / 4_000) / 0.23, 2)
                )
                return 0.1 * log2(hz / 2_000)
                    + broadPeak
                    + Double(repeatIndex - 1) * 0.03
            }
            let response = RoomCorrectionFrequencyResponse(
                frequenciesHz: grid,
                magnitudeDB: magnitudes,
                phaseRadians: grid.map { 0.02 * log2($0 / 1_000) }
            )
            let quality = RoomCorrectionMeasurementQuality(
                clipped: false,
                playbackPeakDBFS: -30,
                capturePeakDBFS: -20,
                estimatedNoiseFloorDBFS: -85,
                estimatedSNRDB: snrDB,
                sweepComplete: true,
                directArrivalSeconds: 0.003,
                usableLowHz: 400,
                usableHighHz: 14_000,
                warnings: []
            )
            captures.append(
                SpeakerMeasurementLabCapture(
                    protocolID: labProtocol.id,
                    repeatIndex: repeatIndex,
                    capturedAt: Date(
                        timeIntervalSince1970:
                            1_700_000_000 + Double(repeatIndex)
                    ),
                    playbackSystemID: systemID,
                    routingSignature: "pr111-active-route",
                    microphone: mic,
                    excitationLevelDBFS: -30,
                    sampleRate: 48_000,
                    source: .speaker(.frontLeft),
                    protectedDriverProvenance: receipt,
                    impulseResponse: [0.0, 0.3, 1.0, 0.2],
                    transferFunction: response,
                    quality: quality
                )
            )
        }
        return (
            SpeakerMeasurementLabSession(
                playbackSystemID: systemID,
                routingSignature: "pr111-active-route",
                microphone: mic,
                sampleRate: 48_000,
                protocols: [labProtocol],
                captures: captures
            ),
            labProtocol.id
        )
    }

    func testBroadRepeatStablePeakProducesBoundedCutOnlyReview() throws {
        let (session, protocolID) = fixture()
        let advice = try analyzer.recommend(
            session: session, protocolID: protocolID
        )
        XCTAssertEqual(advice.targetBus, .leftHigh)
        XCTAssertEqual(advice.repeatedCaptureIDs.count, 3)
        XCTAssertFalse(advice.cuts.isEmpty)
        XCTAssertLessThanOrEqual(advice.cuts.count, 3)
        XCTAssertTrue(advice.cuts.allSatisfy {
            $0.frequencyHz > 1_500 && $0.frequencyHz < 14_000
                && $0.gainDB < 0 && $0.gainDB >= -2.5
                && $0.q > 0 && $0.q <= 1.4
        })
        XCTAssertFalse(advice.canDeploy)
        XCTAssertFalse(advice.canChangeDelayOrPolarity)
        XCTAssertFalse(advice.canAlterCrossoverOrLimiter)
        XCTAssertTrue(advice.requiresNewMeasuredVerification)
    }

    func testSmoothResponseDoesNotInventPEQ() throws {
        let (session, protocolID) = fixture(peakDB: 0)
        XCTAssertTrue(
            try analyzer.recommend(
                session: session, protocolID: protocolID
            ).cuts.isEmpty
        )
    }

    func testClippedLowSNRMissingRepeatsAndBadGridReject() throws {
        var (session, protocolID) = fixture()
        session.captures[0].quality.clipped = true
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
        (session, protocolID) = fixture(snrDB: 14)
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
        (session, protocolID) = fixture(repeats: 2)
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
        (session, protocolID) = fixture()
        session.captures[1].transferFunction.frequenciesHz[13] *= 1.001
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
    }

    func testMandatoryCrossoverAndLimiterAreNeverBypassed() throws {
        var (session, protocolID) = fixture(limiter: false)
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
        (session, protocolID) = fixture(crossover: false)
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
        (session, protocolID) = fixture(protectedBus: .leftFullRange)
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
    }

    func testWrongProtocolOrAlteredRouteCannotBecomeRecommendation() throws {
        var (session, protocolID) = fixture()
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: UUID()
        ))
        session.captures[0].routingSignature = "other-route"
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
    }

    func testUnstableRepeatsDoNotAuthorizeCuts() throws {
        var (session, protocolID) = fixture()
        session.captures[1].transferFunction.magnitudeDB =
            session.captures[1].transferFunction.magnitudeDB.map {
                $0 + 2.5
            }
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
    }
}
