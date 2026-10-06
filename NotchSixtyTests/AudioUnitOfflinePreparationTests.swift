import AudioToolbox
import AVFAudio
import Foundation
import XCTest
@testable import NotchSixty

@MainActor
final class AudioUnitOfflinePreparationTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let mockIdentity = AudioUnitComponentIdentity(
        componentType: 0x61756678, // aufx
        componentSubType: 0x70383030, // p800
        componentManufacturer: 0x6e363079 // n60y
    )

    func testAppleLowPassCanInstantiateAllocateRenderResetAndTearDownOffline() async throws {
        let identity = AudioUnitComponentIdentity(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_LowPassFilter,
            componentManufacturer: kAudioUnitManufacturer_Apple
        )
        guard let descriptor = SystemAudioUnitComponentCatalog()
            .discoverEffects()
            .first(where: { $0.identity == identity }) else {
            throw XCTSkip("Apple Low Pass Audio Unit is not registered on this runner.")
        }

        let format = AudioUnitRackProcessingFormat(
            sampleRate: sampleRate,
            channelCount: 2,
            maximumFramesPerSlice: 512
        )
        guard descriptor.compatibility(for: format).compatible else {
            throw XCTSkip("Apple Low Pass does not advertise compatible stereo metadata on this runner.")
        }

        let report = try await SystemAudioUnitOfflinePreparationBackend(
            renderPassCount: 3
        ).prepare(
            component: descriptor,
            format: format,
            restoringState: nil
        )

        XCTAssertEqual(report.component, identity)
        XCTAssertEqual(report.probe.inputChannelCount, 2)
        XCTAssertEqual(report.probe.outputChannelCount, 2)
        XCTAssertGreaterThanOrEqual(report.probe.maximumFramesToRender, 512)
        XCTAssertTrue(report.initialRender.allSamplesFinite)
        XCTAssertTrue(report.postResetRender.allSamplesFinite)
        XCTAssertEqual(report.initialRender.channelCount, 2)
        XCTAssertEqual(report.postResetRender.channelCount, 2)
        XCTAssertTrue(report.latencyStableAcrossReset)
        XCTAssertTrue(report.tailStableAcrossReset)
        XCTAssertTrue(report.renderResourcesReleased)
        XCTAssertGreaterThan(report.initialRender.renderedFrames, 0)
    }

    func testCapturedAppleStateCanRoundTripThroughFreshOfflineInstance() async throws {
        let identity = AudioUnitComponentIdentity(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_LowPassFilter,
            componentManufacturer: kAudioUnitManufacturer_Apple
        )
        guard let descriptor = SystemAudioUnitComponentCatalog()
            .discoverEffects()
            .first(where: { $0.identity == identity }) else {
            throw XCTSkip("Apple Low Pass Audio Unit is not registered on this runner.")
        }
        let format = AudioUnitRackProcessingFormat(
            sampleRate: sampleRate,
            channelCount: 2,
            maximumFramesPerSlice: 512
        )
        guard descriptor.compatibility(for: format).compatible else {
            throw XCTSkip("Apple Low Pass does not advertise compatible stereo metadata on this runner.")
        }

        let backend = SystemAudioUnitOfflinePreparationBackend(
            renderPassCount: 2
        )
        let first = try await backend.prepare(
            component: descriptor,
            format: format,
            restoringState: nil
        )
        guard let state = first.capturedFullState else {
            throw XCTSkip("Apple Low Pass did not expose serializable full state.")
        }

        let second = try await backend.prepare(
            component: descriptor,
            format: format,
            restoringState: state
        )

        XCTAssertTrue(second.stateRestored)
        XCTAssertTrue(second.stateRecaptured)
        XCTAssertNotNil(second.capturedFullState)
        XCTAssertLessThanOrEqual(
            second.capturedFullState?.count ?? 0,
            AudioUnitRackSlotState.maximumOpaqueStateBytes
        )
    }

    func testSameComponentCanHaveDifferentPreparedLatencyPerSlot() async throws {
        let descriptor = mockDescriptor(channels: [2])
        let host = AudioUnitHostController(
            catalog: OfflineMockCatalog(components: [descriptor])
        )
        host.scan()
        try host.installComponent(mockIdentity, inSlot: 0)
        try host.installComponent(mockIdentity, inSlot: 1)

        let stateA = try PropertyListSerialization.data(
            fromPropertyList: ["latencyFrames": 64],
            format: .binary,
            options: 0
        )
        let stateB = try PropertyListSerialization.data(
            fromPropertyList: ["latencyFrames": 192],
            format: .binary,
            options: 0
        )
        try host.setOpaqueFullState(stateA, slot: 0)
        try host.setOpaqueFullState(stateB, slot: 1)

        let format = AudioUnitRackProcessingFormat(
            sampleRate: sampleRate,
            channelCount: 2,
            maximumFramesPerSlice: 512
        )
        let backend = StateSensitiveOfflineBackend()
        await host.prepareSlotOffline(0, format: format, using: backend)
        await host.prepareSlotOffline(1, format: format, using: backend)

        XCTAssertEqual(host.probeResult(forSlot: 0)?.latencyFrames, 64)
        XCTAssertEqual(host.probeResult(forSlot: 1)?.latencyFrames, 192)

        try host.setBypassed(false, slot: 0)
        try host.setBypassed(false, slot: 1)
        let plan = try host.executionPlan(for: format)

        XCTAssertEqual(plan.slots[0].latencyFrames, 64)
        XCTAssertEqual(plan.slots[1].latencyFrames, 192)
        XCTAssertEqual(plan.totalLatencyFrames, 256)
    }

    func testChangingOpaqueStateInvalidatesOnlyThatSlotPreparation() async throws {
        let descriptor = mockDescriptor(channels: [2])
        let host = AudioUnitHostController(
            catalog: OfflineMockCatalog(components: [descriptor])
        )
        host.scan()
        try host.installComponent(mockIdentity, inSlot: 0)
        try host.installComponent(mockIdentity, inSlot: 1)

        let format = AudioUnitRackProcessingFormat(
            sampleRate: sampleRate,
            channelCount: 2
        )
        let backend = FixedOfflineBackend(
            report: makeReport(
                identity: mockIdentity,
                format: format,
                latencyFrames: 96
            )
        )
        await host.prepareSlotOffline(0, format: format, using: backend)
        await host.prepareSlotOffline(1, format: format, using: backend)
        XCTAssertNotNil(host.probeResult(forSlot: 0))
        XCTAssertNotNil(host.probeResult(forSlot: 1))

        let changedState = try PropertyListSerialization.data(
            fromPropertyList: ["preset": "changed"],
            format: .binary,
            options: 0
        )
        try host.setOpaqueFullState(changedState, slot: 0)

        XCTAssertNil(host.probeResult(forSlot: 0))
        XCTAssertNotNil(host.probeResult(forSlot: 1))
        XCTAssertTrue(host.rackConfiguration.slots[0].bypassed)
        XCTAssertThrowsError(try host.setBypassed(false, slot: 0)) {
            error in
            XCTAssertEqual(
                error as? AudioUnitRackError,
                .componentNotPrepared(self.mockIdentity)
            )
        }
        XCTAssertNoThrow(try host.setBypassed(false, slot: 1))
    }

    func testOfflineStateRestoreFailureQuarantinesAndForcesBypass() async throws {
        let descriptor = mockDescriptor(channels: [2])
        let host = AudioUnitHostController(
            catalog: OfflineMockCatalog(components: [descriptor])
        )
        host.scan()
        try host.installComponent(mockIdentity, inSlot: 0)

        let format = AudioUnitRackProcessingFormat(
            sampleRate: sampleRate,
            channelCount: 2
        )
        await host.prepareSlotOffline(
            0,
            format: format,
            using: ThrowingOfflineBackend(
                error: AudioUnitOfflinePreparationError.stateRestoreFailed
            )
        )

        XCTAssertEqual(
            host.quarantine.entry(for: mockIdentity)?.reason,
            .stateRestoreFailure
        )
        XCTAssertEqual(
            host.lifecycleByComponent[mockIdentity],
            .quarantined
        )
        XCTAssertTrue(host.rackConfiguration.slots[0].bypassed)
        XCTAssertNil(host.probeResult(forSlot: 0))
    }

    func testReportRejectsUnreleasedResourcesAndNondeterministicLatency() throws {
        let format = AudioUnitRackProcessingFormat(
            sampleRate: sampleRate,
            channelCount: 2
        )
        var report = makeReport(
            identity: mockIdentity,
            format: format,
            latencyFrames: 64
        )
        report = AudioUnitOfflinePreparationReport(
            component: report.component,
            format: report.format,
            probe: report.probe,
            capturedFullState: report.capturedFullState,
            stateRestored: report.stateRestored,
            stateRecaptured: report.stateRecaptured,
            initialRender: report.initialRender,
            postResetRender: report.postResetRender,
            latencyStableAcrossReset: false,
            tailStableAcrossReset: true,
            renderResourcesReleased: true
        )
        XCTAssertThrowsError(try report.validate()) { error in
            XCTAssertEqual(
                error as? AudioUnitOfflinePreparationError,
                .latencyChangedAcrossReset
            )
        }

        let leaked = AudioUnitOfflinePreparationReport(
            component: report.component,
            format: report.format,
            probe: report.probe,
            capturedFullState: nil,
            stateRestored: false,
            stateRecaptured: false,
            initialRender: report.initialRender,
            postResetRender: report.postResetRender,
            latencyStableAcrossReset: true,
            tailStableAcrossReset: true,
            renderResourcesReleased: false
        )
        XCTAssertThrowsError(try leaked.validate()) { error in
            XCTAssertEqual(
                error as? AudioUnitOfflinePreparationError,
                .renderResourcesNotReleased
            )
        }
    }

    private func mockDescriptor(
        channels: [Int]
    ) -> AudioUnitComponentDescriptor {
        AudioUnitComponentDescriptor(
            identity: mockIdentity,
            kind: .effect,
            name: "PR80 Mock",
            manufacturerName: "Notch Labs",
            typeName: "Effect",
            version: 0x00010000,
            versionString: "1.0.0",
            hasCustomView: false,
            hasMIDIInput: false,
            hasMIDIOutput: false,
            passesAUVal: true,
            sandboxSafe: true,
            supportedSymmetricChannelCounts: channels
        )
    }

    private func makeReport(
        identity: AudioUnitComponentIdentity,
        format: AudioUnitRackProcessingFormat,
        latencyFrames: Int,
        capturedState: Data? = nil
    ) -> AudioUnitOfflinePreparationReport {
        let latencySeconds =
            Double(latencyFrames) / format.sampleRate
        let metrics = AudioUnitOfflineRenderMetrics(
            renderedFrames: 1_024,
            renderPassCount: 2,
            channelCount: format.channelCount,
            maximumAbsoluteSample: 0.1,
            rmsByChannel: Array(
                repeating: 0.05,
                count: format.channelCount
            ),
            allSamplesFinite: true
        )
        return AudioUnitOfflinePreparationReport(
            component: identity,
            format: format,
            probe: AudioUnitProbeResult(
                component: identity,
                sampleRate: format.sampleRate,
                inputChannelCount: format.channelCount,
                outputChannelCount: format.channelCount,
                maximumFramesToRender: format.maximumFramesPerSlice,
                latencySeconds: latencySeconds,
                tailTimeSeconds: 0.1,
                supportsFullState: capturedState != nil,
                supportsHostBypass: true
            ),
            capturedFullState: capturedState,
            stateRestored: capturedState != nil,
            stateRecaptured: capturedState != nil,
            initialRender: metrics,
            postResetRender: metrics,
            latencyStableAcrossReset: true,
            tailStableAcrossReset: true,
            renderResourcesReleased: true
        )
    }
}

private struct OfflineMockCatalog: AudioUnitComponentCataloging {
    let components: [AudioUnitComponentDescriptor]

    func discoverEffects() -> [AudioUnitComponentDescriptor] {
        components
    }
}

private struct FixedOfflineBackend: AudioUnitOfflinePreparing {
    let report: AudioUnitOfflinePreparationReport

    func prepare(
        component: AudioUnitComponentDescriptor,
        format: AudioUnitRackProcessingFormat,
        restoringState: Data?
    ) async throws -> AudioUnitOfflinePreparationReport {
        report
    }
}

private struct ThrowingOfflineBackend: AudioUnitOfflinePreparing {
    let error: AudioUnitOfflinePreparationError

    func prepare(
        component: AudioUnitComponentDescriptor,
        format: AudioUnitRackProcessingFormat,
        restoringState: Data?
    ) async throws -> AudioUnitOfflinePreparationReport {
        throw error
    }
}

private struct StateSensitiveOfflineBackend: AudioUnitOfflinePreparing {
    func prepare(
        component: AudioUnitComponentDescriptor,
        format: AudioUnitRackProcessingFormat,
        restoringState: Data?
    ) async throws -> AudioUnitOfflinePreparationReport {
        var latencyFrames = 0
        if let restoringState,
           let object = try? PropertyListSerialization.propertyList(
                from: restoringState,
                options: [],
                format: nil
           ),
           let dictionary = object as? [String: Any],
           let latency = dictionary["latencyFrames"] as? Int {
            latencyFrames = latency
        }

        let metrics = AudioUnitOfflineRenderMetrics(
            renderedFrames: 1_024,
            renderPassCount: 2,
            channelCount: format.channelCount,
            maximumAbsoluteSample: 0.1,
            rmsByChannel: Array(
                repeating: 0.05,
                count: format.channelCount
            ),
            allSamplesFinite: true
        )
        return AudioUnitOfflinePreparationReport(
            component: component.identity,
            format: format,
            probe: AudioUnitProbeResult(
                component: component.identity,
                sampleRate: format.sampleRate,
                inputChannelCount: format.channelCount,
                outputChannelCount: format.channelCount,
                maximumFramesToRender: format.maximumFramesPerSlice,
                latencySeconds: Double(latencyFrames) / format.sampleRate,
                tailTimeSeconds: 0.1,
                supportsFullState: restoringState != nil,
                supportsHostBypass: true
            ),
            capturedFullState: restoringState,
            stateRestored: restoringState != nil,
            stateRecaptured: restoringState != nil,
            initialRender: metrics,
            postResetRender: metrics,
            latencyStableAcrossReset: true,
            tailStableAcrossReset: true,
            renderResourcesReleased: true
        )
    }
}
