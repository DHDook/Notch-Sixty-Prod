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
        XCTAssertEqual(total.bufferedFrames, 0)
    }

    func testStartupPrimingPolicyUsesPhysicalBufferSize() {
        let policy = AudioStartupPrimingPolicy(outputBufferFrames: 512)
        XCTAssertEqual(policy.targetFrames, 512)
        XCTAssertEqual(policy.timeoutMicroseconds, 250_000)
        XCTAssertEqual(policy.pollIntervalMicroseconds, 250)
    }

    func testStartupPrimingPolicyNeverUsesZeroTargetOrWaitIntervals() {
        let policy = AudioStartupPrimingPolicy(
            outputBufferFrames: 0,
            timeoutMicroseconds: 0,
            pollIntervalMicroseconds: 0
        )
        XCTAssertEqual(policy.targetFrames, 1)
        XCTAssertEqual(policy.timeoutMicroseconds, 1)
        XCTAssertEqual(policy.pollIntervalMicroseconds, 1)
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
