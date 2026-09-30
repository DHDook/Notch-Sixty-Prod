import XCTest
@testable import NotchSixty

@MainActor
final class RoomCorrectionCalibrationControllerTests: XCTestCase {
    private struct OutputCatalogFixture: OutputDeviceCataloging {
        let devices: [AudioOutputDevice]
        func outputDevices() throws -> [AudioOutputDevice] { devices }
    }

    private struct InputCatalogFixture: InputDeviceCataloging {
        let devices: [AudioInputDevice]
        func inputDevices() throws -> [AudioInputDevice] { devices }
    }

    private final class PermissionFixture: MicrophonePermissionRequesting, @unchecked Sendable {
        var status: MicrophonePermissionStatus
        let requestedStatus: MicrophonePermissionStatus
        private(set) var requestCount = 0

        init(
            status: MicrophonePermissionStatus,
            requestedStatus: MicrophonePermissionStatus? = nil
        ) {
            self.status = status
            self.requestedStatus = requestedStatus ?? status
        }

        func currentStatus() -> MicrophonePermissionStatus { status }

        func requestAccess() async -> MicrophonePermissionStatus {
            requestCount += 1
            status = requestedStatus
            return status
        }
    }

    private final class TransportFixture: RoomCorrectionCalibrationTransporting {
        var startCount = 0
        var finishCount = 0
        var cancelCount = 0
        var snapshotValue: N60RoomMeasurementBridgeSnapshot?
        let capture: RoomCorrectionCalibrationCapture

        init(capture: RoomCorrectionCalibrationCapture = .init(left: [1], right: [2])) {
            self.capture = capture
        }

        func start() throws { startCount += 1 }
        func snapshot() -> N60RoomMeasurementBridgeSnapshot? { snapshotValue }

        func finishAndMaterialize() throws -> RoomCorrectionCalibrationCapture {
            finishCount += 1
            return capture
        }

        func cancel() { cancelCount += 1 }
    }

    private func outputDevice() -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: 11,
            uid: "output-fixture",
            name: "Output Fixture",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [
                AudioSampleRateRange(minimum: 48_000, maximum: 48_000),
            ]
        )
    }

    private func inputDevice() -> AudioInputDevice {
        AudioInputDevice(
            deviceID: 22,
            uid: "input-fixture",
            name: "Measurement Mic",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [
                AudioSampleRateRange(minimum: 48_000, maximum: 48_000),
            ]
        )
    }

    private func engine(output: AudioOutputDevice) throws -> AudioIOEngine {
        let engine = AudioIOEngine(deviceCatalog: OutputCatalogFixture(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: output.uid)
        return engine
    }

    func testPrepareForUseEnumeratesAuthorizedInputsAndSelectsFirstDevice() throws {
        let output = outputDevice()
        let input = inputDevice()
        let permission = PermissionFixture(status: .authorized)
        let controller = RoomCorrectionCalibrationController(
            engine: try engine(output: output),
            inputCatalog: InputCatalogFixture(devices: [input]),
            permissionClient: permission
        )

        controller.prepareForUse()

        XCTAssertEqual(controller.permissionStatus, .authorized)
        XCTAssertEqual(controller.inputDevices, [input])
        XCTAssertEqual(controller.selectedInputUID, input.uid)
        XCTAssertEqual(controller.selectedInputChannelIndex, 0)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertNil(controller.lastErrorDescription)
    }

    func testPermissionRequestIsUserInitiatedAndAdvancesToReadyOnlyWhenAuthorized() async throws {
        let output = outputDevice()
        let input = inputDevice()
        let permission = PermissionFixture(status: .notDetermined, requestedStatus: .authorized)
        let controller = RoomCorrectionCalibrationController(
            engine: try engine(output: output),
            inputCatalog: InputCatalogFixture(devices: [input]),
            permissionClient: permission
        )

        XCTAssertEqual(permission.requestCount, 0)
        XCTAssertEqual(controller.state, .idle)

        await controller.requestMicrophonePermission()

        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(controller.permissionStatus, .authorized)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.selectedInputUID, input.uid)
    }

    func testDeniedPermissionFailsClosedWithoutCreatingMeasurementTransport() throws {
        let output = outputDevice()
        let permission = PermissionFixture(status: .denied)
        var factoryCallCount = 0
        let controller = RoomCorrectionCalibrationController(
            engine: try engine(output: output),
            inputCatalog: InputCatalogFixture(devices: [inputDevice()]),
            permissionClient: permission,
            transportFactory: { _, _, _, _ in
                factoryCallCount += 1
                return TransportFixture()
            }
        )

        XCTAssertThrowsError(try controller.beginMeasurement()) { error in
            XCTAssertEqual(
                error as? RoomCorrectionCalibrationControllerError,
                .microphonePermissionRequired(.denied)
            )
        }
        XCTAssertEqual(factoryCallCount, 0)
        XCTAssertEqual(controller.state, .idle)
    }

    func testMeasurementClaimsHardwareOnlyFromIdleAndHandsCaptureToAnalysis() throws {
        let output = outputDevice()
        let input = inputDevice()
        let permission = PermissionFixture(status: .authorized)
        let transport = TransportFixture(
            capture: RoomCorrectionCalibrationCapture(left: [0.1, 0.2], right: [0.3, 0.4])
        )
        var capturedPlan: RoomCorrectionMeasurementPlan?
        var capturedInputChannel: Int?
        let controller = RoomCorrectionCalibrationController(
            engine: try engine(output: output),
            inputCatalog: InputCatalogFixture(devices: [input]),
            permissionClient: permission,
            transportFactory: { receivedOutput, receivedInput, channel, plan in
                XCTAssertEqual(receivedOutput, output)
                XCTAssertEqual(receivedInput, input)
                capturedInputChannel = channel
                capturedPlan = plan
                return transport
            }
        )
        controller.prepareForUse()
        try controller.selectInputChannel(index: 2)

        try controller.beginMeasurement()

        XCTAssertEqual(controller.state, .measuring)
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(capturedInputChannel, 2)
        XCTAssertEqual(capturedPlan?.program.sampleRate, 48_000)
        XCTAssertEqual(capturedPlan?.program.settings.levelDBFS, -18)
        XCTAssertNotNil(controller.activePlan)

        let capture = try controller.finishMeasurement()

        XCTAssertEqual(capture, transport.capture)
        XCTAssertEqual(controller.latestCapture, transport.capture)
        XCTAssertEqual(controller.state, .analyzing)
        XCTAssertEqual(transport.finishCount, 1)
        XCTAssertEqual(transport.cancelCount, 0)
    }

    func testAtomicCompletionPollMaterializesOnlyAfterRealtimeTimelineCompletes() throws {
        let output = outputDevice()
        let input = inputDevice()
        let transport = TransportFixture()
        let controller = RoomCorrectionCalibrationController(
            engine: try engine(output: output),
            inputCatalog: InputCatalogFixture(devices: [input]),
            permissionClient: PermissionFixture(status: .authorized),
            transportFactory: { _, _, _, _ in transport }
        )
        controller.prepareForUse()
        try controller.beginMeasurement()

        var incomplete = N60RoomMeasurementBridgeSnapshot()
        incomplete.frameCursor = 50
        incomplete.totalFrameCount = 100
        incomplete.complete = false
        transport.snapshotValue = incomplete

        XCTAssertFalse(try controller.finishMeasurementIfComplete())
        XCTAssertEqual(controller.state, .measuring)
        XCTAssertEqual(controller.measurementProgress, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(transport.finishCount, 0)

        var complete = incomplete
        complete.frameCursor = 100
        complete.complete = true
        transport.snapshotValue = complete

        XCTAssertTrue(try controller.finishMeasurementIfComplete())
        XCTAssertEqual(controller.state, .analyzing)
        XCTAssertEqual(controller.latestCapture, transport.capture)
        XCTAssertEqual(transport.finishCount, 1)
    }

    func testCancelReleasesCalibrationTransportAndReturnsIdle() throws {
        let output = outputDevice()
        let input = inputDevice()
        let transport = TransportFixture()
        let controller = RoomCorrectionCalibrationController(
            engine: try engine(output: output),
            inputCatalog: InputCatalogFixture(devices: [input]),
            permissionClient: PermissionFixture(status: .authorized),
            transportFactory: { _, _, _, _ in transport }
        )
        controller.prepareForUse()
        try controller.beginMeasurement()

        controller.cancelMeasurement()

        XCTAssertEqual(transport.cancelCount, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.activePlan)
    }

    func testHardwareClaimEligibilityIsStrictlyIdle() {
        for state in AudioLifecycleState.allCases {
            XCTAssertEqual(
                RoomCorrectionCalibrationController.canClaimHardware(audioLifecycle: state),
                state == .idle,
                "Calibration hardware ownership must be exclusive from ordinary DSP state \(state.rawValue)"
            )
        }
    }
}
