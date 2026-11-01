import Foundation
import XCTest
@testable import NotchSixty

// E24 S0: the hardware boundary for the end-to-end harness. Only what touches Core Audio is
// replaced: the device lists, microphone permission and the measurement transport. Everything
// above those factories is the production default.

/// The 2.1 reference room with three seats. Each seat and each source gets its own arrival time
/// and one smooth resonance, so seat-to-seat differences are real and deterministic.
struct SyntheticReferenceRoom: Sendable {
    let rate: Double
    let seatCount: Int
    let sourcesPerSeat: Int

    func room(measurement index: Int, outputChannel: UInt32) -> ReferenceRoom {
        let seat = index / sourcesPerSeat
        let metres = 2.4 + 0.35 * Double(seat) + 0.2 * Double(outputChannel)
        let frames = Int((metres / 343.0 * rate).rounded())
        let resonance = outputChannel == 2 ? 48.0 + 4.0 * Double(seat) : 90.0 + 15.0 * Double(seat)
        return ReferenceRoom(delayFrames: frames, resonanceHz: resonance, gainDB: 5 - Double(seat))
    }
}

/// Plays a measurement through the real targeted-bridge process function block by block and
/// returns what the microphone would have heard in the reference room. Two passes share the one
/// bridge: the first collects the speaker feed (the bridge writes it), the second replays the
/// room's response as the microphone input (the bridge captures it).
final class ReferenceRoomTransport: MultichannelCalibrationTransporting {
    private let bridge: UnsafeMutablePointer<N60TargetedRoomMeasurementBridge>
    private let room: ReferenceRoom
    private let rate: Double
    private let blockFrames: Int
    private(set) var started = false
    private(set) var cancelled = false

    init(program: RoomCorrectionSweepProgram, inputChannel: Int, outputChannel: UInt32,
         room: ReferenceRoom, blockFrames: Int = 512) throws {
        guard let bridge = program.sweepSamples.withUnsafeBufferPointer({
            N60TargetedRoomMeasurementBridgeCreate(
                $0.baseAddress!, UInt32($0.count), UInt32(program.leadInFrames), UInt32(program.tailFrames),
                UInt32(inputChannel), outputChannel)
        }) else { throw MultichannelCalibrationTransportError.bridgeAllocationFailed }
        self.bridge = bridge
        self.room = room
        self.rate = program.sampleRate
        self.blockFrames = blockFrames
    }

    deinit { N60TargetedRoomMeasurementBridgeDestroy(bridge) }

    func start() throws {
        N60TargetedRoomMeasurementBridgeReset(bridge)
        let total = Int(bridge.pointee.captureFrameCount)
        let silence = [Float](repeating: 0, count: blockFrames)
        var feed = [Float](repeating: 0, count: total)
        var block = [Float](repeating: 0, count: blockFrames)
        var done = 0
        while done < total {
            let n = min(blockFrames, total - done)
            let consumed = silence.withUnsafeBufferPointer { mic in
                block.withUnsafeMutableBufferPointer { out in
                    N60TargetedRoomMeasurementProcessProgramStrided(
                        bridge, mic.baseAddress!, 1, nil, 0, out.baseAddress!, 1, nil, 0, UInt32(n))
                }
            }
            for i in 0..<Int(consumed) { feed[done + i] = block[i] }
            done += n
        }
        var heard = room.render(feed, rate: rate)
        // A real microphone always has a noise floor; the analyzer estimates SNR from it.
        // Deterministic LCG noise at about -75 dBFS.
        var state: UInt32 = 0x1234_5678
        for i in heard.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            heard[i] += (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.0003
        }
        N60TargetedRoomMeasurementBridgeReset(bridge)
        done = 0
        while done < total {
            let n = min(blockFrames, total - done)
            _ = heard.withUnsafeBufferPointer { mic in
                block.withUnsafeMutableBufferPointer { out in
                    N60TargetedRoomMeasurementProcessProgramStrided(
                        bridge, mic.baseAddress! + done, 1, nil, 0, out.baseAddress!, 1, nil, 0, UInt32(n))
                }
            }
            done += n
        }
        started = true
    }

    func snapshot() -> N60TargetedRoomMeasurementBridgeSnapshot? {
        N60TargetedRoomMeasurementBridgeGetSnapshot(bridge)
    }

    func finishAndMaterialize() throws -> MultichannelCalibrationCapture {
        let snapshot = N60TargetedRoomMeasurementBridgeGetSnapshot(bridge)
        guard snapshot.complete else { throw MultichannelCalibrationTransportError.incompleteCapture }
        var samples = [Float](repeating: 0, count: Int(snapshot.totalFrameCount))
        let copied = samples.withUnsafeMutableBufferPointer {
            N60TargetedRoomMeasurementBridgeCopyCapture(bridge, $0.baseAddress!, UInt32($0.count))
        }
        guard copied == snapshot.totalFrameCount else { throw MultichannelCalibrationTransportError.incompleteCapture }
        return MultichannelCalibrationCapture(samples: samples)
    }

    func cancel() { cancelled = true }
}

/// Counts measurements so seat `k` gets the room for seat `k` (the campaign is seat-major).
@MainActor
final class ReferenceRoomTransportFactory {
    let layout: SyntheticReferenceRoom
    private(set) var made = 0

    init(layout: SyntheticReferenceRoom) { self.layout = layout }

    func make(program: RoomCorrectionSweepProgram, inputChannel: Int, outputChannel: UInt32) throws -> any MultichannelCalibrationTransporting {
        defer { made += 1 }
        return try ReferenceRoomTransport(
            program: program, inputChannel: inputChannel, outputChannel: outputChannel,
            room: layout.room(measurement: made, outputChannel: outputChannel))
    }
}

// MARK: - Offline device boundary

struct OfflineOutputCatalog: OutputDeviceCataloging {
    let devices: [AudioOutputDevice]
    func outputDevices() throws -> [AudioOutputDevice] { devices }
}

struct OfflineInputCatalog: InputDeviceCataloging {
    let devices: [AudioInputDevice]
    func inputDevices() throws -> [AudioInputDevice] { devices }
}

struct OfflinePermission: MicrophonePermissionRequesting, Sendable {
    var status: MicrophonePermissionStatus
    func currentStatus() -> MicrophonePermissionStatus { status }
    func requestAccess() async -> MicrophonePermissionStatus { status }
}

/// The whole production object graph for the setup window, with only the boundary offline.
@MainActor
struct OfflineSetupRig {
    let rate: Double
    let engine: AudioIOEngine
    let profiles: ProductProfileController
    let microphone: RoomCorrectionCalibrationController
    let calibration: MultichannelCalibrationController
    let model: SystemSetupFlowModel
    let transports: ReferenceRoomTransportFactory
    let root: URL

    static let outputUID = "e24-reference-output"
    static let inputUID = "e24-reference-mic"

    init(rate: Double, permission: MicrophonePermissionStatus = .authorized, seats: Int = 3) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-E24S0-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.rate = rate
        let ranges = [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)]
        let output = AudioOutputDevice(
            deviceID: 9_001, uid: Self.outputUID, name: "Reference 2.1 Interface", nominalSampleRate: rate,
            availableSampleRateRanges: ranges, outputChannelCount: 6)
        let input = AudioInputDevice(
            deviceID: 9_002, uid: Self.inputUID, name: "Reference Measurement Mic", nominalSampleRate: rate,
            availableSampleRateRanges: ranges)
        engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: Self.outputUID)
        profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        microphone = RoomCorrectionCalibrationController(
            engine: engine, inputCatalog: OfflineInputCatalog(devices: [input]),
            permissionClient: OfflinePermission(status: permission))
        microphone.prepareForUse()
        _ = try? microphone.refreshInputDevices()
        microphone.selectInput(uid: Self.inputUID)
        // Short sweeps keep the suite fast; the analysis path is the production one.
        microphone.sweepDurationSeconds = 0.4
        microphone.sweepLeadInSeconds = 0.05
        microphone.sweepTailSeconds = 0.25
        microphone.sweepFadeSeconds = 0.01
        microphone.sweepStartFrequencyHz = 30
        microphone.sweepEndFrequencyHz = min(20_000, 0.4 * rate)
        let layout = SyntheticReferenceRoom(rate: rate, seatCount: seats, sourcesPerSeat: 3)
        let transports = ReferenceRoomTransportFactory(layout: layout)
        self.transports = transports
        calibration = MultichannelCalibrationController(
            engine: engine, profiles: profiles, microphone: microphone,
            store: MultichannelCalibrationCampaignStore(rootDirectory: root.appendingPathComponent("campaigns")),
            transportFactory: { _, _, _, inputChannel, program, outputChannel in
                try MainActor.assumeIsolated {
                    try transports.make(program: program, inputChannel: inputChannel, outputChannel: outputChannel)
                }
            })
        model = SystemSetupFlowModel(
            engine: engine, profiles: profiles, microphone: microphone, calibration: calibration,
            services: ProductionSystemSetupServices.production(engine: engine),
            sessions: SystemSetupSessionStore(directory: root.appendingPathComponent("sessions")),
            roomProjectsDirectory: root.appendingPathComponent("RoomCorrection"))
    }

    /// A stereo pair plus one subwoofer on the reference interface (2.1).
    func installTwoPointOneProfile() throws {
        var bass = profiles.selectedSystemProfile?.state.bassManagement ?? engine.bassManagementConfiguration
        bass.enabled = true
        try profiles.replaceSelectedSystemBassManagement(bass)
        let uid = Self.outputUID
        try profiles.replaceSelectedSystemOutputDeviceProfile(OutputDeviceProfileConfiguration(
            enabled: true, programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(role: .frontLeft, destination: PhysicalOutputEndpoint(deviceUID: uid, channelIndex: 0)),
                SemanticSpeakerOutputAssignment(role: .frontRight, destination: PhysicalOutputEndpoint(deviceUID: uid, channelIndex: 1)),
            ],
            subwooferAssignments: [
                PhysicalSubwooferOutputAssignment(index: 0, destination: PhysicalOutputEndpoint(deviceUID: uid, channelIndex: 2)),
            ]))
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }
}
