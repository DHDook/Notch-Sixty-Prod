import Foundation

// E13 S7 (G1): the real-transport environment for the BRIR capture flow.
//
// Speaker passes reuse the multichannel calibration route (the user's speaker arrangement and its
// physical output channel for the role); headphone passes build a plain stereo route on the selected
// output. Both go through the E11 multi-microphone runner on one shared-clock input, so the ear
// microphones are two channels of one interface. The runner cancels the transport on failure or
// cancellation, which restores any device rate the transport changed.

@MainActor
final class BRIRLiveCaptureEnvironment: BRIRCaptureEnvironment {
    /// Headphone sweeps go straight to the ears, so they play well below the room-measurement level.
    nonisolated static let headphoneSweepLevelDBFS = -30.0
    nonisolated static let timeoutMarginSeconds = 15.0

    typealias Transport = (_ routePlan: LiveNChannelOutputRoutePlan, _ outputs: [AudioOutputDevice],
                           _ program: RoomCorrectionSweepProgram, _ physicalChannel: UInt32) -> MultiMicTransportFactory

    private let calibration: MultichannelCalibrationController
    private let store: BinauralProfileAssetStore
    private let transport: Transport
    private var sessionOpen = false

    init(
        calibration: MultichannelCalibrationController,
        store: BinauralProfileAssetStore = BinauralProfileAssetStore(),
        transport: @escaping Transport = { routePlan, outputs, program, channel in
            MultichannelCalibrationTransport.multiMicFactory(
                routePlan: routePlan, outputs: outputs, program: program,
                physicalOutputChannelIndex: channel, referenceProgram: nil)
        }
    ) {
        self.calibration = calibration
        self.store = store
        self.transport = transport
    }

    func beginSession() throws {
        try calibration.beginExternalPass()
        sessionOpen = true
    }

    func finishSession() {
        guard sessionOpen else { return }
        sessionOpen = false
        calibration.endExternalPass()
    }

    func speakerPass(plan: BRIRCapturePlan, step: BRIRCaptureStep) async throws -> BRIRPassOutcome {
        let pass = try calibration.prepareSeatPass(for: .speaker(step.role))
        guard abs(pass.sampleRate - plan.sampleRate) < 0.5 else { throw BRIRLiveCaptureError.sampleRateChanged }
        return try await run(
            plan: plan, program: pass.program, sampleRate: pass.sampleRate,
            factory: transport(pass.routePlan, pass.outputs, pass.program, pass.physicalOutputChannel))
    }

    func headphonePass(plan: BRIRCapturePlan, channel: Int) async throws -> BRIRPassOutcome {
        guard let output = calibration.engine.selectedOutputDevice,
              output.outputChannelCount >= 2, channel >= 0, channel < 2 else {
            throw BRIRLiveCaptureError.headphoneOutputRequired
        }
        guard abs(output.nominalSampleRate - plan.sampleRate) < 0.5 else { throw BRIRLiveCaptureError.sampleRateChanged }
        _ = MeasurementPlaybackPolicy.stopPlaybackIfRunning(calibration.engine)
        let settings = calibration.microphone.sweepSettings(
            sampleRate: output.nominalSampleRate, levelDBFS: Self.headphoneSweepLevelDBFS)
        let program = try RoomCorrectionSweepGenerator().makeProgram(settings: settings)
        let route = LiveNChannelOutputRoutePlan(
            programLayout: .stereo, orderedDeviceUIDs: [output.uid], referenceDeviceUID: output.uid,
            physicalChannelCount: output.outputChannelCount, programPhysicalChannels: [0, 1],
            subwooferPhysicalChannels: [], subwooferCount: 0, bassManagementEnabled: false,
            speakerCalibrations: [:], subwooferCalibrations: [])
        return try await run(
            plan: plan, program: program, sampleRate: output.nominalSampleRate,
            factory: transport(route, [output], program, UInt32(channel)))
    }

    func save(_ asset: BinauralProfileAsset) throws -> BinauralProfileReference {
        try store.save(asset)
    }

    /// The pass layout: the first sweep of the program, starting after its lead-in. A repeated-sweep
    /// train still carries the first sweep at the same place; later ones fall outside the BRIR length.
    private func run(
        plan: BRIRCapturePlan, program: RoomCorrectionSweepProgram, sampleRate: Double, factory: MultiMicTransportFactory
    ) async throws -> BRIRPassOutcome {
        let pass = MultiMicPass(
            sweep: program.singleSweep, sweepStartFrame: program.leadInFrames, referenceChirp: nil, chirpStartFrame: 0)
        let timeout = Double(program.captureFrameCount) / sampleRate + Self.timeoutMarginSeconds
        let result = try await BRIRCaptureProcessor.captureChecked(
            plan: plan, pass: pass, timeoutSeconds: timeout, makeTransport: factory)
        return BRIRPassOutcome(left: result.left, right: result.right, quality: result.quality)
    }
}

enum BRIRLiveCaptureError: Error, Equatable, LocalizedError {
    case sampleRateChanged
    case headphoneOutputRequired

    var errorDescription: String? {
        switch self {
        case .sampleRateChanged: "The output rate changed since the capture started. Cancel and start again."
        case .headphoneOutputRequired: "Select your two-channel headphone output before capturing the compensation."
        }
    }
}
