import Foundation
import XCTest
@testable import NotchSixty

@MainActor
final class AudioUnitHostFoundationTests: XCTestCase {
    private let identity = AudioUnitComponentIdentity(
        componentType: 0x61756678, // aufx
        componentSubType: 0x74657374, // test
        componentManufacturer: 0x6e363079 // n60y
    )

    func testRackRoundTripPreservesOpaqueStateAndLatencyMetadata() throws {
        var slot = AudioUnitRackSlotState(
            component: identity,
            displayName: "Mock Effect",
            manufacturerName: "Notch Labs",
            bypassed: true,
            wetDryMix: 0.75,
            opaqueFullState: Data([0, 1, 2, 3, 4]),
            lastKnownLatencyFrames: 128,
            lastKnownTailFrames: 2_048
        )
        try slot.validate()

        let rack = AudioUnitRackConfiguration(slots: [
            slot,
            AudioUnitRackSlotState(),
            AudioUnitRackSlotState(),
            AudioUnitRackSlotState(),
        ])
        let encoded = try JSONEncoder().encode(rack)
        let decoded = try JSONDecoder().decode(
            AudioUnitRackConfiguration.self,
            from: encoded
        )

        XCTAssertEqual(decoded, rack)
        XCTAssertEqual(decoded.slots[0].opaqueFullState, Data([0, 1, 2, 3, 4]))
        XCTAssertEqual(decoded.slots[0].lastKnownLatencyFrames, 128)
        XCTAssertEqual(decoded.slots[0].lastKnownTailFrames, 2_048)
    }

    func testLegacyContentPresetWithoutRackDecodesToEmptyRack() throws {
        struct Legacy: Encodable {
            let schemaVersion = ContentPresetState.currentSchemaVersion
            let stereoEQ = StereoEQConfiguration()
            let inputPreampDB = 0.0
            let headroomAttenuationDB = 0.0
            let dynamics = DynamicsConfiguration()
        }

        let data = try JSONEncoder().encode(Legacy())
        let decoded = try JSONDecoder().decode(
            ContentPresetState.self,
            from: data
        )

        XCTAssertEqual(
            decoded.audioUnitRack.slots.count,
            AudioUnitRackConfiguration.defaultSlotCount
        )
        XCTAssertEqual(decoded.audioUnitRack.occupiedSlotCount, 0)
    }

    func testActiveExecutionPlanAggregatesLatencyTailAndWetDryDelay() throws {
        var first = AudioUnitRackSlotState(
            component: identity,
            displayName: "Mock Effect",
            manufacturerName: "Notch Labs",
            bypassed: false,
            wetDryMix: 0.5
        )
        let secondIdentity = AudioUnitComponentIdentity(
            componentType: 0x61756678,
            componentSubType: 0x74657332,
            componentManufacturer: 0x6e363079
        )
        let second = AudioUnitRackSlotState(
            component: secondIdentity,
            displayName: "Mock Effect 2",
            manufacturerName: "Notch Labs",
            bypassed: false,
            wetDryMix: 1
        )
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 12,
            maximumFramesPerSlice: 512
        )
        let firstProbe = probe(
            identity: identity,
            format: format,
            latencySeconds: 0.002,
            tailSeconds: 0.25
        )
        first.recordProbe(firstProbe)

        let plan = try AudioUnitRackPreparationPlanner().prepare(
            configuration: AudioUnitRackConfiguration(slots: [first, second]),
            descriptors: [
                descriptor(identity: identity, channels: [2, 12]),
                descriptor(identity: secondIdentity, channels: [12]),
            ],
            probes: [
                firstProbe,
                probe(
                    identity: secondIdentity,
                    format: format,
                    latencySeconds: 0.001,
                    tailSeconds: 0.10
                ),
            ],
            quarantine: AudioUnitQuarantineRegistry(),
            format: format
        )

        XCTAssertEqual(plan.slots[0].mode, .process)
        XCTAssertEqual(plan.slots[0].latencyFrames, 96)
        XCTAssertEqual(plan.slots[0].dryCompensationFrames, 96)
        XCTAssertEqual(plan.slots[1].latencyFrames, 48)
        XCTAssertEqual(plan.totalLatencyFrames, 144)
        XCTAssertEqual(plan.totalTailFrames, 16_800)
        XCTAssertFalse(plan.requiresLatencyMatchedBypass)
    }

    func testMissingComponentFallsBackOnlyWithKnownLatency() throws {
        let slot = AudioUnitRackSlotState(
            component: identity,
            displayName: "Gone",
            manufacturerName: "Vendor",
            bypassed: false,
            wetDryMix: 1,
            lastKnownLatencyFrames: 240,
            lastKnownTailFrames: 0
        )
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 2
        )
        let plan = try AudioUnitRackPreparationPlanner().prepare(
            configuration: AudioUnitRackConfiguration(slots: [slot]),
            descriptors: [],
            probes: [],
            quarantine: AudioUnitQuarantineRegistry(),
            format: format
        )

        XCTAssertEqual(plan.slots[0].mode, .latencyMatchedBypass)
        XCTAssertEqual(plan.slots[0].latencyFrames, 240)
        XCTAssertEqual(plan.totalLatencyFrames, 240)
        XCTAssertTrue(plan.requiresLatencyMatchedBypass)
    }

    func testMissingComponentWithoutKnownLatencyFailsClosed() {
        let slot = AudioUnitRackSlotState(
            component: identity,
            displayName: "Gone",
            manufacturerName: "Vendor",
            bypassed: false
        )
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 2
        )

        XCTAssertThrowsError(
            try AudioUnitRackPreparationPlanner().prepare(
                configuration: AudioUnitRackConfiguration(slots: [slot]),
                descriptors: [],
                probes: [],
                quarantine: AudioUnitQuarantineRegistry(),
                format: format
            )
        ) { error in
            guard case AudioUnitRackError.missingBypassLatency = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUnsupportedSurroundLayoutUsesKnownLatencyMatchedBypass() throws {
        let slot = AudioUnitRackSlotState(
            component: identity,
            displayName: "Stereo Only",
            manufacturerName: "Vendor",
            bypassed: false,
            lastKnownLatencyFrames: 64
        )
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 12
        )
        let plan = try AudioUnitRackPreparationPlanner().prepare(
            configuration: AudioUnitRackConfiguration(slots: [slot]),
            descriptors: [descriptor(identity: identity, channels: [1, 2])],
            probes: [],
            quarantine: AudioUnitQuarantineRegistry(),
            format: format
        )

        XCTAssertEqual(plan.slots[0].mode, .latencyMatchedBypass)
        XCTAssertEqual(plan.slots[0].latencyFrames, 64)
        XCTAssertTrue(plan.slots[0].reason?.contains("12-in") == true)
    }

    func testQuarantinedComponentCannotProcess() throws {
        let slot = AudioUnitRackSlotState(
            component: identity,
            displayName: "Risky",
            manufacturerName: "Vendor",
            bypassed: false,
            lastKnownLatencyFrames: 32
        )
        var quarantine = AudioUnitQuarantineRegistry()
        quarantine.recordFailure(
            component: identity,
            reason: .runtimeFailure,
            description: "mock render failure",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 2
        )
        let plan = try AudioUnitRackPreparationPlanner().prepare(
            configuration: AudioUnitRackConfiguration(slots: [slot]),
            descriptors: [descriptor(identity: identity, channels: [2])],
            probes: [probe(
                identity: identity,
                format: format,
                latencySeconds: 32.0 / 48_000.0,
                tailSeconds: 0
            )],
            quarantine: quarantine,
            format: format
        )

        XCTAssertEqual(plan.slots[0].mode, .latencyMatchedBypass)
        XCTAssertTrue(plan.requiresLatencyMatchedBypass)
    }

    func testHostControllerScanInstallProbeAndEnableLifecycle() async throws {
        let component = descriptor(identity: identity, channels: [2, 12])
        let host = AudioUnitHostController(
            catalog: MockCatalog(components: [component])
        )
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 12,
            maximumFramesPerSlice: 512
        )

        host.scan(format: format)
        XCTAssertEqual(host.discoveredComponents, [component])
        XCTAssertEqual(host.lifecycleByComponent[identity], .discovered)

        try host.installComponent(identity, inSlot: 0)
        XCTAssertTrue(host.rackConfiguration.slots[0].bypassed)

        let result = probe(
            identity: identity,
            format: format,
            latencySeconds: 0.003,
            tailSeconds: 0.2
        )
        await host.probe(
            component: identity,
            format: format,
            using: MockProbeBackend(result: .success(result))
        )

        XCTAssertEqual(host.lifecycleByComponent[identity], .prepared)
        XCTAssertEqual(
            host.rackConfiguration.slots[0].lastKnownLatencyFrames,
            144
        )
        XCTAssertEqual(
            host.rackConfiguration.slots[0].lastKnownTailFrames,
            9_600
        )

        try host.setBypassed(false, slot: 0)
        let plan = try host.executionPlan(for: format)
        XCTAssertEqual(plan.slots[0].mode, .process)
        XCTAssertEqual(plan.totalLatencyFrames, 144)
    }

    func testProbeFailureQuarantinesComponent() async {
        let component = descriptor(identity: identity, channels: [2])
        let host = AudioUnitHostController(
            catalog: MockCatalog(components: [component])
        )
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 2
        )

        host.scan(format: format)
        await host.probe(
            component: identity,
            format: format,
            using: MockProbeBackend(
                result: .failure(MockProbeError.failed)
            )
        )

        XCTAssertEqual(host.lifecycleByComponent[identity], .quarantined)
        XCTAssertTrue(host.quarantine.isQuarantined(identity))
        XCTAssertEqual(
            host.quarantine.entry(for: identity)?.failureCount,
            1
        )

        host.clearQuarantine(identity)
        XCTAssertFalse(host.quarantine.isQuarantined(identity))
        XCTAssertEqual(host.lifecycleByComponent[identity], .discovered)
    }

    func testOpaqueStateSizeIsBounded() {
        let oversized = Data(
            count: AudioUnitRackSlotState.maximumOpaqueStateBytes + 1
        )
        let slot = AudioUnitRackSlotState(
            component: identity,
            displayName: "Mock",
            manufacturerName: "Vendor",
            opaqueFullState: oversized
        )
        XCTAssertThrowsError(
            try AudioUnitRackConfiguration(slots: [slot]).validate()
        ) { error in
            guard case AudioUnitRackError.slotStateTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func descriptor(
        identity: AudioUnitComponentIdentity,
        channels: [Int]
    ) -> AudioUnitComponentDescriptor {
        AudioUnitComponentDescriptor(
            identity: identity,
            kind: .effect,
            name: "Mock Effect",
            manufacturerName: "Notch Labs",
            typeName: "Effect",
            version: 0x00010000,
            versionString: "1.0.0",
            hasCustomView: true,
            hasMIDIInput: false,
            hasMIDIOutput: false,
            passesAUVal: true,
            sandboxSafe: true,
            supportedSymmetricChannelCounts: channels
        )
    }

    private func probe(
        identity: AudioUnitComponentIdentity,
        format: AudioUnitRackProcessingFormat,
        latencySeconds: Double,
        tailSeconds: Double
    ) -> AudioUnitProbeResult {
        AudioUnitProbeResult(
            component: identity,
            sampleRate: format.sampleRate,
            inputChannelCount: format.channelCount,
            outputChannelCount: format.channelCount,
            maximumFramesToRender: max(4_096, format.maximumFramesPerSlice),
            latencySeconds: latencySeconds,
            tailTimeSeconds: tailSeconds,
            supportsFullState: true,
            supportsHostBypass: true
        )
    }
}

private struct MockCatalog: AudioUnitComponentCataloging {
    let components: [AudioUnitComponentDescriptor]

    func discoverEffects() -> [AudioUnitComponentDescriptor] {
        components
    }
}

private enum MockProbeError: Error {
    case failed
}

private struct MockProbeBackend: AudioUnitHostProbeBackend {
    let result: Result<AudioUnitProbeResult, Error>

    func probe(
        component: AudioUnitComponentDescriptor,
        format: AudioUnitRackProcessingFormat
    ) async throws -> AudioUnitProbeResult {
        try result.get()
    }
}
