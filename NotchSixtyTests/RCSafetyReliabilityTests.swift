import CoreAudio
import XCTest
@testable import NotchSixty

/// Regression coverage for the RC safety/reliability fixes: software master
/// volume persistence and start gain, wake/recovery retry policy, activity-based
/// N-channel activation gating, and LFE playback gain.
final class RCSafetyReliabilityTests: XCTestCase {
    // MARK: Master volume

    @MainActor
    func testSoftwareVolumeIsRestoredPerOutputOnFirstSync() throws {
        let store = InMemoryMasterVolumeStore()
        store.stored["dac"] = MasterVolumeConfiguration(level: 0.4, muted: false)
        let engine = makeEngine(store: store)

        try engine.selectOutput(uid: "dac")

        XCTAssertEqual(engine.masterVolumeConfiguration.level, 0.4, accuracy: 1.0e-9)
        XCTAssertEqual(engine.masterVolumeCapabilities.controlMode, .softwareDSP)
    }

    @MainActor
    func testSoftwareVolumeChangesArePersistedForSelectedOutput() throws {
        let store = InMemoryMasterVolumeStore()
        let engine = makeEngine(store: store)
        try engine.selectOutput(uid: "dac")

        try engine.setMasterVolumeLevel(0.6)
        try engine.setMasterMuted(true)

        XCTAssertEqual(store.stored["dac"], MasterVolumeConfiguration(level: 0.6, muted: true))
    }

    @MainActor
    func testResyncForSameOutputDoesNotOverwriteCurrentLevel() throws {
        let store = InMemoryMasterVolumeStore()
        let volume = SoftwareOnlyVolumeController()
        let engine = makeEngine(store: store, volume: volume)
        try engine.selectOutput(uid: "dac")
        try engine.setMasterVolumeLevel(0.6)

        store.stored["dac"] = MasterVolumeConfiguration(level: 0.9, muted: false)
        volume.onExternalChange?()

        XCTAssertEqual(engine.masterVolumeConfiguration.level, 0.6, accuracy: 1.0e-9)
    }

    @MainActor
    func testSwitchingOutputsRestoresEachOutputsOwnLevel() throws {
        let store = InMemoryMasterVolumeStore()
        store.stored["dac"] = MasterVolumeConfiguration(level: 0.3, muted: false)
        store.stored["headphones"] = MasterVolumeConfiguration(level: 0.7, muted: false)
        let engine = makeEngine(store: store)

        try engine.selectOutput(uid: "dac")
        XCTAssertEqual(engine.masterVolumeConfiguration.level, 0.3, accuracy: 1.0e-9)
        try engine.selectOutput(uid: "headphones")
        XCTAssertEqual(engine.masterVolumeConfiguration.level, 0.7, accuracy: 1.0e-9)
        try engine.selectOutput(uid: "dac")
        XCTAssertEqual(engine.masterVolumeConfiguration.level, 0.3, accuracy: 1.0e-9)
    }

    func testUserDefaultsStoreUsesSafeFirstUseLevelAndRoundTrips() throws {
        let suite = "com.dhdook.NotchSixty.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsMasterVolumeStore(defaults: defaults)

        XCTAssertEqual(
            store.restoredSoftwareVolume(forOutputUID: "never-seen"),
            MasterVolumeConfiguration(
                level: UserDefaultsMasterVolumeStore.firstUseSoftwareLevel,
                muted: false
            )
        )
        XCTAssertLessThan(UserDefaultsMasterVolumeStore.firstUseSoftwareLevel, 1.0)

        store.storeSoftwareVolume(MasterVolumeConfiguration(level: 0.55, muted: true), forOutputUID: "dac")
        XCTAssertEqual(
            UserDefaultsMasterVolumeStore(defaults: defaults).restoredSoftwareVolume(forOutputUID: "dac"),
            MasterVolumeConfiguration(level: 0.55, muted: true)
        )
    }

    @MainActor
    func testStereoTransportStartGraphCarriesSoftwareMasterGainAndMute() throws {
        let engine = makeEngine(store: InMemoryMasterVolumeStore())
        try engine.selectOutput(uid: "dac")
        try engine.setMasterVolumeLevel(0.5)

        let graph = try engine.stereoTransportStartGraph(sampleRate: 48_000)
        XCTAssertEqual(graph.masterGainLinear, 0.125, accuracy: 1.0e-6, "0.5 on the cubic software taper")

        try engine.setMasterMuted(true)
        XCTAssertEqual(try engine.stereoTransportStartGraph(sampleRate: 48_000).masterGainLinear, 0)
    }

    func testSoftwareTaperGivesFineLowLevelControl() throws {
        XCTAssertEqual(MasterVolumeConfiguration.softwareTaperGain(forLevel: 1), 1)
        XCTAssertEqual(MasterVolumeConfiguration.softwareTaperGain(forLevel: 0), 0)
        XCTAssertEqual(try XCTUnwrap(MasterVolumeConfiguration.softwareTaperDB(forLevel: 0.5)), -18.06, accuracy: 0.01)
        let topStep = try XCTUnwrap(MasterVolumeConfiguration.softwareTaperDB(forLevel: 15.0 / 16.0))
        XCTAssertEqual(topStep, -1.68, accuracy: 0.01)
        let levels = (1...16).map { Double($0) / 16 }
        let steps = zip(levels.dropFirst(), levels).map {
            MasterVolumeConfiguration.softwareTaperDB(forLevel: $0)!
                - MasterVolumeConfiguration.softwareTaperDB(forLevel: $1)!
        }
        XCTAssertTrue(steps.allSatisfy { $0 > 0 }, "taper is monotonic")
        XCTAssertNil(MasterVolumeConfiguration.softwareTaperDB(forLevel: 0))
    }

    // MARK: Wake and recovery

    func testIdleMayEnterOutputRecoveryForResumeAfterWake() {
        XCTAssertTrue(AudioLifecycleStateMachine.canTransition(from: .idle, to: .recoveringOutput))
        var machine = AudioLifecycleStateMachine()
        XCTAssertNoThrow(try machine.transition(to: .recoveringOutput))
        XCTAssertNoThrow(try machine.transition(to: .stopping))
        XCTAssertNoThrow(try machine.transition(to: .idle))
    }

    func testRecoveryBuildRetriesBackOffAndEventuallyFail() {
        let delays = (1...8).map {
            OutputRecoveryRetryPolicy.buildRetryDelay(afterConsecutiveFailures: $0)
        }
        XCTAssertEqual(delays, [0.5, 1, 2, 4, 8, 10, 10, 10])
        XCTAssertFalse(OutputRecoveryRetryPolicy.shouldFail(afterConsecutiveFailures: 7))
        XCTAssertTrue(OutputRecoveryRetryPolicy.shouldFail(afterConsecutiveFailures: 8))
        XCTAssertEqual(OutputRecoveryRetryPolicy.buildRetryDelay(afterConsecutiveFailures: 1_000), 10)
    }

    // MARK: Realtime underrun

    func testMatchedRateUnderrunFadesPartialBlockAndRearmsGate() throws {
        let bridge = try XCTUnwrap(N60RealtimeAudioBridgeCreate(4_096))
        defer { N60RealtimeAudioBridgeDestroy(bridge) }
        XCTAssertTrue(N60RealtimeAudioBridgePublishDSPGraph(bridge, N60DSPGraphSnapshotMakeUnity(48_000)))
        N60RealtimeAudioBridgeConfigureOutputGate(bridge, 256, 1)

        let harness = StereoIOProcHarness(bridge: bridge)
        harness.capture(frames: 512, value: 0.5)
        _ = harness.render(frames: 256)
        XCTAssertTrue(N60RealtimeAudioBridgeGetSnapshot(bridge).outputGateOpen)

        harness.capture(frames: 100, value: 0.5)
        let full = harness.render(frames: 256)
        XCTAssertEqual(full[200], 0.5, accuracy: 1.0e-3)

        // 100 frames remain for a 256-frame callback.
        let partial = harness.render(frames: 256)
        XCTAssertGreaterThan(partial[0], 0.45)
        XCTAssertLessThan(abs(partial[99]), 0.05, "partial block fades to zero")
        for index in 1..<100 {
            XCTAssertLessThanOrEqual(partial[index], partial[index - 1] + 1.0e-6)
        }
        XCTAssertTrue(partial[100...].allSatisfy { $0 == 0 })
        XCTAssertFalse(N60RealtimeAudioBridgeGetSnapshot(bridge).outputGateOpen, "gate re-armed after underrun")

        // Re-primes before audio resumes.
        harness.capture(frames: 100, value: 0.5)
        XCTAssertTrue(harness.render(frames: 256).allSatisfy { $0 == 0 })
        harness.capture(frames: 400, value: 0.5)
        let resumed = harness.render(frames: 256)
        XCTAssertTrue(N60RealtimeAudioBridgeGetSnapshot(bridge).outputGateOpen)
        XCTAssertEqual(resumed[200], 0.5, accuracy: 1.0e-3)
    }

    // MARK: Tri-amp crossover

    func testTriAmpBandsSumFlatBetweenCrossovers() throws {
        var bass = BassManagementConfiguration()
        bass.enabled = true
        bass.frequencyHz = 800
        bass.upperFrequencyHz = 2_500
        bass.topology = .linkwitzRiley24
        bass.physicalOutputMode = .triAmp
        let sampleRate = 48_000.0

        for frequency in [300.0, 1_000.0, 1_414.0, 2_000.0, 6_000.0] {
            let frameCount = 19_200
            let input = (0..<frameCount).map {
                Float(0.01 * sin(2 * Double.pi * frequency * Double($0) / sampleRate))
            }
            var sum = [Float](repeating: 0, count: frameCount)
            for bus in [SpeakerOutputBus.leftLow, .leftMid, .leftHigh] {
                var driver = SpeakerDriverProcessingConfiguration()
                driver.replace(SpeakerDriverBusProcessingConfiguration(
                    bus: bus,
                    enabled: true,
                    trimDB: 0,
                    polarityInverted: false,
                    delayMilliseconds: 0,
                    limiterEnabled: true,
                    limiterThresholdDBFS: -1
                ))
                let rendered = try SpeakerMeasurementLabProtectedExcitationCompiler().compile(
                    monoSamples: input,
                    sampleRate: sampleRate,
                    targetBus: bus,
                    bassManagement: bass,
                    driverProcessing: driver
                ).renderedSamples
                for index in 0..<frameCount { sum[index] += rendered[index] }
            }
            let steady = frameCount / 2..<frameCount
            let ratioDB = 20 * log10(rms(sum[steady]) / rms(input[steady]))
            XCTAssertEqual(ratioDB, 0, accuracy: 0.1, "tri-amp sum at \(frequency) Hz")
        }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }

    // MARK: HRTF conversion

    func testHRIRResamplingPreservesFrequencyResponse() throws {
        let sourceRate = 48_000.0
        let taps = 256
        var left = [Float](repeating: 0, count: taps)
        var right = [Float](repeating: 0, count: taps)
        left[20] = 0.8
        for index in 20..<taps {
            right[index] = 0.5 * Float(exp(-Double(index - 20) / 6.0))
        }
        let asset = BinauralProfileAsset(
            displayName: "Fixture",
            sampleRate: sourceRate,
            tapCount: taps,
            declaredLatencyFrames: 20,
            measurements: [
                BinauralMeasurement(
                    azimuthDegrees: 30, elevationDegrees: 0, distanceMeters: 1.5,
                    leftIR: left, rightIR: right
                ),
            ]
        )
        for targetRate in [44_100.0, 96_000.0, 192_000.0] {
            let converted = try asset.resampled(to: targetRate)
            XCTAssertEqual(converted.sampleRate, targetRate)
            XCTAssertEqual(converted.tapCount, Int(ceil(Double(taps) * targetRate / sourceRate)))
            XCTAssertEqual(converted.declaredLatencyFrames, Int((20 * targetRate / sourceRate).rounded()))
            for frequency in [100.0, 1_000.0, 8_000.0, 16_000.0] {
                for (source, result) in [
                    (left, converted.measurements[0].leftIR),
                    (right, converted.measurements[0].rightIR),
                ] {
                    let before = magnitudeDB(source, frequency: frequency, sampleRate: sourceRate)
                    let after = magnitudeDB(result, frequency: frequency, sampleRate: targetRate)
                    XCTAssertEqual(after, before, accuracy: 0.1, "\(frequency) Hz at \(targetRate)")
                }
            }
        }
        XCTAssertEqual(try asset.resampled(to: sourceRate), asset)
    }

    private func magnitudeDB(_ ir: [Float], frequency: Double, sampleRate: Double) -> Double {
        var re = 0.0, im = 0.0
        for (n, value) in ir.enumerated() {
            let phase = -2 * Double.pi * frequency * Double(n) / sampleRate
            re += Double(value) * cos(phase)
            im += Double(value) * sin(phase)
        }
        return 20 * log10(max(hypot(re, im), 1.0e-12))
    }

    // MARK: Room project persistence

    func testRoomProjectStoresSamplesInSidecarsAndRoundTrips() throws {
        let (store, root) = makeProjectStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = makeProject(captureFrames: 48_000)

        let url = try store.save(project)
        XCTAssertEqual(url.lastPathComponent, RoomCorrectionProjectStore.projectFileName)
        let json = try Data(contentsOf: url)
        XCTAssertLessThan(json.count, 64 * 1_024, "sample arrays must not be inlined in the JSON")
        let samples = store.projectDirectory(for: project.id)
            .appendingPathComponent(RoomCorrectionProjectStore.sampleDirectoryName)
        let files = try FileManager.default.contentsOfDirectory(atPath: samples.path)
        XCTAssertEqual(files.count, 6, "4 measurement arrays + 2 design tap arrays")
        XCTAssertEqual(try store.load(project.id), project)
    }

    func testRoomProjectReusesUnchangedSidecarsAndRemovesSuperseded() throws {
        let (store, root) = makeProjectStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = makeProject(captureFrames: 4_800)
        try store.save(project)
        let samples = store.projectDirectory(for: project.id)
            .appendingPathComponent(RoomCorrectionProjectStore.sampleDirectoryName)
        let captureFile = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: samples.path)
                .first { $0.contains(".left.capture-") }
        )
        let captureURL = samples.appendingPathComponent(captureFile)
        let before = try FileManager.default.attributesOfItem(atPath: captureURL.path)[.modificationDate] as? Date

        project.name = "Renamed"
        try store.save(project)
        let after = try FileManager.default.attributesOfItem(atPath: captureURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "unchanged samples are not rewritten")

        project.designs = []
        project.selectedDesignID = nil
        try store.save(project)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: samples.path).count, 4)
        XCTAssertEqual(try store.load(project.id), project)
    }

    func testLegacyInlineProjectLoadsAndMigratesOnSave() throws {
        let (store, root) = makeProjectStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = makeProject(captureFrames: 480)
        let legacy = store.legacyProjectURL(for: project.id)
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(project).write(to: legacy)

        XCTAssertEqual(try store.load(project.id), project)
        try store.save(project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try store.load(project.id), project)
    }

    func testMissingSidecarIsReportedAsCorruptProject() throws {
        let (store, root) = makeProjectStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = makeProject(captureFrames: 480)
        try store.save(project)
        let samples = store.projectDirectory(for: project.id)
            .appendingPathComponent(RoomCorrectionProjectStore.sampleDirectoryName)
        let first = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: samples.path).first)
        try FileManager.default.removeItem(at: samples.appendingPathComponent(first))

        XCTAssertThrowsError(try store.load(project.id)) {
            XCTAssertEqual($0 as? RoomCorrectionProjectError, .corruptProject(project.id))
        }
    }

    private func makeProjectStore() -> (RoomCorrectionProjectStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-RCStore-\(UUID().uuidString)", isDirectory: true)
        return (RoomCorrectionProjectStore(rootDirectory: root), root)
    }

    private func makeProject(captureFrames: Int) -> RoomCorrectionProject {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let response = RoomCorrectionFrequencyResponse(
            frequenciesHz: [20, 1_000, 20_000],
            magnitudeDB: [1, 0, -1],
            phaseRadians: nil
        )
        let quality = RoomCorrectionMeasurementQuality(
            clipped: false,
            playbackPeakDBFS: -18,
            capturePeakDBFS: -12,
            estimatedNoiseFloorDBFS: -70,
            estimatedSNRDB: 58,
            sweepComplete: true,
            directArrivalSeconds: 0.012,
            usableLowHz: 25,
            usableHighHz: 19_000,
            warnings: []
        )
        func channel(_ seed: Float) -> RoomCorrectionChannelMeasurement {
            RoomCorrectionChannelMeasurement(
                capturedAt: created,
                rawCapture: (0..<captureFrames).map { seed * sin(Float($0) * 0.01) },
                impulseResponse: (0..<(captureFrames / 4)).map { seed * exp(-Float($0) / 200) },
                transferFunction: response,
                quality: quality
            )
        }
        var project = RoomCorrectionProject(playbackSystemID: UUID(), name: "Sidecar Fixture")
        let position = RoomCorrectionMeasurementPosition(
            name: "Seat",
            sampleRate: 48_000,
            left: channel(0.5),
            right: channel(0.4)
        )
        project.measurements = [position]
        project.aggregate = RoomCorrectionAggregateResponse(
            generatedAt: created,
            includedPositionIDs: [position.id],
            leftResponse: response,
            rightResponse: response
        )
        let design = RoomCorrectionDesign(
            name: "Design",
            createdAt: created,
            sampleRate: 48_000,
            parameters: RoomCorrectionDesignParameters(
                correctionLowHz: 25,
                correctionHighHz: 19_000,
                smoothingOctaves: 1.0 / 6.0,
                maximumBoostDB: 6,
                maximumCutDB: 12,
                requestedTapCount: 1_024
            ),
            filter: RoomCorrectionFilter(
                name: "Design",
                sampleRate: 48_000,
                leftTaps: (0..<1_024).map { $0 == 0 ? 0.9 : 0.001 * Float($0 % 7) },
                rightTaps: (0..<1_024).map { $0 == 0 ? 0.8 : 0.001 * Float($0 % 5) },
                declaredLatencyFrames: 0
            ),
            predictedLeftResponse: response,
            predictedRightResponse: response,
            recommendedHeadroomDB: 3,
            algorithmVersion: "fixture"
        )
        project.designs = [design]
        project.selectedDesignID = design.id
        return project
    }

    // MARK: Working state

    @MainActor
    func testUnsavedContentEditsSurviveRelaunchAndClearOnPresetSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-Working-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("profiles.json")

        let engine = AudioIOEngine(deviceCatalog: FixedOutputCatalog())
        let profiles = ProductProfileController(engine: engine, storageURL: storage)
        profiles.restoreSelectedLayers()
        let savedPreamp = engine.gainConfiguration.inputPreampDB
        try engine.setInputPreampDB(savedPreamp - 4.5)
        XCTAssertTrue(profiles.selectedContentPresetIsDirty)
        profiles.recordWorkingContentStateIfNeeded()

        let relaunchedEngine = AudioIOEngine(deviceCatalog: FixedOutputCatalog())
        let relaunched = ProductProfileController(engine: relaunchedEngine, storageURL: storage)
        relaunched.restoreSelectedLayers()
        XCTAssertEqual(relaunchedEngine.gainConfiguration.inputPreampDB, savedPreamp - 4.5, accuracy: 1.0e-9)
        XCTAssertTrue(relaunched.selectedContentPresetIsDirty, "restored edits remain unsaved")

        let presetID = try XCTUnwrap(relaunched.selectedContentPresetID)
        relaunched.selectContentPreset(presetID)
        XCTAssertFalse(relaunched.selectedContentPresetIsDirty)

        let thirdEngine = AudioIOEngine(deviceCatalog: FixedOutputCatalog())
        let third = ProductProfileController(engine: thirdEngine, storageURL: storage)
        third.restoreSelectedLayers()
        XCTAssertEqual(thirdEngine.gainConfiguration.inputPreampDB, savedPreamp, accuracy: 1.0e-9)
    }

    // MARK: Activation gating

    func testDisabledButEditedPlaybackControlsAreInactive() {
        var playback = PlaybackControlConfiguration()
        XCTAssertFalse(playback.hasActiveImageProcessing)

        playback.speakerCrossfeedAmount = 0.3
        playback.symmetryBalancePosition = 0.4
        playback.crosstalkCancellationAmount = 0.9
        XCTAssertNotEqual(playback, PlaybackControlConfiguration())
        XCTAssertFalse(playback.hasActiveImageProcessing)

        playback.speakerCrossfeedEnabled = true
        XCTAssertTrue(playback.hasActiveImageProcessing)
    }

    func testPlaybackActivityCoversBalanceDelayAndAudition() {
        var balance = PlaybackControlConfiguration()
        balance.balance = -0.2
        XCTAssertTrue(balance.hasActiveImageProcessing)

        var delay = PlaybackControlConfiguration()
        delay.interChannelDelayMs = 0.5
        XCTAssertTrue(delay.hasActiveImageProcessing)

        var audition = PlaybackControlConfiguration()
        audition.auditionMode = .reference
        XCTAssertTrue(audition.hasActiveImageProcessing)

        var bypass = PlaybackControlConfiguration()
        bypass.globalBypassed = true
        XCTAssertFalse(bypass.hasActiveImageProcessing, "Global bypass is gated separately")
        XCTAssertNotNil(LiveNChannelTransportError.globalBypassUnsupported.errorDescription)
    }

    func testDisabledButEditedDynamicsAreInactive() {
        var dynamics = DynamicsConfiguration()
        XCTAssertFalse(dynamics.hasActiveProcessing)

        dynamics.compressor.thresholdDB = -30
        dynamics.oversampling = .four
        XCTAssertNotEqual(dynamics, DynamicsConfiguration())
        XCTAssertFalse(dynamics.hasActiveProcessing)

        dynamics.limiter.enabled = true
        XCTAssertTrue(dynamics.hasActiveProcessing)

        var mono = DynamicsConfiguration()
        mono.stereoMode = .trueMono
        XCTAssertTrue(mono.hasActiveProcessing)
    }

    // MARK: LFE

    func testBassManagedLFEReceivesInBandGainAndLowPass() throws {
        let graph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: fiveOneRoutePlan(bassManagementEnabled: true),
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(enabled: true)
        )

        XCTAssertEqual(graph.bassManagement.lfeGainLinear, Float(pow(10.0, 0.5)), accuracy: 1.0e-4)
        XCTAssertTrue(graph.bassManagement.lfeLowPassEnabled)
        XCTAssertEqual(laneGain(graph, channel: 3), 1.0, accuracy: 1.0e-6,
                       "LFE in-band gain must not be applied twice")
    }

    func testDirectlyMappedLFEReceivesInBandGainWithoutBassManagement() throws {
        let graph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: fiveOneRoutePlan(bassManagementEnabled: false),
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(enabled: false)
        )

        XCTAssertEqual(laneGain(graph, channel: 0), 1.0, accuracy: 1.0e-6)
        XCTAssertEqual(laneGain(graph, channel: 3), Float(pow(10.0, 0.5)), accuracy: 1.0e-4)
    }

    // MARK: Fixtures

    @MainActor
    private func makeEngine(
        store: InMemoryMasterVolumeStore,
        volume: SoftwareOnlyVolumeController = SoftwareOnlyVolumeController()
    ) -> AudioIOEngine {
        let engine = AudioIOEngine(
            deviceCatalog: FixedOutputCatalog(),
            masterVolumeController: volume,
            globalVolumeKeyMonitor: IdleVolumeKeyMonitor(),
            masterVolumeStore: store
        )
        _ = try? engine.refreshOutputDevices()
        return engine
    }

    private func fiveOneRoutePlan(bassManagementEnabled: Bool) -> LiveNChannelOutputRoutePlan {
        LiveNChannelOutputRoutePlan(
            programLayout: .fiveOne,
            orderedDeviceUIDs: ["interface"],
            referenceDeviceUID: "interface",
            physicalChannelCount: 6,
            programPhysicalChannels: bassManagementEnabled
                ? [0, 1, 2, UInt32.max, 4, 5]
                : [0, 1, 2, 3, 4, 5],
            subwooferPhysicalChannels: bassManagementEnabled ? [3] : [],
            subwooferCount: bassManagementEnabled ? 1 : 0,
            bassManagementEnabled: bassManagementEnabled,
            speakerCalibrations: [:],
            subwooferCalibrations: bassManagementEnabled ? [nil] : []
        )
    }

    private func laneGain(_ graph: N60LiveNChannelRenderGraph, channel: Int) -> Float {
        var lanes = graph.laneGraph.lanes
        return withUnsafePointer(to: &lanes) { pointer in
            pointer.withMemoryRebound(
                to: N60ProgramLaneSnapshot.self,
                capacity: Int(N60_MAX_PROGRAM_CHANNELS)
            ) { $0[channel].gainLinear }
        }
    }
}

private final class InMemoryMasterVolumeStore: MasterVolumePersisting {
    var stored: [String: MasterVolumeConfiguration] = [:]

    func restoredSoftwareVolume(forOutputUID uid: String) -> MasterVolumeConfiguration? {
        stored[uid]
    }

    func storeSoftwareVolume(_ configuration: MasterVolumeConfiguration, forOutputUID uid: String) {
        stored[uid] = configuration
    }
}

private final class SoftwareOnlyVolumeController: MasterVolumeDeviceControlling {
    var onExternalChange: (() -> Void)?

    func inspect(deviceID: AudioDeviceID) throws -> MasterVolumeDeviceSnapshot {
        MasterVolumeDeviceSnapshot(capabilities: .softwareOnly, level: nil, muted: nil)
    }

    func setVolume(_ level: Double, deviceID: AudioDeviceID) throws {}
    func setMuted(_ muted: Bool, deviceID: AudioDeviceID) throws {}
    func monitor(deviceID: AudioDeviceID?) throws {}
    func stopMonitoring() {}
}

private final class IdleVolumeKeyMonitor: GlobalVolumeKeyMonitoring {
    var onVolumeIncrement: (() -> Void)?
    var onVolumeDecrement: (() -> Void)?
    var state: GlobalVolumeKeyMonitoringState = .stopped

    func start() throws {}
    func stop() {}
}

private struct FixedOutputCatalog: OutputDeviceCataloging {
    func outputDevices() throws -> [AudioOutputDevice] {
        [
            AudioOutputDevice(
                deviceID: 41,
                uid: "dac",
                name: "DAC",
                nominalSampleRate: 96_000,
                availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)]
            ),
            AudioOutputDevice(
                deviceID: 42,
                uid: "headphones",
                name: "Headphones",
                nominalSampleRate: 48_000,
                availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 192_000)]
            ),
        ]
    }
}

/// Drives the stereo bridge's capture/output IOProcs with interleaved stereo
/// buffers; returns the left channel of each rendered output buffer.
private final class StereoIOProcHarness {
    private let bridge: OpaquePointer
    private var timestamp = AudioTimeStamp()

    init(bridge: OpaquePointer) {
        self.bridge = bridge
    }

    func capture(frames: Int, value: Float) {
        var samples = [Float](repeating: value, count: frames * 2)
        samples.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(buffer.baseAddress)
                )
            )
            var unusedOutput = AudioBufferList()
            _ = N60CaptureIOProc(
                0, &timestamp, &list, &timestamp, &unusedOutput, &timestamp,
                UnsafeMutableRawPointer(bridge)
            )
        }
    }

    func render(frames: Int) -> [Float] {
        var samples = [Float](repeating: -1, count: frames * 2)
        samples.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(buffer.baseAddress)
                )
            )
            var unusedInput = AudioBufferList()
            _ = N60OutputIOProc(
                0, &timestamp, &unusedInput, &timestamp, &list, &timestamp,
                UnsafeMutableRawPointer(bridge)
            )
        }
        return stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
    }
}
