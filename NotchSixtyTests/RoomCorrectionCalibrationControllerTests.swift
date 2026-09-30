import Foundation
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

    private final class PermissionRequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private struct PermissionFixture: MicrophonePermissionRequesting, Sendable {
        let current: MicrophonePermissionStatus
        let requested: MicrophonePermissionStatus
        let requests: PermissionRequestCounter

        init(
            status: MicrophonePermissionStatus,
            requestedStatus: MicrophonePermissionStatus? = nil,
            requests: PermissionRequestCounter = PermissionRequestCounter()
        ) {
            self.current = status
            self.requested = requestedStatus ?? status
            self.requests = requests
        }

        func currentStatus() -> MicrophonePermissionStatus { current }

        func requestAccess() async -> MicrophonePermissionStatus {
            requests.increment()
            return requested
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

    private actor AnalysisGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var waiting = false

        func wait() async {
            await withCheckedContinuation { continuation in
                waiting = true
                self.continuation = continuation
            }
        }

        func isWaiting() -> Bool { waiting }

        func release() {
            continuation?.resume()
            continuation = nil
            waiting = false
        }
    }

    private enum AnalysisFixtureError: Error, LocalizedError {
        case synthetic

        var errorDescription: String? {
            "Synthetic analysis failure."
        }
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

    private func analysisResult(sampleRate: Double = 48_000) -> RoomCorrectionMeasurementAnalysis {
        let response = RoomCorrectionFrequencyResponse(
            frequenciesHz: [100, 1_000],
            magnitudeDB: [0, -1],
            phaseRadians: [0, 0.1]
        )
        let quality = RoomCorrectionMeasurementQuality(
            clipped: false,
            playbackPeakDBFS: -18,
            capturePeakDBFS: -12,
            estimatedNoiseFloorDBFS: -70,
            estimatedSNRDB: 45,
            sweepComplete: true,
            directArrivalSeconds: 0.01,
            usableLowHz: 20,
            usableHighHz: 20_000,
            warnings: []
        )
        let channel = RoomCorrectionChannelMeasurement(
            capturedAt: Date(timeIntervalSince1970: 123),
            rawCapture: [0.1, 0.2],
            impulseResponse: [1, 0],
            transferFunction: response,
            quality: quality
        )
        return RoomCorrectionMeasurementAnalysis(
            sampleRate: sampleRate,
            left: channel,
            right: channel
        )
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
        let requests = PermissionRequestCounter()
        let permission = PermissionFixture(
            status: .notDetermined,
            requestedStatus: .authorized,
            requests: requests
        )
        let controller = RoomCorrectionCalibrationController(
            engine: try engine(output: output),
            inputCatalog: InputCatalogFixture(devices: [input]),
            permissionClient: permission
        )

        XCTAssertEqual(requests.count, 0)
        XCTAssertEqual(controller.state, .idle)

        await controller.requestMicrophonePermission()

        XCTAssertEqual(requests.count, 1)
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
        XCTAssertNil(controller.latestAnalysis)
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

    func testAnalysisPublishesCurrentGenerationAndAdvancesToReviewing() async throws {
        let output = outputDevice()
        let input = inputDevice()
        let transport = TransportFixture()
        let expected = analysisResult()
        let controller = RoomCorrectionCalibrationController(
            engine: try engine(output: output),
            inputCatalog: InputCatalogFixture(devices: [input]),
            permissionClient: PermissionFixture(status: .authorized),
            transportFactory: { _, _, _, _ in transport },
            analysisOperation: { _, _, _ in expected }
        )
        controller.prepareForUse()
        try controller.beginMeasurement()
        _ = try controller.finishMeasurement()

        let published = await controller.analyzeLatestCapture()

        XCTAssertTrue(published)
        XCTAssertEqual(controller.latestAnalysis, expected)
        XCTAssertEqual(controller.state, .reviewing)
        XCTAssertNil(controller.lastErrorDescription)
        XCTAssertTrue(controller.canBeginMeasurement)
    }

    func testAnalysisFailureFailsClosedAndKeepsResultUnpublished() async throws {
        let output = outputDevice()
        let input = inputDevice()
        let transport = TransportFixture()
        let controller = RoomCorrectionCalibrationController(
            engine: try engine(output: output),
            inputCatalog: InputCatalogFixture(devices: [input]),
            permissionClient: PermissionFixture(status: .authorized),
            transportFactory: { _, _, _, _ in transport },
            analysisOperation: { _, _, _ in throw AnalysisFixtureError.synthetic }
        )
        controller.prepareForUse()
        try controller.beginMeasurement()
        _ = try controller.finishMeasurement()

        let published = await controller.analyzeLatestCapture()

        XCTAssertFalse(published)
        XCTAssertNil(controller.latestAnalysis)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.lastErrorDescription, "Synthetic analysis failure.")
    }

    func testCancelledAnalysisCannotPublishStaleResult() async throws {
        let output = outputDevice()
        let input = inputDevice()
        let transport = TransportFixture()
        let gate = AnalysisGate()
        let expected = analysisResult()
        let controller = RoomCorrectionCalibrationController(
            engine: try engine(output: output),
            inputCatalog: InputCatalogFixture(devices: [input]),
            permissionClient: PermissionFixture(status: .authorized),
            transportFactory: { _, _, _, _ in transport },
            analysisOperation: { _, _, _ in
                await gate.wait()
                return expected
            }
        )
        controller.prepareForUse()
        try controller.beginMeasurement()
        _ = try controller.finishMeasurement()

        let analysisTask = Task { await controller.analyzeLatestCapture() }
        while !(await gate.isWaiting()) {
            await Task.yield()
        }

        controller.cancelMeasurement()
        await gate.release()
        let published = await analysisTask.value

        XCTAssertFalse(published)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.activePlan)
        XCTAssertNil(controller.latestCapture)
        XCTAssertNil(controller.latestAnalysis)
        XCTAssertNil(controller.lastErrorDescription)
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
        XCTAssertNil(controller.latestCapture)
        XCTAssertNil(controller.latestAnalysis)
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
