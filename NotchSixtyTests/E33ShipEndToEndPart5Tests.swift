import AudioToolbox
import AVFAudio
import SwiftUI
import XCTest
@testable import NotchSixty

/// E33 S11b part 5 (G109): the remaining end-to-end cases through production wiring at the eight rates, with
/// `e33.page-enhancements` on: S12 to S15 on a 5.1 session (the page's starting point to the graph the engine builds for a
/// wide session), S16 (a provoked clip to the History card), S17 (a 5.1 session's view choice to the analysis worker) and
/// S22 to S25 (a plug-in through the rack planner, live edit, rack bypass and the front pair of a 5.1 session).
@MainActor
final class E33ShipEndToEndPart5Tests: XCTestCase {
    /// E33 S11d: the page enhancements are graduated, so the nightly flags-off matrix (which forces every graduated
    /// flag off, and off wins over a test override) cannot run these flag-on cases; the flags-off path is covered by
    /// the rest of the suite under the matrix and by the flag-off cases here in the normal run.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(ProcessInfo.processInfo.environment[FeatureFlags.graduatedOffEnvironmentKey] == "1",
                      "the flags-off matrix forces e33.page-enhancements off")
    }

    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let flags = FeatureFlags()
    private let fiveOneRoles = OutputProgramLayout.fiveOne.roles

    override func setUp() {
        super.setUp()
        flags.setEnabled(true, for: .eqPageEnhancements)
        flags.setEnabled(true, for: .dynamicsExtras)
    }

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    // MARK: S12 to S15: a 5.1 session

    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_433, uid: "e33ship5-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "e33ship5-out")
        return engine
    }

    private var fiveOnePlan: LiveNChannelOutputRoutePlan {
        LiveNChannelOutputRoutePlan(
            programLayout: .fiveOne, orderedDeviceUIDs: ["interface"], referenceDeviceUID: "interface",
            physicalChannelCount: 6, programPhysicalChannels: [5, 4, 3, N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED, 1, 0],
            subwooferPhysicalChannels: [], subwooferCount: 0, bassManagementEnabled: false,
            speakerCalibrations: [:], subwooferCalibrations: [])
    }

    /// The 5.1 graph the engine builds for what the Dynamics page set: program DSP from the engine, then the production
    /// translator for N-channel sessions.
    private func fiveOneSpec(_ engine: AudioIOEngine, rate: Double) throws -> (UnifiedGraphSpec, UnifiedGraphProgramDSP) {
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: fiveOneRoles))
        let program = try XCTUnwrap(try engine.makeUnifiedProgramDSP(sampleRate: rate, shape: shape, virtualSpeakers: false, subwooferCount: 0))
        let configuration = try UnifiedGraphTranslator.nChannelEligibility(
            routePlan: fiveOnePlan, sampleRate: rate, gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(), programDSP: program).get()
        return (try configuration.makeSpec(), program)
    }

    private func render(_ spec: UnifiedGraphSpec, input: [[Float]]) throws -> [[Float]] {
        let host = try UnifiedGraphHost(spec: spec)
        defer { host.release() }
        var out = [[Float]](repeating: [], count: input.count)
        var position = 0
        while position < input[0].count {
            let count = min(512, input[0].count - position)
            let result = try host.processOffline(input: input.map { Array($0[position..<position + count]) }, frames: count)
            for lane in 0..<input.count { out[lane] += result[lane] }
            position += count
        }
        return out
    }

    /// Level of the 1 kHz component (correlation over whole cycles is not needed at this length).
    private func toneDB(_ x: ArraySlice<Float>, rate: Double) -> Double {
        var re = 0.0, im = 0.0
        for (k, v) in x.enumerated() {
            let phase = 2 * Double.pi * 1_000 * Double(k) / rate
            re += Double(v) * cos(phase); im += Double(v) * sin(phase)
        }
        return 20 * log10((re * re + im * im).squareRoot() * 2 / Double(x.count))
    }

    private func rmsDB(_ x: ArraySlice<Float>) -> Double {
        20 * log10((x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))).squareRoot())
    }

    /// Quiet speech on the centre, loud music on the fronts and surrounds, a loud effect on the LFE.
    private func film(
        rate: Double, seconds: Double, centreAmplitude: Double, shape: UnifiedGraphLayoutShape,
        musicAmplitude: Double = 0.3, lfeAmplitude: Double = 0.5, carrierAmplitude: Double = 0
    ) -> [[Float]] {
        let frames = Int(rate * seconds)
        let centre = shape.centerLane ?? 2, lfe = shape.lfeLane ?? 3
        return (0..<fiveOneRoles.count).map { lane in
            (0..<frames).map { i in
                let t = Double(i) / rate
                if lane == centre {
                    // Speech-band tone under a loud out-of-band programme carrier, as the core's centre leveller case does.
                    return Float(centreAmplitude * sin(2 * Double.pi * 1_000 * t) + carrierAmplitude * sin(2 * Double.pi * 8_000 * t))
                }
                if lane == lfe { return Float(lfeAmplitude * sin(2 * Double.pi * 60 * t)) }
                return Float(musicAmplitude * sin(2 * Double.pi * (300 + 90 * Double(lane)) * t))
            }
        }
    }

    /// S12 to S15 on 5.1: Clear dialogue (a starting point, saved with the configuration) lifts speech on the centre lane
    /// against the music (the speech-lift lab render), keeps every lane under the ceiling, leaves the LFE out of the
    /// detector, and the page's "Acts on" line is the table the translator used.
    func testClearDialogueOnAFiveOneSessionLiftsSpeechAtEveryRate() throws {
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: fiveOneRoles))
        let centre = try XCTUnwrap(shape.centerLane), lfe = try XCTUnwrap(shape.lfeLane)
        for rate in rates {
            let control = try engine(rate: rate)
            let (controlSpec, _) = try fiveOneSpec(control, rate: rate)
            let e = try engine(rate: rate)
            try e.replaceDynamicsConfiguration(DynamicsStartingPoint.clearDialogue.applying(to: e.dynamicsConfiguration))
            // Saved with the profile: the recipe survives an encode and decode.
            let saved = try JSONDecoder().decode(DynamicsConfiguration.self, from: JSONEncoder().encode(e.dynamicsConfiguration))
            XCTAssertEqual(saved, e.dynamicsConfiguration, "starting point survives save and load at \(rate)")
            let (spec, program) = try fiveOneSpec(e, rate: rate)
            XCTAssertTrue(program.surroundDetector)
            XCTAssertNotNil(spec.stages.first { $0.kind == N60_STAGE_LOUDNESS.rawValue }, "the leveller is in the 5.1 graph, \(rate)")
            XCTAssertNil(controlSpec.stages.first { $0.kind == N60_STAGE_LOUDNESS.rawValue })
            if let protection = program.protection { XCTAssertTrue(protection.autoRelease, "Auto Release reaches the 5.1 protection stage, \(rate)") }

            let input = film(rate: rate, seconds: 3, centreAmplitude: 0.02, shape: shape, carrierAmplitude: 0.3)
            let on = try render(spec, input: input), off = try render(controlSpec, input: input)
            let tail = Int(rate * 2)..<Int(rate * 3)
            // The compressor is linked and ducks every lane; the leveller lifts the centre against the rest of the programme.
            let frontLane = 0
            let lift = (toneDB(on[centre][tail], rate: rate) - toneDB(off[centre][tail], rate: rate)) - (rmsDB(on[frontLane][tail]) - rmsDB(off[frontLane][tail]))
            // The settled lift is about 2.4 dB at 44.1 and 48 kHz and about 1.4 dB from 88.2 kHz up (G110), so the floor is 1 dB.
            XCTAssertGreaterThan(lift, 1, "speech on the centre is lifted against the fronts by the leveller at \(rate): \(lift) dB")
            for lane in 0..<fiveOneRoles.count {
                XCTAssertTrue(on[lane].allSatisfy { $0.isFinite }, "lane \(lane) at \(rate)")
                XCTAssertLessThanOrEqual(on[lane].dropFirst(Int(rate * 0.5)).map { abs($0) }.max() ?? 0, 0.95, "ceiling, lane \(lane) at \(rate)")
            }
            XCTAssertEqual(rmsDB(on[lfe][tail]) - rmsDB(off[lfe][tail]), 0, accuracy: 1.0, "the LFE keeps its level at \(rate)")

            for module in [ProductionDynamicsModule.compressor, .dialogueLeveler] {
                let mapping = DynamicsSessionMapping.mapping(for: module, shape: shape, virtualSpeakers: false)
                if module == .compressor { XCTAssertFalse(mapping.detectorLanes.contains(lfe), "the detector leaves the LFE out") }
                XCTAssertFalse(DynamicsSessionMapping.actsOnText(for: module, shape: shape, virtualSpeakers: false).isEmpty)
            }
        }
    }

    /// S13 and S12 through the production translator: a 5.1 film signal with the compressor on keeps the mains level
    /// under a loud LFE, at every rate (the same graph the engine builds, not a hand-built program).
    func testCompressorOnAFiveOneSessionIgnoresTheLFEAtEveryRate() throws {
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: fiveOneRoles))
        let lfe = try XCTUnwrap(shape.lfeLane)
        for rate in rates {
            let e = try engine(rate: rate)
            var d = DynamicsConfiguration()
            d.compressor.enabled = true
            try e.replaceDynamicsConfiguration(d)
            let (spec, _) = try fiveOneSpec(e, rate: rate)
            let compressor = try XCTUnwrap(spec.stages.first { $0.kind == N60_STAGE_COMPRESSOR.rawValue })
            XCTAssertEqual(compressor.params.last, Float(lfe + 1), "the compressor excludes the LFE at \(rate)")
            let input = film(rate: rate, seconds: 1, centreAmplitude: 0.05, shape: shape, musicAmplitude: 0.05, lfeAmplitude: 0.9)
            let out = try render(spec, input: input)
            let tail = Int(rate * 0.5)..<Int(rate)
            for lane in 0..<fiveOneRoles.count where lane != lfe {
                XCTAssertEqual(rmsDB(out[lane][tail]) - rmsDB(input[lane][tail]), 0, accuracy: 0.5, "lane \(lane) keeps its level at \(rate)")
            }
        }
    }

    // MARK: S16: a provoked clip reaches the History card

    /// A clip on the input, read the way the meter hub's poll reads it, is noted by the history the card shows; the card's
    /// Clear button empties it.
    func testProvokedClipReachesTheHistoryCard() throws {
        let history = SessionEventHistory(store: nil)
        let channels: [String: MeterChannelReading] = [
            "input.L": MeterChannelReading(peakLinear: 1, rmsLinear: 0.5, overRangeSamples: 6, truePeakLinear: 1.2),
            "input.R": MeterChannelReading(peakLinear: 0.2, rmsLinear: 0.1, overRangeSamples: 0, truePeakLinear: nil),
        ]
        let diagnostics = try engine(rate: 48_000).diagnosticsSnapshot()
        let page = HostedPage(ProductionEventHistoryCard(history: history))
        XCTAssertTrue(page.has("This session", kind: .segmented), "the card is on the page")
        history.observe(SessionEventSample.make(channels: channels, diagnostics: diagnostics, protection: [], now: Date()))
        XCTAssertEqual(history.log.events.filter { $0.kind == .clip }.map(\.place), ["Input L"])
        XCTAssertEqual(history.log.events.first { $0.kind == .clip }?.amount, 6)
        XCTAssertTrue(history.exportText().contains("Input L"))
        page.settle()
        // The card's Clear button is a bare SwiftUI button the harness cannot reach (G107); it calls this.
        history.clear()
        XCTAssertTrue(history.log.events.isEmpty, "Clear empties this session's list")
    }

    // MARK: S17: a 5.1 session's view choice reaches the analysis worker

    func testFiveOneSingleSpeakerViewReachesTheWorkerAtEveryRate() throws {
        func meter(_ role: OutputProgramRole, _ i: Int) -> ProductionTransportChannelMeter {
            ProductionTransportChannelMeter(
                id: "program-\(role.rawValue)", label: role.displayName, channelIndex: UInt32(i),
                peakLinear: 0, rmsLinear: 0, overRangeSamples: 0)
        }
        let transport = ProductionTransportMeterSnapshot(
            kind: .semanticSpeakers, displayName: "5.1", programLayoutName: "5.1", sampleRate: 48_000, latencyFrames: 0,
            meteringEnabled: true, programChannels: fiveOneRoles.enumerated().map { meter($0.element, $0.offset) },
            physicalOutputs: [], inputTruePeakLinear: nil, outputTruePeakLinear: nil, roomTreatment: nil,
            renderFailures: 0, outputWriteFailures: 0)
        let options = AnalysisViewOptions(transport: transport)
        XCTAssertEqual(options.kind, .wide)
        let side = try XCTUnwrap(options.views.first { $0.title == "Side Left" }, "the picker offers each speaker").view
        let front = try XCTUnwrap(options.views.first { $0.title == "Front Left" }, "the picker offers each speaker").view
        for rate in rates {
            let capture = try XCTUnwrap(N60LoudnessCaptureCreate(6, 6, rate))
            defer { N60LoudnessCaptureDestroy(capture) }
            let positions = LoudnessChannelPosition.positions(for: fiveOneRoles)
            let worker = try XCTUnwrap(ProductionWideLoudnessWorker(
                capture: capture, sampleRate: rate, inputPositions: positions, outputPositions: positions, roles: fiveOneRoles))
            defer { worker.stop() }
            let size = ProductionAnalysisMath.fftSize(sampleRate: rate)
            let count = Int(rate * (Double(size) / rate + 0.4))
            let tone = (0..<count).map { Float(0.5 * sin(2 * Double.pi * 1_000 * Double($0) / rate)) }
            let silence = [Float](repeating: 0, count: count)
            let planes = [silence, silence, silence, silence, tone, silence]  // Side Left only
            var peaks: [Float] = []
            for view in [side, front] {
                worker.setDemand(UInt32(N60_ANALYSIS_DEMAND_SPECTRUM) | ProductionAnalysisSelection.encode(view: view))
                Thread.sleep(forTimeInterval: 0.1)
                var written = N60LoudnessCaptureGetSnapshot(capture).capturedFrames
                var start = 0
                let block = Int(rate / 10)
                while start < count {
                    let end = min(start + block, count)
                    let granted = N60LoudnessCaptureBeginBlock(capture, UInt32(end - start))
                    for n in 0..<Int(granted.frames) {
                        var frame = planes.map { $0[start + n] }
                        N60LoudnessCaptureWriteInput(capture, granted, UInt32(n), &frame)
                        N60LoudnessCaptureWriteOutput(capture, granted, UInt32(n), &frame)
                    }
                    N60LoudnessCaptureCommit(capture, granted)
                    written += UInt64(granted.frames)
                    start = end
                    let deadline = Date().addingTimeInterval(3)
                    while Date() < deadline {
                        let s = worker.snapshot()
                        if s.capturedFrames == written, s.availableFrames == 0 { break }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
                Thread.sleep(forTimeInterval: 0.12)
                peaks.append(worker.snapshot().spectrum.map(\.outputDB).max() ?? -.infinity)
            }
            XCTAssertGreaterThan(peaks[0], -12, "Side Left view shows its tone at \(rate)")
            XCTAssertLessThan(peaks[1], -75, "Front Left view does not at \(rate)")
        }
    }

    // MARK: S22 to S25: a plug-in through the rack on a 5.1 session

    private func descriptor() -> AudioUnitComponentDescriptor {
        AudioUnitComponentDescriptor(
            identity: AudioUnitComponentIdentity(componentType: 0x61756678, componentSubType: 0x73743235, componentManufacturer: 0x6e363073),
            kind: .effect, name: "Fake Stereo", manufacturerName: "Notch Labs", typeName: "Effect", version: 1,
            versionString: "1.0.0", hasCustomView: false, hasMIDIInput: false, hasMIDIOutput: false, passesAUVal: true,
            sandboxSafe: true, supportedSymmetricChannelCounts: [2])
    }

    private final class EditTarget: AudioUnitLiveEditTarget {
        var state = Data([1, 2, 3])
        var editing = false
        func captureState() throws -> Data { state }
        func restoreState(_ data: Data) throws { state = data }
        var reportedLatencyFrames: Int? { 0 }
        func presets() -> [AudioUnitPresetEntry] { [] }
        func applyPreset(_ entry: AudioUnitPresetEntry) throws {}
        func setEditing(_ editing: Bool) { self.editing = editing }
    }

    /// A stereo-only plug-in is accepted on a 5.1 session (S22, S25) and planned on the front pair with its probed latency;
    /// a live edit and its revert leave the saved state intact (S23); the rack bypass keeps the rack's latency (S24); and the
    /// live pair stage built from the plan processes the front pair while the other lanes pass delayed by that latency.
    func testPlugInRackOnAFiveOneSessionAtEveryRate() throws {
        let frames = 64
        let roles = fiveOneRoles
        let plug = descriptor()
        for rate in rates {
            let format = AudioUnitRackProcessingFormat(
                sampleRate: rate, channelCount: roles.count, maximumFramesPerSlice: frames, channelRoles: roles, allowsStereoPairs: true)
            XCTAssertTrue(plug.compatibility(for: format, separateProcess: true).compatible, "accepted on 5.1 at \(rate)")
            let latency = Int(rate * 0.0001)  // 4 to 38 frames, under the 64-frame block
            let pairFormat = format.slotFormat(for: plug)
            let probe = AudioUnitProbeResult(
                component: plug.identity, sampleRate: rate, inputChannelCount: 2, outputChannelCount: 2,
                maximumFramesToRender: 4_096, latencySeconds: Double(latency) / rate, tailTimeSeconds: 0,
                supportsFullState: true, supportsHostBypass: true)
            XCTAssertEqual(pairFormat.channelCount, 2)
            let slot = AudioUnitRackSlotState(
                component: plug.identity, displayName: "Fake", bypassed: false, opaqueFullState: Data([7, 7]), channelMode: .frontLeftRight)
            let planner = AudioUnitRackPreparationPlanner()
            let plan = try planner.prepare(
                configuration: AudioUnitRackConfiguration(slots: [slot]), descriptors: [plug], probes: [probe],
                quarantine: AudioUnitQuarantineRegistry(), format: format)
            XCTAssertEqual(plan.slots.first?.mode, .process)
            XCTAssertEqual(plan.totalLatencyFrames, probe.latencyFrames, "the rack reports the slot's latency at \(rate)")

            // S23: edit by ear, then revert.
            let target = EditTarget()
            let session = try AudioUnitLiveEditSession(target: target, renderedLatencyFrames: latency)
            target.state = Data([9])
            XCTAssertTrue(session.hasEdits)
            try session.revert()
            XCTAssertEqual(target.state, Data([1, 2, 3]))
            session.end()

            // S24: rack bypass keeps the latency and restores the slot's own flag.
            let bypassed = AudioUnitRackBypass.bypassing(AudioUnitRackConfiguration(slots: [slot]))
            XCTAssertTrue(AudioUnitRackBypass.isBypassed(bypassed.configuration))
            let bypassPlan = try planner.prepare(
                configuration: bypassed.configuration, descriptors: [plug], probes: [probe],
                quarantine: AudioUnitQuarantineRegistry(), format: format)
            XCTAssertEqual(bypassPlan.totalLatencyFrames, plan.totalLatencyFrames, "bypass keeps the latency at \(rate)")
            XCTAssertEqual(AudioUnitRackBypass.restoring(bypassed.configuration, saved: bypassed.saved).slots.first?.bypassed, false)

            // S25: the live stage on the front pair; the other lanes are delayed by the slot's latency.
            let pairs = AudioUnitSlotChannelMode.frontLeftRight.lanePairs(channelCount: roles.count, roles: roles)
            XCTAssertEqual(pairs.map { [$0.left, $0.right] }, [[0, 1]])
            let wet: Float = 0.5
            let stage = AudioUnitLivePairStage(
                slotIndex: 0, component: nil,
                instances: [try makeInstance(rate: rate, frames: frames, latency: latency, wet: wet)],
                pairs: pairs, channelCount: roles.count, maximumFramesPerSlice: frames, latencyFrames: latency)
            var last: [Float] = []
            var inputs: [[Float]] = []
            for block in 0..<3 {
                let input = (0..<(frames * roles.count)).map { Float(block * 1_000 + $0 + 1) }
                inputs.append(input)
                var output = [Float](repeating: -9, count: input.count)
                let result = input.withUnsafeBufferPointer { source in
                    output.withUnsafeMutableBufferPointer { destination in
                        stage.process(
                            inputInterleaved: source.baseAddress!, outputInterleaved: destination.baseAddress!, frameCount: frames,
                            channelCount: roles.count, sampleTime: Double(block * frames))
                    }
                }
                XCTAssertEqual(result.faultReason, N60AudioUnitLiveRackFaultNone)
                last = output
            }
            for frame in 0..<frames {
                for lane in 0..<roles.count {
                    if lane < 2 {
                        XCTAssertEqual(last[frame * roles.count + lane], wet, "front pair runs the plug-in, \(rate)")
                    } else {
                        let source = frame - latency
                        let expected = source >= 0 ? inputs[2][source * roles.count + lane] : inputs[1][(frames + source) * roles.count + lane]
                        XCTAssertEqual(last[frame * roles.count + lane].bitPattern, expected.bitPattern, "lane \(lane) is delayed, not processed, \(rate)")
                    }
                }
            }
        }
    }

    private final class Counter: @unchecked Sendable { var calls = 0 }

    private func makeInstance(rate: Double, frames: Int, latency: Int, wet: Float) throws -> AudioUnitLiveProcessStage {
        let unit = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_LowPassFilter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        let avFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let block: AURenderBlock = { _, _, count, _, list, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    for frame in 0..<Int(count) { data[frame] = wet }
                }
            }
            return noErr
        }
        return AudioUnitLiveProcessStage(
            slotIndex: 0,
            component: AudioUnitComponentIdentity(componentType: 0x61756678, componentSubType: 0x73743235, componentManufacturer: 0x6e363073),
            unit: unit, renderBlock: block, outputBuffer: buffer, channelCount: 2, maximumFramesPerSlice: frames,
            sampleRate: rate, latencyFrames: latency, tailFrames: 0, wetDryMix: 1,
            faultGate: try XCTUnwrap(N60AudioUnitStageFaultGateCreate()))
    }
}
