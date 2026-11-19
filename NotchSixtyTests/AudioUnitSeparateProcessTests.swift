import AudioToolbox
import AVFAudio
import Foundation
import XCTest
@testable import NotchSixty

/// E33 S22 (`e33.page-enhancements`): separate-process plug-in loading. The census measures the rejection counts, the
/// policy drops the sandbox-safe rejection, and a plug-in process that stops or runs slow is handled like a render fault.
final class AudioUnitSeparateProcessTests: XCTestCase {
    private static let rates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ]

    private func descriptor(
        sub: UInt32, sandboxSafe: Bool, validates: Bool = true,
        kind: AudioUnitEffectKind = .effect, channels: [Int] = [2]
    ) -> AudioUnitComponentDescriptor {
        AudioUnitComponentDescriptor(
            identity: AudioUnitComponentIdentity(
                componentType: 0x61756678, componentSubType: sub, componentManufacturer: 0x6e363073
            ),
            kind: kind, name: "Fake \(sub)", manufacturerName: "Notch Labs", typeName: "Effect",
            version: 0x0001_0000, versionString: "1.0.0", hasCustomView: false, hasMIDIInput: false,
            hasMIDIOutput: false, passesAUVal: validates, sandboxSafe: sandboxSafe,
            supportedSymmetricChannelCounts: channels
        )
    }

    private func format(_ rate: Double, channels: Int = 2) -> AudioUnitRackProcessingFormat {
        AudioUnitRackProcessingFormat(
            sampleRate: rate, channelCount: channels, maximumFramesPerSlice: 64
        )
    }

    // MARK: policy and census

    func testSandboxRejectionIsDroppedOnlyForSeparateProcess() {
        let unsafe = descriptor(sub: 1, sandboxSafe: false)
        for rate in Self.rates {
            XCTAssertFalse(unsafe.compatibility(for: format(rate), separateProcess: false).compatible)
            XCTAssertTrue(unsafe.compatibility(for: format(rate), separateProcess: true).compatible)
        }
    }

    func testSeparateProcessKeepsEveryOtherRejection() {
        let badValidation = descriptor(sub: 2, sandboxSafe: false, validates: false)
        let wrongChannels = descriptor(sub: 3, sandboxSafe: false, channels: [1])
        let notEffect = descriptor(sub: 4, sandboxSafe: false, kind: .unsupported)
        for item in [badValidation, wrongChannels, notEffect] {
            XCTAssertFalse(item.compatibility(for: format(48_000), separateProcess: true).compatible)
        }
    }

    func testInstantiationOptionsFollowThePolicy() {
        XCTAssertEqual(AudioUnitLoadingPolicy.instantiationOptions(separateProcess: true), .loadOutOfProcess)
        XCTAssertEqual(AudioUnitLoadingPolicy.instantiationOptions(separateProcess: false), [])
    }

    func testCensusCountsEachRejectionReason() {
        let items = [
            descriptor(sub: 1, sandboxSafe: true),
            descriptor(sub: 2, sandboxSafe: false),
            descriptor(sub: 3, sandboxSafe: false),
            descriptor(sub: 4, sandboxSafe: false, validates: false),
            descriptor(sub: 5, sandboxSafe: true, channels: [1]),
            descriptor(sub: 6, sandboxSafe: true, kind: .unsupported),
        ]
        let census = AudioUnitRejectionCensus(descriptors: items, channelCount: 2)
        XCTAssertEqual(census.total, 6)
        XCTAssertEqual(census.accepted, 1)
        XCTAssertEqual(census.notSandboxSafe, 3)
        XCTAssertEqual(census.failsValidation, 1)
        XCTAssertEqual(census.noChannelSupport, 1)
        XCTAssertEqual(census.notEffectKind, 1)
        XCTAssertEqual(census.onlySandbox, 2)
        XCTAssertEqual(census.acceptedSeparateProcess, 3)
    }

    /// The measurement: counts the real installed effects on this machine. Prints the line recorded in the E33 Log.
    func testMeasureInstalledEffectRejectionCounts() {
        let descriptors = SystemAudioUnitComponentCatalog().discoverEffects()
        for channels in [2, 6] {
            let census = AudioUnitRejectionCensus(descriptors: descriptors, channelCount: channels)
            print("E33-S22-CENSUS channels=\(channels) \(census.summary)")
            XCTAssertEqual(census.total, descriptors.count)
            XCTAssertGreaterThanOrEqual(census.acceptedSeparateProcess, census.accepted)
        }
    }

    // MARK: render faults on a separate-process plug-in

    private enum Behaviour {
        case dies(afterCalls: Int)
        case slow(seconds: Double)
    }

    private final class CallCounter: @unchecked Sendable {
        var calls = 0
    }

    private func makeStage(
        rate: Double, latency: Int, behaviour: Behaviour, counter: CallCounter
    ) throws -> (AudioUnitLiveProcessStage, AVAudioPCMBuffer) {
        let unit = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_LowPassFilter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        ))
        let avFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: 64))
        buffer.frameLength = 64
        let block: AURenderBlock = { _, _, frames, _, list, _ in
            counter.calls += 1
            switch behaviour {
            case .dies(let afterCalls):
                if counter.calls > afterCalls { return kAudioUnitErr_InvalidParameter }
            case .slow(let seconds):
                Thread.sleep(forTimeInterval: seconds)
            }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for index in 0..<buffers.count {
                if let data = buffers[index].mData?.assumingMemoryBound(to: Float.self) {
                    for frame in 0..<Int(frames) { data[frame] = 0.5 }
                }
            }
            return noErr
        }
        let gate = try XCTUnwrap(N60AudioUnitStageFaultGateCreate())
        let stage = AudioUnitLiveProcessStage(
            slotIndex: 0,
            component: AudioUnitComponentIdentity(
                componentType: 0x61756678, componentSubType: 0x73703231, componentManufacturer: 0x6e363073
            ),
            unit: unit, renderBlock: block, outputBuffer: buffer, channelCount: 2,
            maximumFramesPerSlice: 64, sampleRate: rate, latencyFrames: latency, tailFrames: 0,
            wetDryMix: 1, faultGate: gate
        )
        return (stage, buffer)
    }

    private func run(
        _ stage: AudioUnitLiveProcessStage, block index: Int, ramp: [Float]
    ) -> (AudioUnitLiveRackStageResult, [Float]) {
        var output = [Float](repeating: -9, count: ramp.count)
        let result = ramp.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                stage.process(
                    inputInterleaved: source.baseAddress!, outputInterleaved: destination.baseAddress!,
                    frameCount: 64, channelCount: 2, sampleTime: Double(index * 64)
                )
            }
        }
        return (result, output)
    }

    func testPluginProcessThatStopsGivesDryAudioAtTheReportedLatencyAtEveryRate() throws {
        for rate in Self.rates {
            let latency = 10
            let counter = CallCounter()
            let (stage, _) = try makeStage(
                rate: rate, latency: latency, behaviour: .dies(afterCalls: 1), counter: counter
            )
            // Block 0 renders wet (0.5); the process then stops.
            let first = (0..<128).map { Float($0 + 1) }
            let second = (0..<128).map { Float($0 + 1000) }
            let third = (0..<128).map { Float($0 + 2000) }
            let (ok, wet) = run(stage, block: 0, ramp: first)
            XCTAssertEqual(ok.faultReason, N60AudioUnitLiveRackFaultNone, "rate \(rate)")
            XCTAssertTrue(wet.allSatisfy { $0 == 0.5 })

            let (fail, dry1) = run(stage, block: 1, ramp: second)
            XCTAssertEqual(fail.faultReason, N60AudioUnitLiveRackFaultRenderStatus, "rate \(rate)")
            XCTAssertNotEqual(fail.renderStatus, noErr)
            // Dry audio at the reported latency: the input delayed by `latency` frames (2 channels interleaved).
            for sample in 0..<(latency * 2) {
                XCTAssertEqual(dry1[sample], first[128 - latency * 2 + sample], "rate \(rate)")
            }
            for sample in (latency * 2)..<128 {
                XCTAssertEqual(dry1[sample], second[sample - latency * 2], "rate \(rate)")
            }

            // Later blocks stay dry without calling the dead plug-in again.
            let callsAfterFault = counter.calls
            let (again, dry2) = run(stage, block: 2, ramp: third)
            XCTAssertEqual(again.faultReason, N60AudioUnitLiveRackFaultNone)
            XCTAssertEqual(counter.calls, callsAfterFault, "rate \(rate)")
            for sample in (latency * 2)..<128 {
                XCTAssertEqual(dry2[sample], third[sample - latency * 2], "rate \(rate)")
            }
        }
    }

    func testWatchdogStillTripsOnASlowSeparateProcessPlugin() throws {
        let counter = CallCounter()
        let (stage, _) = try makeStage(
            rate: 48_000, latency: 4, behaviour: .slow(seconds: 0.05), counter: counter
        )
        let ramp = (0..<128).map { Float($0) }
        var tripped: AudioUnitLiveRackStageResult?
        for block in 0..<AudioUnitLiveRenderWatchdog.consecutiveOverrunLimit {
            let (result, _) = run(stage, block: block, ramp: ramp)
            tripped = result
        }
        XCTAssertEqual(tripped?.faultReason, N60AudioUnitLiveRackFaultCPUOverrun)
        let before = counter.calls
        _ = run(stage, block: 9, ramp: ramp)
        XCTAssertEqual(counter.calls, before, "a tripped slot is not rendered again")
    }

    func testProcessStoppedQuarantineReasonIsStored() throws {
        var registry = AudioUnitQuarantineRegistry()
        let item = descriptor(sub: 9, sandboxSafe: false)
        registry.recordFailure(
            component: item.identity, reason: .processStopped,
            description: AudioUnitLoadingPolicy.processStoppedDescription
        )
        let decoded = try JSONDecoder().decode(
            AudioUnitQuarantineRegistry.self, from: JSONEncoder().encode(registry)
        )
        XCTAssertEqual(decoded.entry(for: item.identity)?.reason, .processStopped)
        XCTAssertFalse(AudioUnitLoadingPolicy.processStoppedDescription.isEmpty)
    }
}
