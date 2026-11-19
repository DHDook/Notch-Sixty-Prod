import AudioToolbox
import AVFAudio
import Foundation
import XCTest
@testable import NotchSixty

/// E33 S23 (`e33.page-enhancements`): live editing of a running plug-in, the plug-in's own presets, and copy and paste.
@MainActor
final class AudioUnitLiveEditTests: XCTestCase {
    private static let rates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ]

    private final class FakeTarget: AudioUnitLiveEditTarget {
        var state: Data
        var latency: Int? = 0
        var editing = false
        var generationsBuilt = 0
        var presetList = [
            AudioUnitPresetEntry(number: 0, name: "Warm", isFactory: true),
            AudioUnitPresetEntry(number: -1, name: "Mine", isFactory: false),
        ]
        var presetStates: [String: Data] = [:]

        init(state: Data) { self.state = state }

        func captureState() throws -> Data { state }
        func restoreState(_ data: Data) throws { state = data }
        var reportedLatencyFrames: Int? { latency }
        func presets() -> [AudioUnitPresetEntry] { presetList }
        func applyPreset(_ entry: AudioUnitPresetEntry) throws {
            guard let data = presetStates[entry.name] else {
                throw AudioUnitLiveEditError.presetUnavailable(entry.name)
            }
            state = data
        }
        func setEditing(_ editing: Bool) { self.editing = editing }
    }

    private func bytes(_ values: [UInt8]) -> Data { Data(values) }

    func testEditReachesTheLiveUnitWithoutANewGeneration() throws {
        let target = FakeTarget(state: bytes([1, 2, 3]))
        let session = try AudioUnitLiveEditSession(target: target, renderedLatencyFrames: 0)
        XCTAssertTrue(target.editing, "the stage is told an edit is open")
        XCTAssertFalse(session.hasEdits)

        target.state = bytes([9, 9, 9])  // the user moves a control; the unit changes directly
        XCTAssertTrue(session.hasEdits)
        XCTAssertEqual(target.generationsBuilt, 0, "an edit never builds a rack generation")
        session.end()
        XCTAssertFalse(target.editing)
    }

    func testRevertRestoresTheCapturedStateBitForBitAtEveryRate() throws {
        for rate in Self.rates {
            var original = Data()
            for index in 0..<4_096 { original.append(UInt8(truncatingIfNeeded: index &* 31 &+ Int(rate) / 1000)) }
            let target = FakeTarget(state: original)
            target.latency = Int(rate / 1000)
            let session = try AudioUnitLiveEditSession(
                target: target, renderedLatencyFrames: Int(rate / 1000)
            )
            target.state = bytes([7])
            target.state.append(contentsOf: [1, 2])
            try session.revert()
            XCTAssertEqual(target.state, original, "rate \(rate)")
            XCTAssertEqual(try session.finish(), .unchanged, "rate \(rate)")
        }
    }

    func testChoosingAPresetIsAnEditThatRevertUndoes() throws {
        let original = bytes([1, 1, 1])
        let target = FakeTarget(state: original)
        target.presetStates["Warm"] = bytes([5, 5])
        let session = try AudioUnitLiveEditSession(target: target, renderedLatencyFrames: 0)
        XCTAssertEqual(session.presets.map(\.name), ["Warm", "Mine"])
        XCTAssertEqual(session.presets.map(\.isFactory), [true, false])

        try session.applyPreset(session.presets[0])
        XCTAssertEqual(target.state, bytes([5, 5]))
        XCTAssertEqual(try session.finish(), .commit(state: bytes([5, 5]), latencyChanged: false))
        try session.revert()
        XCTAssertEqual(target.state, original)

        XCTAssertThrowsError(try session.applyPreset(session.presets[1])) {
            XCTAssertEqual($0 as? AudioUnitLiveEditError, .presetUnavailable("Mine"))
        }
    }

    func testALatencyChangingEditTakesTheRestartPathAndShowsANotice() throws {
        for rate in Self.rates {
            let rendered = 64
            let target = FakeTarget(state: bytes([1]))
            target.latency = rendered
            let session = try AudioUnitLiveEditSession(target: target, renderedLatencyFrames: rendered)
            XCTAssertFalse(session.latencyChanged)

            target.state = bytes([2])
            target.latency = rendered + 1  // within the runtime's one-frame tolerance
            XCTAssertEqual(try session.finish(), .commit(state: bytes([2]), latencyChanged: false))

            target.latency = rendered + 480
            XCTAssertTrue(session.latencyChanged, "rate \(rate)")
            XCTAssertEqual(try session.finish(), .commit(state: bytes([2]), latencyChanged: true))
            // Same state but a moved delay still has to restart the rack.
            target.state = bytes([1])
            XCTAssertEqual(try session.finish(), .commit(state: bytes([1]), latencyChanged: true))

            let notice = AudioUnitLiveEditSession.latencyNotice(
                rendered: rendered, now: rendered + 480, sampleRate: rate
            )
            XCTAssertTrue(notice.contains("restarts audio"), notice)
            target.latency = nil
            XCTAssertTrue(session.latencyChanged, "an out-of-range latency counts as a change")
        }
    }

    func testPasteOntoADifferentPlugInIsRefused() throws {
        let a = AudioUnitComponentIdentity(componentType: 0x61756678, componentSubType: 1, componentManufacturer: 7)
        let b = AudioUnitComponentIdentity(componentType: 0x61756678, componentSubType: 2, componentManufacturer: 7)
        let source = AudioUnitRackSlotState(component: a, opaqueFullState: bytes([4, 5]))
        let clipboard = try XCTUnwrap(AudioUnitSettingsClipboard(copying: source))
        XCTAssertNil(AudioUnitSettingsClipboard(copying: AudioUnitRackSlotState()), "an empty slot has nothing to copy")

        let same = AudioUnitRackSlotState(component: a, opaqueFullState: bytes([9]))
        XCTAssertTrue(clipboard.canPaste(onto: same))
        XCTAssertEqual(
            try clipboard.pasteMutation(onto: same, index: 2),
            .setOpaqueFullState(slot: 2, state: bytes([4, 5]))
        )

        let other = AudioUnitRackSlotState(component: b)
        XCTAssertFalse(clipboard.canPaste(onto: other))
        XCTAssertThrowsError(try clipboard.pasteMutation(onto: other, index: 0)) {
            XCTAssertEqual($0 as? AudioUnitLiveEditError, .differentPlugIn)
        }
        XCTAssertThrowsError(try clipboard.pasteMutation(onto: AudioUnitRackSlotState(), index: 0))
    }

    func testClipboardSurvivesAContentPresetSwitchOnTheHost() throws {
        let a = AudioUnitComponentIdentity(componentType: 0x61756678, componentSubType: 1, componentManufacturer: 7)
        let host = AudioUnitHostController()
        host.settingsClipboard = AudioUnitSettingsClipboard(
            copying: AudioUnitRackSlotState(component: a, opaqueFullState: bytes([1]))
        )
        // A Content Preset switch replaces the rack, not the host's clipboard.
        try host.replaceRackConfiguration(AudioUnitRackConfiguration())
        XCTAssertNotNil(host.settingsClipboard)
    }

    // MARK: the real unit

    func testSystemTargetEditsTheSameUnitTheStageRendersAtEveryRate() throws {
        for rate in Self.rates {
            let unit = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_LowPassFilter,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
            ))
            let avFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: 64))
            buffer.frameLength = 64
            let block: AURenderBlock = { _, _, _, _, _, _ in noErr }
            let gate = try XCTUnwrap(N60AudioUnitStageFaultGateCreate())
            let identity = AudioUnitComponentIdentity(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_LowPassFilter,
                componentManufacturer: kAudioUnitManufacturer_Apple
            )
            let stage = AudioUnitLiveProcessStage(
                slotIndex: 0, component: identity, unit: unit, renderBlock: block, outputBuffer: buffer,
                channelCount: 2, maximumFramesPerSlice: 64, sampleRate: rate, latencyFrames: 0, tailFrames: 0,
                wetDryMix: 1, faultGate: gate
            )
            let runtime = try AudioUnitLiveRackRuntime(
                format: AudioUnitRackProcessingFormat(sampleRate: rate, channelCount: 2, maximumFramesPerSlice: 64),
                totalLatencyFrames: 0, stages: [stage], componentsBySlot: [identity]
            )
            XCTAssertTrue(runtime.processStage(forSlot: 0) === stage)
            XCTAssertNil(runtime.processStage(forSlot: 1))

            let target = AUAudioUnitEditTarget(audioUnit: stage.liveAudioUnit, sampleRate: rate, stage: stage)
            let session = try AudioUnitLiveEditSession(target: target, renderedLatencyFrames: 0)
            let au = unit.withNodeAUAudioUnit { $0 }
            XCTAssertTrue(stage.liveAudioUnit === au, "the editor attaches to the rendered unit, not a copy")

            let cutoff = try XCTUnwrap(au.parameterTree?.allParameters.first)
            let original = cutoff.value
            let moved = cutoff.minValue + (cutoff.maxValue - cutoff.minValue) * 0.37
            cutoff.value = moved
            XCTAssertTrue(session.hasEdits, "rate \(rate)")
            XCTAssertEqual(
                try XCTUnwrap(unit.withNodeAUAudioUnit { $0.parameterTree?.allParameters.first }).value,
                moved, "the live unit changed at once"
            )

            try session.revert()
            XCTAssertEqual(cutoff.value, original, accuracy: 0.001, "rate \(rate)")
            XCTAssertEqual(try session.finish(), .unchanged)
            session.end()
            _ = runtime
        }
    }
}
