import AudioToolbox
import Foundation
import XCTest
@testable import NotchSixty

/// E7 S3 (`e7.rate-adapt`): a plug-in that refuses the device rate is bypassed at that rate with its latency kept,
/// never quarantined, and returns when the rate changes to one it accepts.
@MainActor
final class AudioUnitRateRefusalTests: XCTestCase {
    private static let rates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ]
    private static let latencySeconds = 0.005

    private let refuser = AudioUnitComponentIdentity(
        componentType: 0x61756678, componentSubType: 0x72667331, componentManufacturer: 0x6e363072
    )
    private let other = AudioUnitComponentIdentity(
        componentType: 0x61756678, componentSubType: 0x72667332, componentManufacturer: 0x6e363072
    )

    private func descriptor(_ identity: AudioUnitComponentIdentity, _ name: String) -> AudioUnitComponentDescriptor {
        AudioUnitComponentDescriptor(
            identity: identity, kind: .effect, name: name, manufacturerName: "Notch Labs", typeName: "Effect",
            version: 0x0001_0000, versionString: "1.0.0", hasCustomView: false, hasMIDIInput: false,
            hasMIDIOutput: false, passesAUVal: true, sandboxSafe: true, supportedSymmetricChannelCounts: [2]
        )
    }

    private func format(_ rate: Double) -> AudioUnitRackProcessingFormat {
        AudioUnitRackProcessingFormat(
            sampleRate: rate, channelCount: 2,
            maximumFramesPerSlice: AudioUnitRackProcessingFormat.recommendedMaximumFramesPerSlice(sampleRate: rate)
        )
    }

    private func makeHost(flag: Bool) async throws -> AudioUnitHostController {
        let host = AudioUnitHostController(catalog: Catalog(components: [
            descriptor(refuser, "Refuses above 96 kHz"), descriptor(other, "Accepts all"),
        ]))
        host.rateAdaptEnabled = flag
        host.scan()
        try host.installComponent(refuser, inSlot: 0)
        try host.installComponent(other, inSlot: 1)
        for slot in 0...1 {
            await host.prepareSlotOffline(slot, format: format(48_000), using: backend)
        }
        try host.setBypassed(false, slot: 0)
        try host.setBypassed(false, slot: 1)
        return host
    }

    /// Mirrors a rate change: un-bypassed slots are re-prepared at the new rate (preparation re-bypasses them)
    /// and the user's un-bypass is restored for every slot that can run.
    private func switchRate(_ host: AudioUnitHostController, _ f: AudioUnitRackProcessingFormat) async {
        for slot in 0..<host.rackConfiguration.slots.count where host.rackConfiguration.slots[slot].component != nil {
            try? host.setBypassed(false, slot: slot)
        }
        await host.prepareActiveSlotsForLive(format: f, using: backend)
        for slot in 0..<host.rackConfiguration.slots.count where host.rackConfiguration.slots[slot].component != nil {
            try? host.setBypassed(false, slot: slot)
        }
    }

    private let backend = RefusingBackend(refusing: [refusingIdentity], limit: 96_000)

    func testRefusalAtEightRatesBypassesOnlyThatSlotWithAlignedLatencyAndNoQuarantine() async throws {
        let host = try await makeHost(flag: true)
        // Prepared once at 48 kHz, so the probe latency is known.
        await switchRate(host, format(48_000))
        XCTAssertEqual(try host.executionPlan(for: format(48_000)).slots.prefix(2).map(\.mode), [.process, .process])

        for rate in Self.rates {
            let f = format(rate)
            await switchRate(host, f)
            let plan = try host.executionPlan(for: f)
            XCTAssertTrue(host.quarantine.entries.isEmpty, "no quarantine entry at \(rate)")
            XCTAssertEqual(host.lifecycleByComponent[refuser] == .quarantined, false)
            XCTAssertEqual(plan.slots[1].mode, .process, "other slot renders at \(rate)")
            if rate > 96_000 {
                XCTAssertEqual(plan.slots[0].mode, .latencyMatchedBypass, "\(rate)")
                XCTAssertEqual(
                    plan.slots[0].reason, AudioUnitRateRefusal.message(rate: rate)
                )
                let expected = AudioUnitProbeResult.conservativeFrameCount(
                    seconds: Self.latencySeconds, sampleRate: rate
                )
                XCTAssertEqual(plan.slots[0].latencyFrames, expected)
                XCTAssertEqual(plan.slots[0].dryCompensationFrames, expected)
                XCTAssertEqual(plan.totalLatencyFrames, expected * 2)
                XCTAssertEqual(
                    host.rateRefusalNote(forSlot: 0, sampleRate: rate), AudioUnitRateRefusal.message(rate: rate)
                )
            } else {
                XCTAssertEqual(plan.slots[0].mode, .process, "\(rate)")
                XCTAssertNil(host.rateRefusalNote(forSlot: 0, sampleRate: rate))
            }
        }
    }

    func testChangeBackTo48kHzRestoresTheSlot() async throws {
        let host = try await makeHost(flag: true)
        await switchRate(host, format(48_000))
        await switchRate(host, format(384_000))
        XCTAssertEqual(try host.executionPlan(for: format(384_000)).slots[0].mode, .latencyMatchedBypass)

        await switchRate(host, format(48_000))
        let plan = try host.executionPlan(for: format(48_000))
        XCTAssertEqual(plan.slots[0].mode, .process)
        XCTAssertNil(plan.slots[0].reason)
        XCTAssertTrue(host.quarantine.entries.isEmpty)
    }

    func testLiveRackBuildsWithRefusedSlotBypassedAtHighRate() async throws {
        let host = try await makeHost(flag: true)
        await switchRate(host, format(48_000))
        let f = format(192_000)
        // Only the refuser stays in the rack so no real Audio Unit is needed for a live build.
        try host.removeComponent(fromSlot: 1)
        await switchRate(host, f)
        let runtime = try await host.makeLiveRackRuntime(format: f)
        defer { runtime?.stopFaultMonitoring() }
        XCTAssertEqual(
            runtime?.totalLatencyFrames,
            try host.executionPlan(for: f).totalLatencyFrames
        )
        XCTAssertTrue(host.quarantine.entries.isEmpty)
    }

    func testFlagOffQuarantinesAsBefore() async throws {
        let host = try await makeHost(flag: false)
        await switchRate(host, format(384_000))
        XCTAssertNotNil(host.quarantine.entry(for: refuser))
        XCTAssertTrue(host.rateRefusals.isEmpty)
    }
}

private let refusingIdentity = AudioUnitComponentIdentity(
    componentType: 0x61756678, componentSubType: 0x72667331, componentManufacturer: 0x6e363072
)

private struct Catalog: AudioUnitComponentCataloging {
    let components: [AudioUnitComponentDescriptor]
    func discoverEffects() -> [AudioUnitComponentDescriptor] { components }
}

/// Refuses `setFormat` above `limit` for the listed components; every other request succeeds.
private struct RefusingBackend: AudioUnitOfflinePreparing {
    let refusing: [AudioUnitComponentIdentity]
    let limit: Double

    func prepare(
        component: AudioUnitComponentDescriptor,
        format: AudioUnitRackProcessingFormat,
        restoringState: Data?
    ) async throws -> AudioUnitOfflinePreparationReport {
        if refusing.contains(component.identity), format.sampleRate > limit {
            throw AudioUnitOfflinePreparationError.unsupportedSampleRate(
                component: component.identity, rate: format.sampleRate
            )
        }
        let metrics = AudioUnitOfflineRenderMetrics(
            renderedFrames: 512, renderPassCount: 2, channelCount: format.channelCount,
            maximumAbsoluteSample: 0.1, rmsByChannel: Array(repeating: 0.05, count: format.channelCount),
            allSamplesFinite: true
        )
        return AudioUnitOfflinePreparationReport(
            component: component.identity, format: format,
            probe: AudioUnitProbeResult(
                component: component.identity, sampleRate: format.sampleRate,
                inputChannelCount: format.channelCount, outputChannelCount: format.channelCount,
                maximumFramesToRender: format.maximumFramesPerSlice, latencySeconds: 0.005,
                tailTimeSeconds: 0, supportsFullState: false, supportsHostBypass: true
            ),
            capturedFullState: nil, stateRestored: false, stateRecaptured: false,
            initialRender: metrics, postResetRender: metrics,
            latencyStableAcrossReset: true, tailStableAcrossReset: true, renderResourcesReleased: true
        )
    }
}
