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
                    id: UUID(uuidString:
                        "11100000-0000-0000-0000-000000000010")!,
                    name: "Left Low", bus: .leftLow,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "PR111 Device", channelIndex: 0
                    )
                ),
                SpeakerOutputRoute(
                    id: UUID(uuidString:
                        "11100000-0000-0000-0000-000000000011")!,
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
                deviceUID: "PR111 Device",
                channelIndex: bus == .leftLow ? 0 : 1
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

    func testLabReportPublishesDriverCutReviewWithoutDSPDeployment() throws {
        let (session, _) = fixture(peakDB: 5)
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let summary = try XCTUnwrap(report.analysisSummaries.first {
            $0.kind == .protectedDriverOptimization
        })
        XCTAssertTrue(summary.available)
        XCTAssertTrue(summary.title.contains("Left High"))
        XCTAssertEqual(summary.metrics.first {
            $0.name == "Driver"
        }?.value, "Left High")
        XCTAssertEqual(summary.metrics.first {
            $0.name == "Limiting"
        }?.value, "Required / preserved")
        XCTAssertEqual(summary.metrics.first {
            $0.name == "Deployment"
        }?.value, "Never · review only")
        XCTAssertTrue(summary.metrics.contains {
            $0.name.hasPrefix("Cut ")
                && $0.value.contains("dB, Q")
        })
        XCTAssertTrue(summary.warnings.contains {
            $0.contains("no live Apply")
        })
        XCTAssertFalse(report.canDeploy)

        let csv = try SpeakerMeasurementLabReportExporter()
            .csvData(report)
        let csvText = try XCTUnwrap(
            String(data: csv, encoding: .utf8)
        )
        XCTAssertTrue(csvText.contains("protectedDriverOptimization"))
        XCTAssertTrue(csvText.contains("review only"))
        XCTAssertFalse(csvText.contains("impulseResponse"))
        let json = try SpeakerMeasurementLabReportExporter()
            .jsonData(report)
        let jsonText = try XCTUnwrap(
            String(data: json, encoding: .utf8)
        )
        XCTAssertTrue(jsonText.contains("protectedDriverOptimization"))
        XCTAssertFalse(jsonText.contains("transferFunction"))
    }

    func testLabReportSurfacesInconclusiveDriverOnMissingRepeats() throws {
        var (session, _) = fixture()
        session.captures.removeLast()
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let matching = report.analysisSummaries.filter {
            $0.kind == .protectedDriverOptimization
        }
        XCTAssertEqual(matching.count, 1)
        XCTAssertFalse(matching[0].available)
        XCTAssertTrue(matching[0].metrics.isEmpty)
        XCTAssertFalse(matching[0].warnings.isEmpty)
        XCTAssertFalse(report.canDeploy)
    }

    func testLabReportSurfacedProtectedDriverWithoutFabricatingBands() throws {
        let (session, _) = fixture(peakDB: 0)
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let advice = try XCTUnwrap(report.analysisSummaries.first {
            $0.kind == .protectedDriverOptimization
        })
        XCTAssertTrue(advice.available)
        XCTAssertEqual(advice.metrics.first {
            $0.name == "Suggested cuts"
        }?.value, "0")
        XCTAssertFalse(advice.metrics.contains {
            $0.name.hasPrefix("Cut ")
        })
        XCTAssertFalse(report.canDeploy)
    }

    func testReportRejectsUnprotectedLimiterCaptureEvenIfGridLooksGood() throws {
        let (session, _) = fixture(limiter: false)
        XCTAssertThrowsError(
            try SpeakerMeasurementLabReportBuilder().build(
                session: session
            )
        )
    }


    private func timingFixture(
        relativeArrivalMilliseconds: Double = 0.8,
        secondResidualPhaseRadians: Double = 0,
        referenceDriftMilliseconds: Double = 0.02,
        includeReference: Bool = true
    ) -> (SpeakerMeasurementLabSession, UUID, UUID) {
        let lowProtocol = SpeakerMeasurementLabProtocol(
            name: "PR111 Left Low timing",
            request: SpeakerMeasurementLabRequest(
                mode: .protectedDriverNearField,
                target: .protectedDriverBus(.leftLow),
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: 0.05
                )
            ),
            excitationLevelDBFS: -30
        )
        let highProtocol = SpeakerMeasurementLabProtocol(
            name: "PR111 Left High timing",
            request: SpeakerMeasurementLabRequest(
                mode: .protectedDriverNearField,
                target: .protectedDriverBus(.leftHigh),
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: 0.05
                )
            ),
            excitationLevelDBFS: -30
        )
        let grid = (0..<120).map { i in
            200.0 * pow(50.0, Double(i) / 119)
        }
        let lowReceipt = provenance(bus: .leftLow)
        let highReceipt = provenance(bus: .leftHigh)
        var captures: [SpeakerMeasurementLabCapture] = []
        for (labProtocol, receipt, arrival, phase) in [
            (
                lowProtocol,
                lowReceipt,
                0.010,
                0.0
            ),
            (
                highProtocol,
                highReceipt,
                0.010 + relativeArrivalMilliseconds / 1_000,
                secondResidualPhaseRadians
            ),
        ] {
            for repeatIndex in 0..<3 {
                let referenceArrival = 0.002
                    + Double(repeatIndex)
                        * referenceDriftMilliseconds / 2_000
                let shared = includeReference
                    ? SpeakerMeasurementLabSharedClockReferenceEvidence(
                        inputDeviceUID: mic.deviceUID,
                        inputChannelIndex: 1,
                        outputReferenceDeviceUID: "PR111 Device",
                        sampleRate: 48_000,
                        directArrivalSeconds: referenceArrival,
                        transferFunction:
                            RoomCorrectionFrequencyResponse(
                                frequenciesHz: grid,
                                magnitudeDB: grid.map { _ in
                                    Double(repeatIndex - 1) * 0.01
                                },
                                phaseRadians: grid.map { _ in
                                    Double(repeatIndex - 1) * 0.004
                                }
                            ),
                        quality: RoomCorrectionMeasurementQuality(
                            clipped: false,
                            playbackPeakDBFS: -30,
                            capturePeakDBFS: -8,
                            estimatedNoiseFloorDBFS: -85,
                            estimatedSNRDB: 65,
                            sweepComplete: true,
                            directArrivalSeconds: referenceArrival,
                            usableLowHz: 200,
                            usableHighHz: 10_000,
                            warnings: []
                        )
                    ) : nil
                let transferPhase = grid.map { frequency in
                    // The measured phase includes the acoustic time-of-flight.
                    // Slice 3 removes that delay slope before residual
                    // polarity comparison.
                    2 * Double.pi * frequency * arrival
                        + phase
                        + Double(repeatIndex - 1) * 0.002
                }
                captures.append(
                    SpeakerMeasurementLabCapture(
                        protocolID: labProtocol.id,
                        repeatIndex: repeatIndex,
                        capturedAt: Date(
                            timeIntervalSince1970:
                                1_710_000_000
                                + Double(repeatIndex)
                        ),
                        playbackSystemID: systemID,
                        routingSignature: "pr111-active-route",
                        microphone: mic,
                        excitationLevelDBFS: -30,
                        sampleRate: 48_000,
                        source: .speaker(.frontLeft),
                        protectedDriverProvenance: receipt,
                        sharedClockReference: shared,
                        impulseResponse: [0, 0.1, 1, 0.2, 0],
                        transferFunction:
                            RoomCorrectionFrequencyResponse(
                                frequenciesHz: grid,
                                magnitudeDB: grid.map { frequency in
                                    -1.5
                                        - 0.15
                                            * abs(log2(frequency / 1_000))
                                        + Double(repeatIndex - 1) * 0.01
                                },
                                phaseRadians: transferPhase
                            ),
                        quality: RoomCorrectionMeasurementQuality(
                            clipped: false,
                            playbackPeakDBFS: -30,
                            capturePeakDBFS: -18,
                            estimatedNoiseFloorDBFS: -85,
                            estimatedSNRDB: 58,
                            sweepComplete: true,
                            directArrivalSeconds:
                                arrival
                                    + Double(repeatIndex) * 0.00001,
                            usableLowHz: 250,
                            usableHighHz: 8_000,
                            warnings: []
                        )
                    )
                )
            }
        }
        return (
            SpeakerMeasurementLabSession(
                playbackSystemID: systemID,
                routingSignature: "pr111-active-route",
                microphone: mic,
                sharedClockReferenceConfiguration:
                    SpeakerMeasurementLabSharedClockReferenceConfiguration(
                        inputDeviceUID: mic.deviceUID,
                        inputChannelIndex: 1,
                        outputReferenceDeviceUID: "PR111 Device",
                        minimumSNRDB: 35
                    ),
                sampleRate: 48_000,
                protocols: [lowProtocol, highProtocol],
                captures: captures
            ),
            lowProtocol.id,
            highProtocol.id
        )
    }

    func testSharedReferenceTimingSuggestsBoundedDelayForEarlierDriver() throws {
        let (session, lowID, highID) = timingFixture(
            relativeArrivalMilliseconds: 0.8
        )
        let result = try ProtectedDriverTimingRecommendationAnalyzer()
            .recommend(
                session: session,
                firstProtocolID: lowID,
                secondProtocolID: highID
            )
        XCTAssertEqual(result.firstBus, .leftLow)
        XCTAssertEqual(result.secondBus, .leftHigh)
        XCTAssertEqual(result.crossoverFrequencyHz, 1_000, accuracy: 0.001)
        XCTAssertEqual(result.relativeArrivalMilliseconds, 0.8, accuracy: 0.03)
        XCTAssertEqual(result.delayBus, .leftLow)
        XCTAssertEqual(
            try XCTUnwrap(result.additionalDelayMilliseconds),
            0.8,
            accuracy: 0.03
        )
        XCTAssertEqual(result.polarityHypothesis, .retainCurrent)
        XCTAssertTrue(result.measurementOnly)
        XCTAssertFalse(result.canDeploy)
        XCTAssertFalse(result.canChangeCrossoverOrLimiter)
        XCTAssertTrue(result.requiresCombinedDriverVerification)
    }

    func testResidualPiPhaseProducesOnlyPolarityHypothesis() throws {
        let (session, lowID, highID) = timingFixture(
            relativeArrivalMilliseconds: 0.2,
            secondResidualPhaseRadians: .pi
        )
        let result = try ProtectedDriverTimingRecommendationAnalyzer()
            .recommend(
                session: session,
                firstProtocolID: lowID,
                secondProtocolID: highID
            )
        XCTAssertEqual(
            result.polarityHypothesis,
            .invertComparedDriver
        )
        XCTAssertFalse(result.canDeploy)
    }

    func testMissingOrUnstableSharedReferenceFailsClosed() throws {
        var (session, lowID, highID) = timingFixture(
            includeReference: false
        )
        XCTAssertThrowsError(
            try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        )
        (session, lowID, highID) = timingFixture(
            referenceDriftMilliseconds: 0.7
        )
        XCTAssertThrowsError(
            try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        ) {
            XCTAssertEqual(
                $0 as? ProtectedDriverTimingRecommendationError,
                .referencePathUnstable
            )
        }
    }

    func testLargeArrivalMismatchDoesNotInventSafeDelayAdjustment() throws {
        let (session, lowID, highID) = timingFixture(
            relativeArrivalMilliseconds: 3.5
        )
        let result = try ProtectedDriverTimingRecommendationAnalyzer()
            .recommend(
                session: session,
                firstProtocolID: lowID,
                secondProtocolID: highID
            )
        XCTAssertNil(result.delayBus)
        XCTAssertNil(result.additionalDelayMilliseconds)
        XCTAssertFalse(result.canDeploy)
    }

    func testCrossSpeakerOrUnprotectedPairCannotProduceTimingAdvice() throws {
        var (session, lowID, highID) = timingFixture()
        session.protocols[1].request.target =
            .protectedDriverBus(.rightHigh)
        XCTAssertThrowsError(
            try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        )
        (session, lowID, highID) = timingFixture()
        session.captures[3].protectedDriverProvenance?
            .routingConfiguration.referenceDeviceUID = "other-device"
        XCTAssertThrowsError(
            try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        )
    }


    func testLabReportPublishesProtectedTimingAsReviewOnly() throws {
        let (session, _, _) = timingFixture(
            relativeArrivalMilliseconds: 0.8
        )
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let timing = try XCTUnwrap(
            report.analysisSummaries.first {
                $0.kind == .protectedDriverTiming
            }
        )
        XCTAssertTrue(timing.available)
        XCTAssertTrue(timing.title.contains("Left Low"))
        XCTAssertTrue(timing.title.contains("Left High"))
        XCTAssertEqual(
            timing.metrics.first { $0.name == "Deployment" }?.value,
            "Never · review only"
        )
        XCTAssertTrue(timing.metrics.contains {
            $0.name == "Delay hypothesis"
                && $0.value.contains("Left Low")
        })
        XCTAssertTrue(timing.metrics.contains {
            $0.name == "Polarity hypothesis"
                && $0.value.contains("Retain")
        })
        XCTAssertTrue(timing.warnings.contains {
            $0.contains("Combined-driver crossover summation")
        })
        XCTAssertFalse(report.canDeploy)

        let csv = try SpeakerMeasurementLabReportExporter()
            .csvData(report)
        let text = try XCTUnwrap(String(data: csv, encoding: .utf8))
        XCTAssertTrue(text.contains("protectedDriverTiming"))
        XCTAssertTrue(text.contains("Never"))
        let json = try SpeakerMeasurementLabReportExporter()
            .jsonData(report)
        let jsonText = try XCTUnwrap(
            String(data: json, encoding: .utf8)
        )
        XCTAssertTrue(jsonText.contains("protectedDriverTiming"))
        XCTAssertFalse(jsonText.contains("impulseResponse"))
    }

    func testLabReportShowsUnqualifiedTimingWhenReferenceIsUnstable() throws {
        let (session, _, _) = timingFixture(
            referenceDriftMilliseconds: 0.7
        )
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let timing = try XCTUnwrap(
            report.analysisSummaries.first {
                $0.kind == .protectedDriverTiming
            }
        )
        XCTAssertFalse(timing.available)
        XCTAssertTrue(timing.metrics.isEmpty)
        XCTAssertTrue(timing.warnings.contains {
            $0.localizedCaseInsensitiveContains("reference")
        })
        XCTAssertFalse(report.canDeploy)
    }

    func testTriAmpCannotTreatLowAndHighAsAdjacentTimingPair() throws {
        var (session, lowID, highID) = timingFixture()
        for index in session.captures.indices {
            session.captures[index]
                .protectedDriverProvenance?
                .bassManagementConfiguration.physicalOutputMode = .triAmp
            session.captures[index]
                .protectedDriverProvenance?
                .bassManagementConfiguration.upperFrequencyHz = 4_000
        }
        XCTAssertThrowsError(
            try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        )
    }


    func testCrossoverSumModelSelectsBoundedDelayWhenItReducesCancellation()
        throws {
        let (session, lowID, highID) = timingFixture(
            relativeArrivalMilliseconds: 0.8
        )
        let result = try ProtectedDriverCrossoverSumModelAnalyzer()
            .analyze(
                session: session,
                firstProtocolID: lowID,
                secondProtocolID: highID
            )
        XCTAssertEqual(result.firstBus, .leftLow)
        XCTAssertEqual(result.secondBus, .leftHigh)
        XCTAssertEqual(result.bestHypothesis, .addBoundedDelay)
        XCTAssertEqual(
            try XCTUnwrap(result.modeledAdditionalDelayMilliseconds),
            0.8,
            accuracy: 0.03
        )
        XCTAssertFalse(result.modeledInvertsComparedDriver)
        XCTAssertGreaterThan(result.modeledDeficitReductionDB, 0.25)
        XCTAssertLessThan(
            result.candidateMeanCoherenceDeficitDB,
            result.currentMeanCoherenceDeficitDB
        )
        XCTAssertTrue(result.measurementOnly)
        XCTAssertTrue(result.modelOnly)
        XCTAssertFalse(result.canDeploy)
        XCTAssertFalse(result.combinedDriverCaptureVerified)
        XCTAssertTrue(result.requiresPhysicalCombinedDriverCapture)
    }

    func testCrossoverSumModelCanCompareCombinedDelayAndPolarityHypothesis()
        throws {
        let (session, lowID, highID) = timingFixture(
            relativeArrivalMilliseconds: 0.2,
            secondResidualPhaseRadians: .pi
        )
        let result = try ProtectedDriverCrossoverSumModelAnalyzer()
            .analyze(
                session: session,
                firstProtocolID: lowID,
                secondProtocolID: highID
            )
        XCTAssertTrue(result.modeledInvertsComparedDriver)
        XCTAssertTrue(
            result.bestHypothesis == .invertComparedDriver
                || result.bestHypothesis
                    == .addDelayAndInvertComparedDriver
        )
        XCTAssertGreaterThan(result.modeledDeficitReductionDB, 0.25)
        XCTAssertFalse(result.canDeploy)
    }

    func testCrossoverSumModelWithoutQualifiedReferenceFailsClosed() throws {
        let (session, lowID, highID) = timingFixture(
            includeReference: false
        )
        XCTAssertThrowsError(
            try ProtectedDriverCrossoverSumModelAnalyzer()
                .analyze(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        ) {
            XCTAssertEqual(
                $0 as? ProtectedDriverCrossoverSumModelError,
                .timingEvidenceUnavailable
            )
        }
    }

    func testLargeTimingMismatchDoesNotBecomeModeledSafeAdjustment() throws {
        let (session, lowID, highID) = timingFixture(
            relativeArrivalMilliseconds: 3.5
        )
        let result = try ProtectedDriverCrossoverSumModelAnalyzer()
            .analyze(
                session: session,
                firstProtocolID: lowID,
                secondProtocolID: highID
            )
        XCTAssertEqual(result.bestHypothesis, .retainCurrent)
        XCTAssertNil(result.modeledAdditionalDelayMilliseconds)
        XCTAssertFalse(result.modeledInvertsComparedDriver)
        XCTAssertEqual(result.modeledDeficitReductionDB, 0, accuracy: 0.0001)
        XCTAssertFalse(result.canDeploy)
    }

    func testCrossoverSumModelRejectsMismatchedComplexGrid() throws {
        var (session, lowID, highID) = timingFixture()
        session.captures[3]
            .sharedClockReference?
            .transferFunction.frequenciesHz[15] *= 1.001
        XCTAssertThrowsError(
            try ProtectedDriverCrossoverSumModelAnalyzer()
                .analyze(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        )
    }


    func testLabReportPublishesCrossoverSumModelAsModelOnly() throws {
        let (session, _, _) = timingFixture(
            relativeArrivalMilliseconds: 0.8
        )
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let summary = try XCTUnwrap(
            report.analysisSummaries.first {
                $0.kind == .protectedDriverCrossoverSum
            }
        )
        XCTAssertTrue(summary.available)
        XCTAssertEqual(
            summary.metrics.first {
                $0.name == "Combined-driver capture"
            }?.value,
            "REQUIRED · not yet verified"
        )
        XCTAssertEqual(
            summary.metrics.first {
                $0.name == "Deployment"
            }?.value,
            "Never · model only"
        )
        XCTAssertTrue(summary.metrics.contains {
            $0.name == "Modeled reduction"
                && $0.value.contains("dB")
        })
        XCTAssertTrue(summary.warnings.contains {
            $0.contains("MODEL ONLY")
        })
        XCTAssertTrue(summary.warnings.contains {
            $0.contains("combined-driver crossover capture")
        })
        XCTAssertFalse(report.canDeploy)

        let json = try SpeakerMeasurementLabReportExporter()
            .jsonData(report)
        let jsonText = try XCTUnwrap(
            String(data: json, encoding: .utf8)
        )
        XCTAssertTrue(
            jsonText.contains("protectedDriverCrossoverSum")
        )
        XCTAssertFalse(jsonText.contains("impulseResponse"))
    }

    func testLabReportCrossoverSumIsUnavailableWithoutTimingEvidence() throws {
        let (session, _, _) = timingFixture(
            includeReference: false
        )
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let summary = try XCTUnwrap(
            report.analysisSummaries.first {
                $0.kind == .protectedDriverCrossoverSum
            }
        )
        XCTAssertFalse(summary.available)
        XCTAssertTrue(summary.metrics.isEmpty)
        XCTAssertFalse(summary.warnings.isEmpty)
        XCTAssertFalse(report.canDeploy)
    }

}
