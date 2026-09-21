import CoreAudio
import XCTest
@testable import NotchSixty

final class NotchSixtyTests: XCTestCase {
    func testBootstrapTestBundleRuns() {
        XCTAssertTrue(true)
    }

    func testSampleRateRangeNormalizesBoundsAndMatchesRates() {
        let range = AudioSampleRateRange(minimum: 192_000, maximum: 44_100)
        XCTAssertEqual(range.minimum, 44_100)
        XCTAssertEqual(range.maximum, 192_000)
        XCTAssertTrue(range.contains(96_000))
        XCTAssertFalse(range.contains(384_000))
    }

    func testLifecycleAcceptsProductionStartupPath() throws {
        var machine = AudioLifecycleStateMachine()
        for state in [
            AudioLifecycleState.requestingPermission,
            .creatingTap,
            .creatingAggregate,
            .openingOutput,
            .starting,
            .running,
        ] {
            try machine.transition(to: state)
        }
        XCTAssertEqual(machine.state, .running)
    }

    func testLifecycleAcceptsReconfigurationAndRecoveryPaths() throws {
        var machine = AudioLifecycleStateMachine(initialState: .running)
        try machine.transition(to: .reconfiguring)
        try machine.transition(to: .running)
        try machine.transition(to: .recoveringOutput)
        try machine.transition(to: .running)
        XCTAssertEqual(machine.state, .running)
    }

    func testLifecycleCanRemainRecoveringUntilSelectedOutputReturns() {
        var machine = AudioLifecycleStateMachine(initialState: .running)
        XCTAssertNoThrow(try machine.transition(to: .recoveringOutput))
        XCTAssertEqual(machine.state, .recoveringOutput)
    }

    func testLifecycleRejectsInvalidJumpWithoutMutatingState() {
        var machine = AudioLifecycleStateMachine()
        XCTAssertThrowsError(try machine.transition(to: .running))
        XCTAssertEqual(machine.state, .idle)
    }

    func testStereoFloat32FormatIsAccepted() {
        let format = AudioStreamBasicDescription(
            mSampleRate: 96_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let description = AudioStreamFormatDescription(format)
        XCTAssertTrue(description.isSupportedStereoTransportFormat)
        XCTAssertEqual(description.sampleRate, 96_000)
        XCTAssertEqual(description.channelCount, 2)
    }

    func testNonStereoFormatIsRejected() {
        let format = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        XCTAssertFalse(AudioStreamFormatDescription(format).isSupportedStereoTransportFormat)
    }

    func testTransportCountersAccumulateAndUseLatestBufferedDepth() {
        let first = AudioTransportCounters(
            captureCallbacks: 10,
            outputCallbacks: 9,
            capturedFrames: 5_120,
            deliveredFrames: 4_608,
            gatedOutputCallbacks: 2,
            gatedOutputFrames: 1_024,
            bufferedFrames: 512
        )
        let second = AudioTransportCounters(
            captureCallbacks: 5,
            outputCallbacks: 5,
            capturedFrames: 2_560,
            deliveredFrames: 2_560,
            underrunFrames: 32,
            overrunFrames: 16,
            unsupportedBufferLayouts: 1,
            gatedOutputCallbacks: 3,
            gatedOutputFrames: 1_536,
            bufferedFrames: 0
        )
        let total = first + second
        XCTAssertEqual(total.captureCallbacks, 15)
        XCTAssertEqual(total.outputCallbacks, 14)
        XCTAssertEqual(total.capturedFrames, 7_680)
        XCTAssertEqual(total.deliveredFrames, 7_168)
        XCTAssertEqual(total.underrunFrames, 32)
        XCTAssertEqual(total.overrunFrames, 16)
        XCTAssertEqual(total.unsupportedBufferLayouts, 1)
        XCTAssertEqual(total.gatedOutputCallbacks, 5)
        XCTAssertEqual(total.gatedOutputFrames, 2_560)
        XCTAssertEqual(total.bufferedFrames, 0)
    }

    func testStartupGatePolicyKeepsOneHardwareBufferQueuedAfterOpening() {
        let policy = AudioStartupGatePolicy(outputBufferFrames: 512, sampleRate: 384_000)
        XCTAssertEqual(policy.steadyStateTargetFrames, 512)
        XCTAssertEqual(policy.activationBufferedFrames, 1_024)
        XCTAssertEqual(policy.fadeInFrames, 4_608)
    }

    func testStartupGatePolicyNeverUsesZeroBufferOrFadeFrames() {
        let policy = AudioStartupGatePolicy(outputBufferFrames: 0, sampleRate: 0, fadeInMilliseconds: 0)
        XCTAssertEqual(policy.steadyStateTargetFrames, 1)
        XCTAssertEqual(policy.activationBufferedFrames, 2)
        XCTAssertEqual(policy.fadeInFrames, 1)
    }

    func testStartupGatePolicyAvoidsUInt32Overflow() {
        let policy = AudioStartupGatePolicy(outputBufferFrames: UInt32.max, sampleRate: 384_000)
        XCTAssertEqual(policy.steadyStateTargetFrames, UInt32.max)
        XCTAssertEqual(policy.activationBufferedFrames, UInt32.max)
    }

    @MainActor
    func testSelectionFollowsStableUIDAcrossTransientDeviceIDChange() throws {
        let catalog = StubOutputDeviceCatalog(devices: [
            makeDevice(deviceID: 10, uid: "device-a", name: "Output A"),
            makeDevice(deviceID: 20, uid: "device-b", name: "Output B"),
        ])
        let engine = AudioIOEngine(deviceCatalog: catalog)
        try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "device-b")
        XCTAssertEqual(engine.selectedOutputDevice?.deviceID, 20)

        catalog.devices = [makeDevice(deviceID: 99, uid: "device-b", name: "Output B")]
        try engine.refreshOutputDevices()
        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "device-b")
        XCTAssertEqual(engine.selectedOutputDevice?.deviceID, 99)
    }

    @MainActor
    func testRefreshPreservesSelectedUIDWhenHardwareDisappears() throws {
        let catalog = StubOutputDeviceCatalog(devices: [
            makeDevice(deviceID: 20, uid: "device-b", name: "Output B"),
        ])
        let engine = AudioIOEngine(deviceCatalog: catalog)
        try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "device-b")
        catalog.devices = []
        try engine.refreshOutputDevices()

        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "device-b")
        XCTAssertNil(engine.selectedOutputDevice)
        XCTAssertFalse(engine.diagnosticsSnapshot().selectedOutputPresent)
    }

    @MainActor
    func testSelectingUnavailableOutputFailsWithoutChangingRoute() throws {
        let catalog = StubOutputDeviceCatalog(devices: [
            makeDevice(deviceID: 10, uid: "device-a", name: "Output A"),
        ])
        let engine = AudioIOEngine(
            deviceCatalog: catalog,
            initialRouteConfiguration: AudioRouteConfiguration(selectedOutputUID: "persisted-device")
        )
        try engine.refreshOutputDevices()
        XCTAssertThrowsError(try engine.selectOutput(uid: "missing-device"))
        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "persisted-device")
    }

    private func makeDevice(deviceID: AudioDeviceID, uid: String, name: String) -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: deviceID,
            uid: uid,
            name: name,
            nominalSampleRate: 96_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)]
        )
    }
}

private final class StubOutputDeviceCatalog: OutputDeviceCataloging {
    var devices: [AudioOutputDevice]
    init(devices: [AudioOutputDevice]) { self.devices = devices }
    func outputDevices() throws -> [AudioOutputDevice] { devices }
}
