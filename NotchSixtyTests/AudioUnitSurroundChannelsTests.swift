import AudioToolbox
import AVFAudio
import Foundation
import XCTest
@testable import NotchSixty

/// E33 S25 (`e33.page-enhancements`, G48, decision 29): a stereo-only plug-in on a session wider than stereo runs on the
/// front pair or on every pair; the other lanes pass untouched, delayed by the slot's latency.
final class AudioUnitSurroundChannelsTests: XCTestCase {
    private static let rates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ]
    private static let frames = 64
    private static let latency = 10
    private static let wet: Float = 0.5

    private func descriptor(channels: [Int]) -> AudioUnitComponentDescriptor {
        AudioUnitComponentDescriptor(
            identity: AudioUnitComponentIdentity(
                componentType: 0x61756678, componentSubType: 0x73743231, componentManufacturer: 0x6e363073
            ),
            kind: .effect, name: "Fake", manufacturerName: "Notch Labs", typeName: "Effect",
            version: 1, versionString: "1.0.0", hasCustomView: false, hasMIDIInput: false,
            hasMIDIOutput: false, passesAUVal: true, sandboxSafe: true,
            supportedSymmetricChannelCounts: channels
        )
    }

    private func format(
        layout: OutputProgramLayout, rate: Double = 48_000, pairs: Bool = true
    ) -> AudioUnitRackProcessingFormat {
        AudioUnitRackProcessingFormat(
            sampleRate: rate, channelCount: layout.roles.count, maximumFramesPerSlice: Self.frames,
            channelRoles: layout.roles, allowsStereoPairs: pairs
        )
    }

    // MARK: pairing and compatibility

    func testLanePairsFollowTheRolesAndLeaveCentreAndLFEOut() {
        let fiveOne = OutputProgramLayout.fiveOne
        let front = AudioUnitSlotChannelMode.frontLeftRight.lanePairs(channelCount: 6, roles: fiveOne.roles)
        XCTAssertEqual(front.map { [$0.left, $0.right] }, [[0, 1]])
        let every = AudioUnitSlotChannelMode.everyPair.lanePairs(channelCount: 6, roles: fiveOne.roles)
        XCTAssertEqual(every.map { [$0.left, $0.right] }, [[0, 1], [4, 5]])

        let roles = OutputProgramLayout.sevenOneFour.roles
        let pairs = AudioUnitSlotChannelMode.everyPair.lanePairs(channelCount: roles.count, roles: roles)
        let used = Set(pairs.flatMap { [$0.left, $0.right] })
        XCTAssertEqual(pairs.count, 5, "front, side, rear, top front and top rear pairs of 7.1.4")
        XCTAssertFalse(used.contains(roles.firstIndex(of: .frontCenter)!))
        XCTAssertFalse(used.contains(roles.firstIndex(of: .lowFrequencyEffects)!))
        XCTAssertEqual(used.count, pairs.count * 2)
    }

    func testStereoPluginIsCompatibleOnAWideSessionOnlyWithTheFlag() {
        let stereo = descriptor(channels: [2])
        let on = format(layout: .fiveOne)
        let off = format(layout: .fiveOne, pairs: false)
        XCTAssertTrue(stereo.compatibility(for: on, separateProcess: true).compatible)
        XCTAssertFalse(stereo.compatibility(for: off, separateProcess: true).compatible)
        XCTAssertEqual(on.slotFormat(for: stereo).channelCount, 2)
        XCTAssertEqual(off.slotFormat(for: stereo).channelCount, 6)

        let full = descriptor(channels: [2, 6])
        XCTAssertEqual(on.slotFormat(for: full), on, "a plug-in that supports the layout runs on it as today")
        XCTAssertFalse(on.runsAsStereoPairs(on: full))

        let neither = descriptor(channels: [1])
        XCTAssertFalse(neither.compatibility(for: on, separateProcess: true).compatible)
    }

    func testPlannerAcceptsAStereoPreparedSlotOnAWideSession() throws {
        let stereo = descriptor(channels: [2])
        let wide = format(layout: .fiveOne)
        let pair = wide.slotFormat(for: stereo)
        let probe = AudioUnitProbeResult(
            component: stereo.identity, sampleRate: pair.sampleRate, inputChannelCount: 2, outputChannelCount: 2,
            maximumFramesToRender: 4_096, latencySeconds: 0.001, tailTimeSeconds: 0,
            supportsFullState: true, supportsHostBypass: true
        )
        let configuration = AudioUnitRackConfiguration(slots: [
            AudioUnitRackSlotState(
                component: stereo.identity, displayName: "Fake", bypassed: false, channelMode: .everyPair
            ),
        ])
        let plan = try AudioUnitRackPreparationPlanner().prepare(
            configuration: configuration, descriptors: [stereo], probes: [probe],
            quarantine: AudioUnitQuarantineRegistry(), format: wide
        )
        XCTAssertEqual(plan.slots.first?.mode, .process)
        XCTAssertEqual(plan.slots.first?.latencyFrames, probe.latencyFrames)
    }

    // MARK: stored with the slot

    func testChannelModeRoundTripsAndOlderPresetsReadAsFrontLeftRight() throws {
        let slot = AudioUnitRackSlotState(displayName: "Fake", channelMode: .everyPair)
        let decoded = try JSONDecoder().decode(AudioUnitRackSlotState.self, from: JSONEncoder().encode(slot))
        XCTAssertEqual(decoded.channels, .everyPair)

        // A slot saved before the field existed: the key is absent.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(slot)) as? [String: Any]
        )
        object.removeValue(forKey: "channelMode")
        let old = try JSONDecoder().decode(
            AudioUnitRackSlotState.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(old.channelMode)
        XCTAssertEqual(old.channels, .frontLeftRight)
    }

    // MARK: running on lanes

    private func makeInstance(rate: Double, counter: Counter) throws -> AudioUnitLiveProcessStage {
        let unit = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_LowPassFilter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        ))
        let avFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(Self.frames)))
        buffer.frameLength = AVAudioFrameCount(Self.frames)
        let block: AURenderBlock = { _, _, frames, _, list, _ in
            counter.calls += 1
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    for frame in 0..<Int(frames) { data[frame] = Self.wet }
                }
            }
            return noErr
        }
        return AudioUnitLiveProcessStage(
            slotIndex: 0,
            component: AudioUnitComponentIdentity(
                componentType: 0x61756678, componentSubType: 0x73743231, componentManufacturer: 0x6e363073
            ),
            unit: unit, renderBlock: block, outputBuffer: buffer, channelCount: 2,
            maximumFramesPerSlice: Self.frames, sampleRate: rate, latencyFrames: Self.latency, tailFrames: 0,
            wetDryMix: 1, faultGate: try XCTUnwrap(N60AudioUnitStageFaultGateCreate())
        )
    }

    private final class Counter: @unchecked Sendable { var calls = 0 }

    private func makePairStage(
        layout: OutputProgramLayout, mode: AudioUnitSlotChannelMode, rate: Double, counter: Counter
    ) throws -> AudioUnitLivePairStage {
        let roles = layout.roles
        let pairs = mode.lanePairs(channelCount: roles.count, roles: roles)
        return AudioUnitLivePairStage(
            slotIndex: 0, component: nil,
            instances: try pairs.map { _ in try makeInstance(rate: rate, counter: counter) },
            pairs: pairs, channelCount: roles.count, maximumFramesPerSlice: Self.frames,
            latencyFrames: Self.latency
        )
    }

    private func block(_ index: Int, channels: Int) -> [Float] {
        (0..<(Self.frames * channels)).map { Float(index * 10_000 + $0 + 1) }
    }

    private func run(_ stage: AudioUnitLivePairStage, channels: Int, blocks: [[Float]]) -> [[Float]] {
        blocks.enumerated().map { index, input in
            var output = [Float](repeating: -9, count: input.count)
            let result = input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    stage.process(
                        inputInterleaved: source.baseAddress!, outputInterleaved: destination.baseAddress!,
                        frameCount: Self.frames, channelCount: channels, sampleTime: Double(index * Self.frames)
                    )
                }
            }
            XCTAssertEqual(result.faultReason, N60AudioUnitLiveRackFaultNone)
            return output
        }
    }

    private func check(layout: OutputProgramLayout, mode: AudioUnitSlotChannelMode) throws {
        let roles = layout.roles
        let channels = roles.count
        let processed = Set(
            mode.lanePairs(channelCount: channels, roles: roles).flatMap { [$0.left, $0.right] }
        )
        for rate in Self.rates {
            let counter = Counter()
            let stage = try makePairStage(layout: layout, mode: mode, rate: rate, counter: counter)
            let inputs = [block(0, channels: channels), block(1, channels: channels)]
            let outputs = run(stage, channels: channels, blocks: inputs)
            XCTAssertEqual(counter.calls, stage.instances.count * 2, "one render per instance per block")
            // Output frame f, lane c, in the second block: untouched lanes are the input `latency` frames earlier.
            for frame in 0..<Self.frames {
                for lane in 0..<channels {
                    let value = outputs[1][frame * channels + lane]
                    if processed.contains(lane) {
                        XCTAssertEqual(value, Self.wet, "\(layout) \(mode) rate \(rate) lane \(lane)")
                    } else {
                        let source = frame - Self.latency
                        let expected = source >= 0
                            ? inputs[1][source * channels + lane]
                            : inputs[0][(Self.frames + source) * channels + lane]
                        XCTAssertEqual(
                            value.bitPattern, expected.bitPattern, "\(layout) \(mode) rate \(rate) lane \(lane)"
                        )
                    }
                }
            }
        }
    }

    func testFiveOneFrontPairOnly() throws { try check(layout: .fiveOne, mode: .frontLeftRight) }
    func testFiveOneEveryPair() throws { try check(layout: .fiveOne, mode: .everyPair) }
    func testSevenOneFourFrontPairOnly() throws { try check(layout: .sevenOneFour, mode: .frontLeftRight) }
    func testSevenOneFourEveryPair() throws { try check(layout: .sevenOneFour, mode: .everyPair) }

    func testEveryPairAddsEachInstanceToTheLoadReading() throws {
        let counter = Counter()
        let stage = try makePairStage(layout: .fiveOne, mode: .everyPair, rate: 48_000, counter: counter)
        XCTAssertEqual(stage.instances.count, 2)
        _ = run(stage, channels: 6, blocks: [block(0, channels: 6)])
        let reading = stage.takeLoadReading()
        XCTAssertGreaterThan(reading.bufferLoad, 0)
        XCTAssertGreaterThan(reading.watchdogLoad, 0)
        XCTAssertEqual(stage.takeLoadReading(), .idle, "taking the reading clears the peaks")
    }
}
