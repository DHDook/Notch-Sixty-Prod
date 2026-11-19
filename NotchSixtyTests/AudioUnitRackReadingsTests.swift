import AudioToolbox
import AVFAudio
import Foundation
import os
import XCTest
@testable import NotchSixty

/// E33 S24 (`e33.page-enhancements`): the Plugins page readings (load and latency per slot), whole-rack bypass,
/// drag order, rescan on a registration change and the plain catalog reasons.
@MainActor
final class AudioUnitRackReadingsTests: XCTestCase {
    private static let rates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ]

    private func identity(_ sub: UInt32) -> AudioUnitComponentIdentity {
        AudioUnitComponentIdentity(
            componentType: 0x61756678, componentSubType: sub, componentManufacturer: 0x6e363073
        )
    }

    private func descriptor(
        sub: UInt32, sandboxSafe: Bool = true, validates: Bool = true,
        kind: AudioUnitEffectKind = .effect, channels: [Int] = [2]
    ) -> AudioUnitComponentDescriptor {
        AudioUnitComponentDescriptor(
            identity: identity(sub),
            kind: kind, name: "Fake \(sub)", manufacturerName: "Notch Labs", typeName: "Effect",
            version: 0x0001_0000, versionString: "1.0.0", hasCustomView: false, hasMIDIInput: false,
            hasMIDIOutput: false, passesAUVal: validates, sandboxSafe: sandboxSafe,
            supportedSymmetricChannelCounts: channels
        )
    }

    private func format(_ rate: Double, channels: Int = 2) -> AudioUnitRackProcessingFormat {
        AudioUnitRackProcessingFormat(sampleRate: rate, channelCount: channels, maximumFramesPerSlice: 64)
    }

    // MARK: load reading

    func testUnitsClampAndRejectBadValues() {
        XCTAssertEqual(AudioUnitLoadReading.units(0), 0)
        XCTAssertEqual(AudioUnitLoadReading.units(-1), 0)
        XCTAssertEqual(AudioUnitLoadReading.units(.nan), 0)
        XCTAssertEqual(AudioUnitLoadReading.units(.infinity), 0)
        XCTAssertEqual(AudioUnitLoadReading.units(0.5), 5_000)
        XCTAssertEqual(AudioUnitLoadReading.units(1e9), AudioUnitLoadReading.maximumUnits)
    }

    func testFaultGateKeepsThePeakAndClearsOnTake() throws {
        let gate = try XCTUnwrap(N60AudioUnitStageFaultGateCreate())
        defer { N60AudioUnitStageFaultGateDestroy(gate) }
        N60AudioUnitStageFaultGateRecordLoad(gate, 3_000, 100)
        N60AudioUnitStageFaultGateRecordLoad(gate, 9_000, 50)
        N60AudioUnitStageFaultGateRecordLoad(gate, 1_000, 700)
        var buffer: UInt32 = 0
        var watchdog: UInt32 = 0
        N60AudioUnitStageFaultGateTakeLoad(gate, &buffer, &watchdog)
        XCTAssertEqual(buffer, 9_000)
        XCTAssertEqual(watchdog, 700)
        N60AudioUnitStageFaultGateTakeLoad(gate, &buffer, &watchdog)
        XCTAssertEqual(buffer, 0)
        XCTAssertEqual(watchdog, 0)
    }

    func testDisplayWarnsBeforeTheWatchdogCutsThePluginOut() {
        XCTAssertEqual(AudioUnitLoadDisplay(nil).level, .idle)
        XCTAssertEqual(AudioUnitLoadDisplay(.idle).text, "Load: no reading")

        let calm = AudioUnitLoadDisplay(AudioUnitLoadReading(bufferLoad: 0.2, watchdogLoad: 0.05))
        XCTAssertEqual(calm.level, .normal)
        XCTAssertEqual(calm.percentOfBuffer, 20)
        XCTAssertNil(calm.warning)

        let high = AudioUnitLoadDisplay(AudioUnitLoadReading(bufferLoad: 0.8, watchdogLoad: 0.2))
        XCTAssertEqual(high.level, .high)
        XCTAssertNotNil(high.warning)

        // Over the buffer but under the cut-out budget: warns, and the watchdog has not tripped.
        let near = AudioUnitLoadDisplay(AudioUnitLoadReading(bufferLoad: 2.0, watchdogLoad: 0.5))
        XCTAssertEqual(near.level, .nearCutOut)
        XCTAssertLessThan(near.percentOfBuffer.map { Double($0) / 100 } ?? 0, 4 * 1.0, "below the 4x severe budget")
        XCTAssertNotNil(near.warning)
    }

    func testStageLoadReadingFollowsRenderTimeAtEveryRate() throws {
        var previous: Double?
        for rate in Self.rates {
            let stage = try makeStage(rate: rate, sleep: 0.002)
            let ramp = (0..<128).map { Float($0) }
            var output = [Float](repeating: 0, count: 128)
            for block in 0..<2 {
                _ = ramp.withUnsafeBufferPointer { source in
                    output.withUnsafeMutableBufferPointer { destination in
                        stage.process(
                            inputInterleaved: source.baseAddress!, outputInterleaved: destination.baseAddress!,
                            frameCount: 64, channelCount: 2, sampleTime: Double(block * 64)
                        )
                    }
                }
            }
            let reading = stage.takeLoadReading()
            XCTAssertGreaterThanOrEqual(reading.bufferLoad, 1, "2 ms of work exceeds a 64-frame buffer at \(rate)")
            XCTAssertGreaterThan(reading.watchdogLoad, 0, "rate \(rate)")
            // The watchdog budget is at least 10 ms, so 2 ms of work is below it.
            XCTAssertLessThan(reading.watchdogLoad, 1, "rate \(rate)")
            XCTAssertEqual(stage.takeLoadReading(), .idle, "taking clears the peak")
            if let previous, rate >= 88_200 {
                XCTAssertGreaterThan(reading.bufferLoad, previous * 0.5, "load grows with the rate (shorter buffer)")
            }
            previous = reading.bufferLoad
        }
    }

    func testLatencyReadsInMillisecondsAtEveryRate() {
        for rate in Self.rates {
            let frames = Int((rate * 0.0125).rounded())
            let text = AudioUnitLatencyDisplay.milliseconds(frames: frames, sampleRate: rate)
            let value = Double(text.replacingOccurrences(of: " ms", with: "")) ?? 0
            XCTAssertEqual(value, 12.5, accuracy: 0.02, "rate \(rate)")
        }
        XCTAssertEqual(AudioUnitLatencyDisplay.milliseconds(frames: 0, sampleRate: 48_000), "none")
    }

    // MARK: rack bypass

    private func rack(latencies: [Int], bypassed: [Bool]) -> AudioUnitRackConfiguration {
        var configuration = AudioUnitRackConfiguration()
        configuration.slots = latencies.enumerated().map { index, latency in
            AudioUnitRackSlotState(
                component: identity(UInt32(index + 1)), displayName: "P\(index)",
                bypassed: bypassed[index], lastKnownLatencyFrames: latency
            )
        }
        configuration.slots.append(AudioUnitRackSlotState())
        return configuration
    }

    func testRackBypassKeepsTheRackLatencyAtEveryRate() throws {
        for rate in Self.rates {
            let fmt = format(rate)
            let latencies = [Int(rate * 0.002), Int(rate * 0.0075)]
            let live = rack(latencies: latencies, bypassed: [false, false])
            var probes: [UUID: AudioUnitProbeResult] = [:]
            for (index, slot) in live.slots.enumerated() where !slot.isEmpty {
                probes[slot.id] = AudioUnitProbeResult(
                    component: slot.component!, sampleRate: rate, inputChannelCount: 2, outputChannelCount: 2,
                    maximumFramesToRender: 64, latencySeconds: Double(latencies[index]) / rate,
                    tailTimeSeconds: 0, supportsFullState: true, supportsHostBypass: true
                )
            }
            let descriptors = [descriptor(sub: 1), descriptor(sub: 2)]
            let planner = AudioUnitRackPreparationPlanner()
            let before = try planner.prepare(
                configuration: live, descriptors: descriptors, probes: [], slotProbes: probes,
                quarantine: AudioUnitQuarantineRegistry(), format: fmt
            )
            let bypassed = AudioUnitRackBypass.bypassing(live).configuration
            XCTAssertTrue(AudioUnitRackBypass.isBypassed(bypassed))
            let after = try planner.prepare(
                configuration: bypassed, descriptors: descriptors, probes: [], slotProbes: probes,
                quarantine: AudioUnitQuarantineRegistry(), format: fmt
            )
            XCTAssertEqual(after.totalLatencyFrames, before.totalLatencyFrames, "rate \(rate)")
            XCTAssertGreaterThan(after.totalLatencyFrames, 0)
            XCTAssertTrue(after.slots.filter { $0.component != nil }.allSatisfy { $0.mode == .latencyMatchedBypass })
        }
    }

    func testRackBypassRestoresEachSlotsOwnFlag() {
        let original = rack(latencies: [10, 20, 30], bypassed: [false, true, false])
        XCTAssertFalse(AudioUnitRackBypass.isBypassed(original))
        let (bypassed, saved) = AudioUnitRackBypass.bypassing(original)
        XCTAssertTrue(AudioUnitRackBypass.isBypassed(bypassed))
        XCTAssertEqual(saved.count, 3)
        let restored = AudioUnitRackBypass.restoring(bypassed, saved: saved)
        XCTAssertEqual(restored, original)
        // Nothing saved (bypassed in an earlier session): every plug-in switches on.
        let fresh = AudioUnitRackBypass.restoring(bypassed, saved: [:])
        XCTAssertTrue(fresh.slots.filter { !$0.isEmpty }.allSatisfy { !$0.bypassed })
        XCTAssertFalse(AudioUnitRackBypass.isBypassed(AudioUnitRackConfiguration()), "an empty rack is not bypassed")
    }

    // MARK: drag

    func testDragOrderEqualsTheMoveButtonOrder() throws {
        let configuration = rack(latencies: [1, 2, 3, 4], bypassed: [false, false, false, false])
        let ids = configuration.slots.map(\.id)
        for from in 0..<configuration.slots.count {
            for to in 0..<configuration.slots.count {
                let drag = AudioUnitRackDrag.mutation(draggedID: ids[from], onto: ids[to], in: configuration)
                if from == to {
                    XCTAssertNil(drag)
                    continue
                }
                XCTAssertEqual(drag, .move(from: from, to: to))
                // The buttons move one step at a time; the same end order.
                var stepped = configuration.slots
                var position = from
                while position != to {
                    let next = position + (to > position ? 1 : -1)
                    stepped.swapAt(position, next)
                    position = next
                }
                var jumped = configuration.slots
                let moved = jumped.remove(at: from)
                jumped.insert(moved, at: to)
                XCTAssertEqual(stepped.map(\.id), jumped.map(\.id), "from \(from) to \(to)")
            }
        }
        XCTAssertNil(AudioUnitRackDrag.mutation(draggedID: UUID(), onto: ids[0], in: configuration))
    }

    // MARK: rescan

    private final class CountingCatalog: AudioUnitComponentCataloging, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        var scans: Int { lock.withLock { $0 } }
        func discoverEffects() -> [AudioUnitComponentDescriptor] {
            lock.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.02)
            return []
        }
    }

    func testRegistrationChangeTriggersARescan() async throws {
        let center = NotificationCenter()
        let name = Notification.Name("test.registrationsChanged")
        let catalog = CountingCatalog()
        let host = AudioUnitHostController(catalog: catalog)
        host.startWatchingRegistrations(center: center, name: name) { nil }
        XCTAssertEqual(catalog.scans, 0)
        center.post(name: name, object: nil)
        for _ in 0..<100 where catalog.scans < 1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(catalog.scans, 1)
        for _ in 0..<100 where host.lastScanDate == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(host.lastScanDate)

        host.stopWatchingRegistrations(center: center)
        center.post(name: name, object: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(catalog.scans, 1, "no scan once watching stops")
    }

    func testAChangeDuringAScanRunsOneMoreScan() async {
        let catalog = CountingCatalog()
        let host = AudioUnitHostController(catalog: catalog)
        async let first: Void = host.rescanAfterRegistrationChange(format: nil)
        await Task.yield()
        await host.rescanAfterRegistrationChange(format: nil)
        await first
        XCTAssertEqual(catalog.scans, 2)
    }

    // MARK: catalog reasons

    func testEachRejectionReasonHasOnePlainReasonAndAdvice() {
        let fmt = format(48_000)
        let cases: [(AudioUnitComponentDescriptor, String)] = [
            (descriptor(sub: 1, kind: .unsupported), "not an audio effect"),
            (descriptor(sub: 2, validates: false), "validation"),
            (descriptor(sub: 3, sandboxSafe: false), "sandbox"),
            (descriptor(sub: 4, channels: [1]), "2 channels"),
        ]
        for (item, word) in cases {
            let reasons = AudioUnitCatalogReasons.reasons(for: item, format: fmt, separateProcess: false)
            XCTAssertEqual(reasons.count, 1, item.name)
            XCTAssertTrue(reasons[0].reason.contains(word), item.name)
            XCTAssertFalse(reasons[0].advice.isEmpty)
            // Same verdict as the compatibility check.
            XCTAssertFalse(item.compatibility(for: fmt, separateProcess: false).compatible)
        }
        XCTAssertTrue(AudioUnitCatalogReasons.reasons(for: descriptor(sub: 9), format: fmt, separateProcess: false).isEmpty)
        // With separate-process loading the sandbox reason is not given.
        XCTAssertTrue(AudioUnitCatalogReasons.reasons(
            for: descriptor(sub: 3, sandboxSafe: false), format: fmt, separateProcess: true
        ).isEmpty)
    }

    func testMultipleReasonsAreAllListed() {
        let item = descriptor(sub: 5, sandboxSafe: false, validates: false, channels: [1])
        let reasons = AudioUnitCatalogReasons.reasons(for: item, format: format(48_000), separateProcess: false)
        XCTAssertEqual(reasons.count, 3)
    }

    func testSandboxRuleStillAppliesWhenOutOfProcessLoadFailed() {
        let item = descriptor(sub: 6, sandboxSafe: false)
        let entry = AudioUnitQuarantineEntry(
            component: item.identity, reason: .instantiationFailed, failureCount: 1,
            lastFailureDescription: "Could not instantiate.", lastFailureAt: Date()
        )
        let reasons = AudioUnitCatalogReasons.reasons(
            for: item, format: format(48_000), separateProcess: true, quarantine: entry
        )
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].reason.contains("sandbox-safe rule still applies"))

        // A sandbox-safe plug-in that failed to load gets its own failure text, not the sandbox rule.
        let safe = descriptor(sub: 7)
        let other = AudioUnitCatalogReasons.quarantineReason(
            for: safe,
            entry: AudioUnitQuarantineEntry(
                component: safe.identity, reason: .instantiationFailed, failureCount: 1,
                lastFailureDescription: "Could not instantiate.", lastFailureAt: Date()
            )
        )
        XCTAssertFalse(other.reason.contains("sandbox-safe"))
    }

    func testIncompatiblePluginsAreHiddenUntilShown() {
        let items = [descriptor(sub: 1), descriptor(sub: 2, validates: false), descriptor(sub: 3, channels: [1])]
        let fmt = format(48_000)
        let hidden = AudioUnitCatalogReasons.visible(items, format: fmt, showIncompatible: false, separateProcess: false)
        XCTAssertEqual(hidden.map(\.identity), [identity(1)])
        let shown = AudioUnitCatalogReasons.visible(items, format: fmt, showIncompatible: true, separateProcess: false)
        XCTAssertEqual(shown.count, 3)
    }

    // MARK: helpers

    private func makeStage(rate: Double, sleep: TimeInterval) throws -> AudioUnitLiveProcessStage {
        let unit = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_LowPassFilter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        ))
        let avFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: 64))
        buffer.frameLength = 64
        let block: AURenderBlock = { _, _, frames, _, list, _ in
            Thread.sleep(forTimeInterval: sleep)
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for index in 0..<buffers.count {
                if let data = buffers[index].mData?.assumingMemoryBound(to: Float.self) {
                    for frame in 0..<Int(frames) { data[frame] = 0.5 }
                }
            }
            return noErr
        }
        let gate = try XCTUnwrap(N60AudioUnitStageFaultGateCreate())
        return AudioUnitLiveProcessStage(
            slotIndex: 0, component: identity(0x73703232), unit: unit, renderBlock: block, outputBuffer: buffer,
            channelCount: 2, maximumFramesPerSlice: 64, sampleRate: rate, latencyFrames: 0, tailFrames: 0,
            wetDryMix: 1, faultGate: gate
        )
    }
}
