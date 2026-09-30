import Combine
import Foundation

protocol RoomCorrectionCalibrationTransporting: AnyObject {
    func start() throws
    func snapshot() -> N60RoomMeasurementBridgeSnapshot?
    func finishAndMaterialize() throws -> RoomCorrectionCalibrationCapture
    func cancel()
}

extension RoomCorrectionCalibrationTransport: RoomCorrectionCalibrationTransporting {}

typealias RoomCorrectionCalibrationTransportFactory = (
    AudioOutputDevice,
    AudioInputDevice,
    Int,
    RoomCorrectionMeasurementPlan
) throws -> any RoomCorrectionCalibrationTransporting

enum RoomCorrectionCalibrationControllerError: Error, Equatable, LocalizedError {
    case microphonePermissionRequired(MicrophonePermissionStatus)
    case noMeasurementInputSelected
    case noPlaybackOutputSelected
    case playbackMustBeIdle(AudioLifecycleState)
    case invalidInputChannel(Int)
    case measurementAlreadyActive
    case measurementNotActive

    var errorDescription: String? {
        switch self {
        case .microphonePermissionRequired(let status):
            switch status {
            case .notDetermined:
                return "Microphone access is required before room measurement can begin."
            case .restricted:
                return "Microphone access is restricted for this account or Mac."
            case .denied:
                return "Microphone access is denied. Enable microphone access for Notch Sixty in System Settings before measuring the room."
            case .authorized:
                return "Microphone access is authorized."
            }
        case .noMeasurementInputSelected:
            return "Select a measurement microphone before starting room calibration."
        case .noPlaybackOutputSelected:
            return "Select the Playback System output device before starting room calibration."
        case .playbackMustBeIdle(let state):
            return "Stop normal DSP playback before measuring the room. The playback engine is currently \(state.rawValue)."
        case .invalidInputChannel(let index):
            return "Measurement microphone channel \(index + 1) is invalid."
        case .measurementAlreadyActive:
            return "A room measurement is already active."
        case .measurementNotActive:
            return "No room measurement is active."
        }
    }
}

@MainActor
final class RoomCorrectionCalibrationController: ObservableObject {
    let engine: AudioIOEngine

    private let inputCatalog: any InputDeviceCataloging
    private let permissionClient: any MicrophonePermissionRequesting
    private let transportFactory: RoomCorrectionCalibrationTransportFactory
    private let sweepGenerator = RoomCorrectionSweepGenerator()
    private var stateMachine = RoomCorrectionCalibrationStateMachine()
    private var activeTransport: (any RoomCorrectionCalibrationTransporting)?

    @Published private(set) var state: RoomCorrectionCalibrationState = .idle
    @Published private(set) var permissionStatus: MicrophonePermissionStatus
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var selectedInputUID: String?
    @Published private(set) var selectedInputChannelIndex = 0
    @Published private(set) var activePlan: RoomCorrectionMeasurementPlan?
    @Published private(set) var latestCapture: RoomCorrectionCalibrationCapture?
    @Published private(set) var lastErrorDescription: String?

    @Published var sweepStartFrequencyHz = 20.0
    @Published var sweepEndFrequencyHz = 20_000.0
    @Published var sweepDurationSeconds = 5.0
    @Published var sweepLevelDBFS = -18.0
    @Published var sweepLeadInSeconds = 0.5
    @Published var sweepTailSeconds = 1.0
    @Published var sweepFadeSeconds = 0.02
    @Published var interPassSettlingSeconds = 0.25

    init(
        engine: AudioIOEngine,
        inputCatalog: any InputDeviceCataloging = CoreAudioInputDeviceCatalog(),
        permissionClient: any MicrophonePermissionRequesting = AVFoundationMicrophonePermissionClient(),
        transportFactory: @escaping RoomCorrectionCalibrationTransportFactory = { output, input, channel, plan in
            try RoomCorrectionCalibrationTransport(
                output: output,
                input: input,
                inputChannelIndex: channel,
                plan: plan
            )
        }
    ) {
        self.engine = engine
        self.inputCatalog = inputCatalog
        self.permissionClient = permissionClient
        self.transportFactory = transportFactory
        self.permissionStatus = permissionClient.currentStatus()
    }

    var selectedInputDevice: AudioInputDevice? {
        guard let selectedInputUID else { return nil }
        return inputDevices.first { $0.uid == selectedInputUID }
    }

    var selectedOutputDevice: AudioOutputDevice? { engine.selectedOutputDevice }

    var canBeginMeasurement: Bool {
        permissionStatus == .authorized
            && selectedInputDevice != nil
            && selectedOutputDevice != nil
            && Self.canClaimHardware(audioLifecycle: engine.lifecycleState)
            && activeTransport == nil
            && (state == .ready || state == .reviewing)
    }

    static func canClaimHardware(audioLifecycle: AudioLifecycleState) -> Bool {
        audioLifecycle == .idle
    }

    func prepareForUse() {
        permissionStatus = permissionClient.currentStatus()
        guard permissionStatus == .authorized else { return }
        do {
            try refreshInputDevices()
            lastErrorDescription = nil
        } catch {
            recordFailure(error)
        }
    }

    func requestMicrophonePermission() async {
        if state == .failed {
            stateMachine.cancelToIdle()
            publishState()
        }
        guard state == .idle else { return }

        do {
            try stateMachine.transition(to: .requestingPermission)
            publishState()
            permissionStatus = await permissionClient.requestAccess()
            guard permissionStatus == .authorized else {
                let error = RoomCorrectionCalibrationControllerError
                    .microphonePermissionRequired(permissionStatus)
                stateMachine.fail()
                publishState()
                lastErrorDescription = error.localizedDescription
                return
            }

            try stateMachine.transition(to: .enumeratingInputs)
            publishState()
            _ = try discoverInputs()
            try stateMachine.transition(to: .ready)
            publishState()
            lastErrorDescription = nil
        } catch {
            recordFailure(error)
        }
    }

    @discardableResult
    func refreshInputDevices() throws -> [AudioInputDevice] {
        permissionStatus = permissionClient.currentStatus()
        guard permissionStatus == .authorized else {
            throw RoomCorrectionCalibrationControllerError
                .microphonePermissionRequired(permissionStatus)
        }

        if state == .failed {
            stateMachine.cancelToIdle()
            publishState()
        }
        if state == .idle {
            try stateMachine.transition(to: .enumeratingInputs)
            publishState()
        }

        let devices = try discoverInputs()
        if state == .enumeratingInputs {
            try stateMachine.transition(to: .ready)
            publishState()
        }
        lastErrorDescription = nil
        return devices
    }

    func selectInput(uid: String?) {
        guard activeTransport == nil else { return }
        guard let uid else {
            selectedInputUID = nil
            selectedInputChannelIndex = 0
            return
        }
        guard inputDevices.contains(where: { $0.uid == uid }) else { return }
        selectedInputUID = uid
        selectedInputChannelIndex = 0
        lastErrorDescription = nil
    }

    func selectInputChannel(index: Int) throws {
        guard activeTransport == nil else {
            throw RoomCorrectionCalibrationControllerError.measurementAlreadyActive
        }
        guard index >= 0 else {
            throw RoomCorrectionCalibrationControllerError.invalidInputChannel(index)
        }
        selectedInputChannelIndex = index
        lastErrorDescription = nil
    }

    /// Claims the physical output only when ordinary DSP playback is fully idle.
    /// The controller intentionally does not stop or later resume the normal DSP
    /// transport on the user's behalf.
    func beginMeasurement() throws {
        guard activeTransport == nil else {
            throw RoomCorrectionCalibrationControllerError.measurementAlreadyActive
        }
        permissionStatus = permissionClient.currentStatus()
        guard permissionStatus == .authorized else {
            throw RoomCorrectionCalibrationControllerError
                .microphonePermissionRequired(permissionStatus)
        }
        guard Self.canClaimHardware(audioLifecycle: engine.lifecycleState) else {
            throw RoomCorrectionCalibrationControllerError
                .playbackMustBeIdle(engine.lifecycleState)
        }
        guard let output = selectedOutputDevice else {
            throw RoomCorrectionCalibrationControllerError.noPlaybackOutputSelected
        }
        guard let input = selectedInputDevice else {
            throw RoomCorrectionCalibrationControllerError.noMeasurementInputSelected
        }
        guard selectedInputChannelIndex >= 0 else {
            throw RoomCorrectionCalibrationControllerError.invalidInputChannel(selectedInputChannelIndex)
        }

        do {
            if state == .idle {
                try stateMachine.transition(to: .ready)
                publishState()
            }
            guard state == .ready || state == .reviewing else {
                throw RoomCorrectionCalibrationSessionError.invalidTransition(
                    from: state,
                    to: .arming
                )
            }
            try stateMachine.transition(to: .arming)
            publishState()

            let settings = RoomCorrectionSweepSettings(
                sampleRate: output.nominalSampleRate,
                startFrequencyHz: sweepStartFrequencyHz,
                endFrequencyHz: sweepEndFrequencyHz,
                durationSeconds: sweepDurationSeconds,
                levelDBFS: sweepLevelDBFS,
                leadInSeconds: sweepLeadInSeconds,
                tailSeconds: sweepTailSeconds,
                fadeSeconds: sweepFadeSeconds
            )
            let program = try sweepGenerator.makeProgram(settings: settings)
            let plan = try RoomCorrectionMeasurementPlan(
                program: program,
                settlingSeconds: interPassSettlingSeconds
            )
            let transport = try transportFactory(
                output,
                input,
                selectedInputChannelIndex,
                plan
            )
            activePlan = plan
            activeTransport = transport
            try transport.start()

            try stateMachine.transition(to: .measuring)
            publishState()
            latestCapture = nil
            lastErrorDescription = nil
        } catch {
            activeTransport?.cancel()
            activeTransport = nil
            activePlan = nil
            recordFailure(error)
            throw error
        }
    }

    func measurementSnapshot() -> N60RoomMeasurementBridgeSnapshot? {
        activeTransport?.snapshot()
    }

    var measurementProgress: Double {
        guard let snapshot = measurementSnapshot(), snapshot.totalFrameCount > 0 else { return 0 }
        return min(max(Double(snapshot.frameCursor) / Double(snapshot.totalFrameCount), 0), 1)
    }

    /// Polls the atomic realtime snapshot and materializes capture data only after
    /// the dedicated IOProc timeline is complete. Returns true exactly when this
    /// call completed the active measurement.
    @discardableResult
    func finishMeasurementIfComplete() throws -> Bool {
        guard state == .measuring, let transport = activeTransport else { return false }
        guard transport.snapshot()?.complete == true else { return false }
        _ = try finishMeasurement()
        return true
    }

    /// Called after the realtime transport reports completion. Analysis is the
    /// next Slice-D owner of the captured samples; no acoustic DSP runs here.
    @discardableResult
    func finishMeasurement() throws -> RoomCorrectionCalibrationCapture {
        guard state == .measuring, let transport = activeTransport else {
            throw RoomCorrectionCalibrationControllerError.measurementNotActive
        }
        do {
            let capture = try transport.finishAndMaterialize()
            activeTransport = nil
            latestCapture = capture
            try stateMachine.transition(to: .analyzing)
            publishState()
            lastErrorDescription = nil
            return capture
        } catch {
            activeTransport?.cancel()
            activeTransport = nil
            recordFailure(error)
            throw error
        }
    }

    func cancelMeasurement() {
        activeTransport?.cancel()
        activeTransport = nil
        activePlan = nil
        stateMachine.cancelToIdle()
        publishState()
        lastErrorDescription = nil
    }

    func resetAfterFailure() {
        activeTransport?.cancel()
        activeTransport = nil
        activePlan = nil
        stateMachine.cancelToIdle()
        publishState()
        lastErrorDescription = nil
    }

    private func discoverInputs() throws -> [AudioInputDevice] {
        let devices = try inputCatalog.inputDevices()
        inputDevices = devices
        if let selectedInputUID, devices.contains(where: { $0.uid == selectedInputUID }) {
            return devices
        }
        selectedInputUID = devices.first?.uid
        selectedInputChannelIndex = 0
        return devices
    }

    private func publishState() {
        state = stateMachine.state
    }

    private func recordFailure(_ error: Error) {
        activeTransport?.cancel()
        activeTransport = nil
        if state != .idle && state != .failed {
            stateMachine.fail()
        }
        publishState()
        lastErrorDescription = error.localizedDescription
    }
}
