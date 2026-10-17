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
        XCTAssertEqual(graph.masterGainLinear, 0.5, accuracy: 1.0e-6)

        try engine.setMasterMuted(true)
        XCTAssertEqual(try engine.stereoTransportStartGraph(sampleRate: 48_000).masterGainLinear, 0)
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
