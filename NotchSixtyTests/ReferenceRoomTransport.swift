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
    /// E24 S5b1: the rooms the seats after the first hear, in `additionalSeats` order (the K-microphone pass). Each seat
    /// has its own seeded noise and an optional clock offset in frames (its capture starts that many frames late).
    var seatRooms: [ReferenceRoom] = []
    var seatClockOffsetFrames: [Int] = []
    /// Burst corruption: (seat index in pass order, frame range, amplitude) added to that seat's capture.
    var bursts: [(seat: Int, frames: Range<Int>, amplitude: Float)] = []
    /// A seat whose microphone delivers digital silence.
    var silentSeats: Set<Int> = []
    private var seatCaptures: [[Float]] = []
    /// E24 S5b2: the timing chirp's own output channel and, per seat in pass order, the room that speaker has to the seat.
    private let referenceProgram: MultichannelReferenceProgram?
    var referenceRooms: [ReferenceRoom] = []
    /// Per seat in pass order, how loudly the chirp reaches it (0 hides it).
    var referenceGains: [Float] = []
    /// Clock drift per seat in pass order, in ppm: a sample is dropped every 1e6/ppm frames, as an uncompensated
    /// device would slip against the output clock.
    var seatDriftPPM: [Double] = []

    init(program: RoomCorrectionSweepProgram, inputChannel: Int, outputChannel: UInt32,
         room: ReferenceRoom, blockFrames: Int = 512,
         outputSweepSamples: [Float]? = nil, referenceProgram: MultichannelReferenceProgram? = nil) throws {
        self.referenceProgram = referenceProgram
        guard let bridge = (outputSweepSamples ?? program.sweepSamples).withUnsafeBufferPointer({
            N60TargetedRoomMeasurementBridgeCreate(
                $0.baseAddress!, UInt32($0.count), UInt32(program.leadInFrames), UInt32(program.tailFrames),
                UInt32(inputChannel), outputChannel)
        }) else { throw MultichannelCalibrationTransportError.bridgeAllocationFailed }
        self.bridge = bridge
        self.room = room
        self.rate = program.sampleRate
        self.blockFrames = blockFrames
        if let referenceProgram {
            let attached = referenceProgram.samples.withUnsafeBufferPointer {
                N60TargetedRoomMeasurementBridgeAttachReferenceProgram(
                    bridge, $0.baseAddress, UInt32($0.count), UInt32(referenceProgram.startFrame), referenceProgram.outputChannelIndex)
            }
            guard attached else { throw MultichannelCalibrationTransportError.invalidOutputProgram }
        }
    }

    deinit { N60TargetedRoomMeasurementBridgeDestroy(bridge) }

    func start() throws {
        N60TargetedRoomMeasurementBridgeReset(bridge)
        let total = Int(bridge.pointee.captureFrameCount)
        let silence = [Float](repeating: 0, count: blockFrames)
        var feed = [Float](repeating: 0, count: total)
        var referenceFeed = [Float](repeating: 0, count: total)
        var block = [Float](repeating: 0, count: blockFrames)
        var referenceBlock = [Float](repeating: 0, count: blockFrames)
        var done = 0
        while done < total {
            let n = min(blockFrames, total - done)
            let hasReference = referenceProgram != nil
            let consumed = silence.withUnsafeBufferPointer { mic in
                block.withUnsafeMutableBufferPointer { out in
                    referenceBlock.withUnsafeMutableBufferPointer { ref in
                        N60TargetedRoomMeasurementProcessProgramStrided(
                            bridge, mic.baseAddress!, 1, nil, 0, out.baseAddress!, 1,
                            hasReference ? ref.baseAddress : nil, hasReference ? 1 : 0, UInt32(n))
                    }
                }
            }
            for i in 0..<Int(consumed) { feed[done + i] = block[i]; referenceFeed[done + i] = referenceBlock[i] }
            done += n
        }
        func hear(_ room: ReferenceRoom, seed: UInt32, offset: Int, seat: Int) -> [Float] {
            var heard = room.render(feed, rate: rate)
            if referenceProgram != nil, seat < referenceRooms.count {
                let gain = seat < referenceGains.count ? referenceGains[seat] : 1
                for (i, v) in referenceRooms[seat].render(referenceFeed, rate: rate).enumerated() { heard[i] += gain * v }
            }
            if offset > 0 { heard = [Float](repeating: 0, count: offset) + heard.dropLast(offset) }
            if seat < seatDriftPPM.count, seatDriftPPM[seat] > 0 {
                // The input clock runs fast against the output clock: a smooth time warp, read with a windowed sinc
                // (a drift-compensating aggregate resamples rather than slipping samples).
                let ratio = 1 + seatDriftPPM[seat] * 1e-6
                let half = 32
                let source = heard
                for i in heard.indices {
                    let position = Double(i) * ratio
                    let centre = Int(position.rounded(.down))
                    var sum = 0.0
                    let lo = max(0, centre - half + 1), hi = min(source.count - 1, centre + half)
                    if lo > hi { heard[i] = 0; continue }
                    for j in lo...hi {
                        let x = position - Double(j)
                        let sinc = x == 0 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                        let window = 0.5 + 0.5 * cos(Double.pi * x / Double(half))
                        sum += Double(source[j]) * sinc * window
                    }
                    heard[i] = Float(sum)
                }
            }
            // A real microphone always has a noise floor; the analyzer estimates SNR from it.
            // Deterministic LCG noise at about -75 dBFS.
            var state = seed
            for i in heard.indices {
                state = state &* 1_664_525 &+ 1_013_904_223
                heard[i] += (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.0003
            }
            for burst in bursts where burst.seat == seat {
                for i in burst.frames where i < heard.count { heard[i] += burst.amplitude * (i % 2 == 0 ? 1 : -1) }
            }
            return silentSeats.contains(seat) ? [Float](repeating: 0, count: heard.count) : heard
        }
        let heard = hear(room, seed: 0x1234_5678, offset: seatClockOffsetFrames.first ?? 0, seat: 0)
        seatCaptures = seatRooms.enumerated().map { k, seatRoom in
            hear(seatRoom, seed: 0x1234_5678 &+ UInt32(k + 1) &* 7_919,
                 offset: k + 1 < seatClockOffsetFrames.count ? seatClockOffsetFrames[k + 1] : 0, seat: k + 1)
        }
        N60TargetedRoomMeasurementBridgeReset(bridge)
        done = 0
        while done < total {
            let n = min(blockFrames, total - done)
            let hasReference = referenceProgram != nil
            _ = heard.withUnsafeBufferPointer { mic in
                block.withUnsafeMutableBufferPointer { out in
                    referenceBlock.withUnsafeMutableBufferPointer { ref in
                        N60TargetedRoomMeasurementProcessProgramStrided(
                            bridge, mic.baseAddress! + done, 1, nil, 0, out.baseAddress!, 1,
                            hasReference ? ref.baseAddress : nil, hasReference ? 1 : 0, UInt32(n))
                    }
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
        return MultichannelCalibrationCapture(samples: samples, seatSamples: seatCaptures)
    }

    func cancel() { cancelled = true }
}

/// E24 S5b1: the K-microphone pass is the same transport with extra seat rooms.
typealias ReferenceRoomMultiMicTransport = ReferenceRoomTransport

/// Counts measurements so seat `k` gets the room for seat `k` (the campaign is seat-major).
@MainActor
final class ReferenceRoomTransportFactory {
    let layout: SyntheticReferenceRoom
    private(set) var made = 0

    init(layout: SyntheticReferenceRoom) { self.layout = layout }

    /// E24 S5b1: the K-microphone pass. Seat `k` listens on input channel `k` of the reference interface, so the room it
    /// hears is the one a sequential pass of seat `k` hears (the campaign is seat-major, three sources per seat).
    /// Called from the capture task (off the main actor), so this state is lock-guarded, not actor-isolated.
    private let multiMicLock = NSLock()
    nonisolated(unsafe) var clockOffsetFrames: [Int] = []
    nonisolated(unsafe) var configure: (@Sendable (ReferenceRoomTransport) -> Void)?
    nonisolated(unsafe) private var recordedPasses: [(primary: MultichannelSeatInput, additional: [MultichannelSeatInput])] = []
    nonisolated var passes: [(primary: MultichannelSeatInput, additional: [MultichannelSeatInput])] {
        multiMicLock.lock(); defer { multiMicLock.unlock() }; return recordedPasses
    }
    nonisolated var passCount: Int { passes.count }

    /// Which seat of the room a microphone input hears; by default its channel index (one interface, channel per seat).
    nonisolated(unsafe) var seatOfInput: @Sendable (MultichannelSeatInput) -> Int = { $0.channelIndex }
    /// E24 S5b2: per input device UID, a clock offset in frames and a drift in ppm (seats on that device share them).
    nonisolated(unsafe) var deviceClock: [String: (offsetFrames: Int, driftPPM: Double)] = [:]
    nonisolated(unsafe) private var recordedPassSweeps: [(chirp: Bool, selfChirp: Bool)] = []
    nonisolated var passSweeps: [(chirp: Bool, selfChirp: Bool)] {
        multiMicLock.lock(); defer { multiMicLock.unlock() }; return recordedPassSweeps
    }

    nonisolated func makeMultiMic(program: RoomCorrectionSweepProgram, outputChannel: UInt32,
                      primary: MultichannelSeatInput, additional: [MultichannelSeatInput],
                      outputSweepSamples: [Float]? = nil, referenceProgram: MultichannelReferenceProgram? = nil) throws -> any MultichannelCalibrationTransporting {
        multiMicLock.lock()
        recordedPasses.append((primary, additional))
        recordedPassSweeps.append((referenceProgram != nil || outputSweepSamples != nil, outputSweepSamples != nil))
        multiMicLock.unlock()
        func room(_ input: MultichannelSeatInput) -> ReferenceRoom {
            layout.room(measurement: seatOfInput(input) * layout.sourcesPerSeat + Int(outputChannel), outputChannel: outputChannel)
        }
        func referenceRoom(_ input: MultichannelSeatInput) -> ReferenceRoom {
            layout.room(measurement: seatOfInput(input) * layout.sourcesPerSeat, outputChannel: 0)
        }
        let transport = try ReferenceRoomTransport(
            program: program, inputChannel: primary.channelIndex, outputChannel: outputChannel, room: room(primary),
            outputSweepSamples: outputSweepSamples, referenceProgram: referenceProgram)
        transport.seatRooms = additional.map(room)
        transport.referenceRooms = ([primary] + additional).map(referenceRoom)
        let inputs = [primary] + additional
        if deviceClock.isEmpty {
            transport.seatClockOffsetFrames = clockOffsetFrames
        } else {
            transport.seatClockOffsetFrames = inputs.map { deviceClock[$0.device.uid]?.offsetFrames ?? 0 }
            transport.seatDriftPPM = inputs.map { deviceClock[$0.device.uid]?.driftPPM ?? 0 }
        }
        configure?(transport)
        return transport
    }

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
    let levelTransports = OfflineLevelTransportFactory()
    let trialPlayer: OfflineTrialSweepPlayer
    let root: URL
    /// The ABX playback boundary (E24 S9): a recording fake, because no Core Audio session runs offline.
    let abxPlayer = FakeABXPlayer()

    static let outputUID = "e24-reference-output"
    static let inputUID = "e24-reference-mic"

    static let secondInputUID = "e24-reference-mic-b"

    init(rate: Double, permission: MicrophonePermissionStatus = .authorized, seats: Int = 3, secondMicrophone: Bool = false) throws {
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
        let secondInput = AudioInputDevice(
            deviceID: 9_003, uid: Self.secondInputUID, name: "Reference Measurement Mic B", nominalSampleRate: rate,
            availableSampleRateRanges: ranges)
        engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: Self.outputUID)
        engine.unifiedGraphEnabled = true  // the production default (the legacy kernel is a flag)
        profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        microphone = RoomCorrectionCalibrationController(
            engine: engine, inputCatalog: OfflineInputCatalog(devices: secondMicrophone ? [input, secondInput] : [input]),
            permissionClient: OfflinePermission(status: permission))
        microphone.prepareForUse()
        _ = try? microphone.refreshInputDevices()
        microphone.selectInput(uid: Self.inputUID)
        // Short sweeps keep the suite fast; the analysis path is the production one.
        microphone.sweepDurationSeconds = 1.5
        microphone.sweepLeadInSeconds = 0.05
        microphone.sweepTailSeconds = 0.25
        microphone.sweepFadeSeconds = 0.01
        microphone.sweepStartFrequencyHz = 30
        microphone.sweepEndFrequencyHz = min(20_000, 0.4 * rate)
        let layout = SyntheticReferenceRoom(rate: rate, seatCount: seats, sourcesPerSeat: 3)
        let trialPlayer = OfflineTrialSweepPlayer(room: layout.room(measurement: 0, outputChannel: 0), rate: rate)
        self.trialPlayer = trialPlayer
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
            services: ProductionSystemSetupServices.production(
                engine: engine, profiles: profiles, microphone: microphone, calibration: calibration,
                seats: CalibrationSeatMeasurer(calibration: calibration, pollSeconds: 0.005, transport: { pass in
                    { primary, additional in
                        try transports.makeMultiMic(
                            program: pass.program, outputChannel: pass.physicalOutputChannel,
                            primary: primary, additional: additional,
                            outputSweepSamples: pass.outputSweepSamples, referenceProgram: pass.referenceProgram)
                    }
                }),
                levelTransport: levelTransports.factory, trialPlayback: trialPlayer, abx: abxPlayer),
            sessions: SystemSetupSessionStore(directory: root.appendingPathComponent("sessions")),
            roomProjectsDirectory: root.appendingPathComponent("RoomCorrection"),
            abxDirectory: root.appendingPathComponent("ABX"))
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

/// E24 S1: the offline boundary of the level session. A pump thread stands in for the Core Audio IOProc: it calls the
/// production `N60LevelSessionProcess` with a synthetic microphone (a quiet sine) and collects what the lanes carry.
final class OfflineLevelSessionPump: LevelSessionTransporting, @unchecked Sendable {
    private let context: UnsafeMutableRawPointer
    private let laneCount: Int
    private let rate: Double
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?
    private var peaks: [Float]
    private(set) var started = false
    private(set) var cancelled = false
    var didStopCleanly: Bool { true }

    init(context: OpaquePointer, laneCount: Int, rate: Double) {
        self.context = UnsafeMutableRawPointer(context)
        self.laneCount = laneCount
        self.rate = rate
        peaks = Array(repeating: 0, count: laneCount)
    }

    /// Largest absolute sample seen per lane so far.
    var lanePeaks: [Float] { lock.lock(); defer { lock.unlock() }; return peaks }

    func start() throws {
        running = true
        started = true
        let block = 256
        let blockSeconds = Double(block) / rate
        let thread = Thread { [self] in
            let ctx = OpaquePointer(context)
            var mic = [Float](repeating: 0, count: block)
            let storage = (0..<laneCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
            defer { storage.forEach { $0.deallocate() } }
            var pointers: [UnsafeMutablePointer<Float>?] = storage
            var strides = [UInt32](repeating: 1, count: laneCount)
            var phase = 0.0
            while true {
                lock.lock(); let go = running; lock.unlock()
                if !go { break }
                for i in 0..<block { mic[i] = 0.01 * Float(sin(phase)); phase += 2 * .pi * 1_000 / rate }
                _ = mic.withUnsafeBufferPointer { m in
                    N60LevelSessionProcess(ctx, m.baseAddress, 1, &pointers, &strides, UInt32(block))
                }
                lock.lock()
                for i in 0..<laneCount {
                    for f in 0..<block { peaks[i] = max(peaks[i], abs(storage[i][f])) }
                }
                lock.unlock()
                Thread.sleep(forTimeInterval: blockSeconds)
            }
        }
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        while let t = thread, !t.isFinished, t.isExecuting { Thread.sleep(forTimeInterval: 0.002) }
    }

    func cancel() { cancelled = true; stop() }
}

/// Records what the session handed the transport factory.
@MainActor
final class OfflineLevelTransportFactory {
    private(set) var pumps: [OfflineLevelSessionPump] = []
    private(set) var requests: [LevelSessionRequest] = []
    var failure: Error?

    var factory: LevelSessionTransportFactory {
        { [unowned self] request, context, channels in
            try MainActor.assumeIsolated {
                if let failure = self.failure { throw failure }
                let pump = OfflineLevelSessionPump(context: context, laneCount: channels.count, rate: request.sampleRate)
                self.pumps.append(pump)
                self.requests.append(request)
                return pump
            }
        }
    }
}

/// E24 S3a: the offline boundary of the live check. It renders the sweep through the real unified graph (the lane plan the
/// candidate carries) and the main seat's reference room, in place of the generator on the live graph and the microphone.
@MainActor
final class OfflineTrialSweepPlayer: TrialSweepPlaying {
    let room: ReferenceRoom
    let rate: Double
    var preparationFailure: RoomCorrectionTrialError?
    private(set) var sweepsPlayed = 0
    private(set) var stops = 0

    /// E24 S3c: with joint bass installed the sweep also reaches the main seat through each subwoofer (the generator sits
    /// ahead of bass management). Each path is the sub lane's published stage, the sub's gain, delay and polarity, and the
    /// sub's reference room. `mainDelaySeconds` is the lane alignment delay on the measured lane.
    struct SubPath { var lane: Int; var room: ReferenceRoom; var gainDB: Double; var delaySeconds: Double; var inverted: Bool }
    var subPaths: [SubPath] = []
    var mainDelaySeconds = 0.0

    init(room: ReferenceRoom, rate: Double) { self.room = room; self.rate = rate }

    func prepare() throws { if let preparationFailure { throw preparationFailure } }

    private func delayed(_ x: [Float], seconds: Double) -> [Float] {
        let frames = Int((seconds * rate).rounded())
        return frames > 0 ? [Float](repeating: 0, count: frames) + x.dropLast(frames) : x
    }

    func playSweep(_ candidate: RoomCorrectionDeployCandidate) async throws -> [Float] {
        try prepare()
        sweepsPlayed += 1
        // The offline graph is the 6-lane reference layout; the plan's stage and mask are the production ones.
        var graphCandidate = candidate
        graphCandidate.lanePlan.laneCount = 6
        var mixed = room.render(delayed(try OfflineGraphTrialHost.renderGraph(graphCandidate, rate: rate), seconds: mainDelaySeconds), rate: rate)
        for path in subPaths {
            // Move the sub lane's stage onto the measured lane so the same graph renders it.
            var sub = graphCandidate
            sub.lanePlan.stages = sub.lanePlan.stages.compactMap { stage in
                guard stage.laneMask & (UInt64(1) << UInt64(path.lane)) != 0 else { return nil }
                var moved = stage
                moved.laneMask = UInt64(1) << UInt64(sub.measuredLane)
                return moved
            }
            guard !sub.lanePlan.stages.isEmpty else { continue }
            let gain = Float(pow(10.0, path.gainDB / 20) * (path.inverted ? -1 : 1))
            let heard = path.room.render(
                delayed(try OfflineGraphTrialHost.renderGraph(sub, rate: rate), seconds: path.delaySeconds), rate: rate)
            for index in mixed.indices where index < heard.count { mixed[index] += gain * heard[index] }
        }
        return mixed
    }

    func stop() { stops += 1 }
}
