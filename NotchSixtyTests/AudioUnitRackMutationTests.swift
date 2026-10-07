import Foundation
import XCTest
@testable import NotchSixty

@MainActor
final class AudioUnitRackMutationTests: XCTestCase {
    private let identity = AudioUnitComponentIdentity(
        componentType: 0x61756678,
        componentSubType: 0x6d383230,
        componentManufacturer: 0x6e363079
    )

    func testSwitchboardCrossfadesEqualLatencyGenerations() async throws {
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 2,
            maximumFramesPerSlice: 64
        )
        let old = try makeGainRuntime(
            gain: 1,
            latency: 0,
            format: format
        )
        let new = try makeGainRuntime(
            gain: 0,
            latency: 0,
            format: format
        )
        let switchboard = try AudioUnitLiveRackSwitchboard(
            format: format,
            initialRuntime: old
        )
        var processor = switchboard.processor

        let transition = Task {
            try await switchboard.transition(
                to: new,
                crossfadeFrames: 4
            )
        }
        await Task.yield()

        var input = [Float](repeating: 1, count: 8)
        var output = [Float](repeating: -1, count: 8)
        let rendered = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                N60AudioUnitLiveRackProcess(
                    &processor,
                    source.baseAddress!,
                    destination.baseAddress!,
                    4,
                    2,
                    0
                )
            }
        }
        XCTAssertTrue(rendered)
        try await transition.value

        let expected: [Float] = [
            0.75, 0.75,
            0.50, 0.50,
            0.25, 0.25,
            0.00, 0.00,
        ]
        for index in output.indices {
            XCTAssertEqual(
                output[index],
                expected[index],
                accuracy: 0.000_001
            )
        }
        XCTAssertEqual(
            switchboard.status.renderedGeneration,
            2
        )
    }

    func testSwitchboardRejectsLatencyChangeWithoutRestart() async throws {
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 2,
            maximumFramesPerSlice: 64
        )
        let old = try makeGainRuntime(
            gain: 1,
            latency: 10,
            format: format
        )
        let new = try makeGainRuntime(
            gain: 1,
            latency: 11,
            format: format
        )
        let switchboard = try AudioUnitLiveRackSwitchboard(
            format: format,
            initialRuntime: old
        )

        do {
            try await switchboard.transition(
                to: new,
                crossfadeFrames: 16
            )
            XCTFail("Expected latency-changing transition rejection.")
        } catch let error as AudioUnitRackGenerationExchangeError {
            XCTAssertEqual(
                error,
                .latencyChangeRequiresRestart(
                    current: 10,
                    candidate: 11
                )
            )
        }
    }

    func testMutationCandidateDoesNotCommitUntilExplicitCommit() async throws {
        let descriptor = mockDescriptor()
        let host = AudioUnitHostController(
            catalog: PR82MockCatalog(components: [descriptor])
        )
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 2,
            maximumFramesPerSlice: 64
        )
        host.scan(format: format)

        let original = host.rackConfiguration
        let candidate = try await host.makeMutationCandidate(
            applying: .install(
                component: identity,
                slot: 0,
                initiallyBypassed: true
            ),
            format: format,
            using: PR82UnexpectedPreparationBackend()
        )

        XCTAssertEqual(host.rackConfiguration, original)
        XCTAssertEqual(
            candidate.configuration.slots[0].component,
            identity
        )
        XCTAssertTrue(candidate.configuration.slots[0].bypassed)
        XCTAssertEqual(candidate.plan.slots[0].mode, .latencyMatchedBypass)

        try host.commitMutationCandidate(candidate)
        XCTAssertEqual(
            host.rackConfiguration.slots[0].component,
            identity
        )
    }

    func testReorderPreservesSlotIdentityAndDefersCommit() async throws {
        let descriptor = mockDescriptor()
        let host = AudioUnitHostController(
            catalog: PR82MockCatalog(components: [descriptor])
        )
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 2,
            maximumFramesPerSlice: 64
        )
        host.scan(format: format)

        let install = try await host.makeMutationCandidate(
            applying: .install(
                component: identity,
                slot: 0,
                initiallyBypassed: true
            ),
            format: format,
            using: PR82UnexpectedPreparationBackend()
        )
        try host.commitMutationCandidate(install)

        let installedID = host.rackConfiguration.slots[0].id
        let moved = try await host.makeMutationCandidate(
            applying: .move(from: 0, to: 2),
            format: format,
            using: PR82UnexpectedPreparationBackend()
        )

        XCTAssertEqual(
            host.rackConfiguration.slots[0].id,
            installedID
        )
        XCTAssertEqual(
            moved.configuration.slots[2].id,
            installedID
        )
        XCTAssertEqual(
            moved.configuration.slots[2].component,
            identity
        )
    }

    func testFailedCandidatePreparationLeavesCurrentRackUntouched() async throws {
        let descriptor = mockDescriptor()
        let host = AudioUnitHostController(
            catalog: PR82MockCatalog(components: [descriptor])
        )
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 2,
            maximumFramesPerSlice: 64
        )
        host.scan(format: format)

        let install = try await host.makeMutationCandidate(
            applying: .install(
                component: identity,
                slot: 0,
                initiallyBypassed: true
            ),
            format: format,
            using: PR82UnexpectedPreparationBackend()
        )
        try host.commitMutationCandidate(install)
        let before = host.rackConfiguration

        do {
            _ = try await host.makeMutationCandidate(
                applying: .setBypassed(
                    slot: 0,
                    bypassed: false
                ),
                format: format,
                using: PR82ThrowingPreparationBackend()
            )
            XCTFail("Expected candidate preparation to fail.")
        } catch let error as AudioUnitRackMutationError {
            guard case .candidatePreparationFailed(let slot, _) = error else {
                return XCTFail("Unexpected mutation error: \(error)")
            }
            XCTAssertEqual(slot, 0)
        }

        XCTAssertEqual(host.rackConfiguration, before)
        XCTAssertTrue(host.rackConfiguration.slots[0].bypassed)
        XCTAssertFalse(host.quarantine.isQuarantined(identity))
    }

    private func mockDescriptor() -> AudioUnitComponentDescriptor {
        AudioUnitComponentDescriptor(
            identity: identity,
            kind: .effect,
            name: "PR82 Mock",
            manufacturerName: "Notch Labs",
            typeName: "Effect",
            version: 0x00010000,
            versionString: "1.0.0",
            hasCustomView: false,
            hasMIDIInput: false,
            hasMIDIOutput: false,
            passesAUVal: true,
            sandboxSafe: true,
            supportedSymmetricChannelCounts: [2]
        )
    }

    private func makeGainRuntime(
        gain: Float,
        latency: Int,
        format: AudioUnitRackProcessingFormat
    ) throws -> AudioUnitLiveRackRuntime {
        let stage = PR82GainStage(
            gain: gain,
            latencyFrames: latency
        )
        return try AudioUnitLiveRackRuntime(
            format: format,
            totalLatencyFrames: latency,
            stages: [stage],
            componentsBySlot: [nil]
        )
    }
}

private final class PR82GainStage: AudioUnitLiveRackStageProcessing {
    let slotIndex = 0
    let component: AudioUnitComponentIdentity? = nil
    let latencyFrames: Int
    let gain: Float

    init(gain: Float, latencyFrames: Int) {
        self.gain = gain
        self.latencyFrames = latencyFrames
    }

    func process(
        inputInterleaved: UnsafePointer<Float>,
        outputInterleaved: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sampleTime: Double
    ) -> AudioUnitLiveRackStageResult {
        _ = sampleTime
        let count = frameCount * channelCount
        for index in 0..<count {
            outputInterleaved[index] =
                inputInterleaved[index] * gain
        }
        return .success
    }
}

private struct PR82MockCatalog: AudioUnitComponentCataloging {
    let components: [AudioUnitComponentDescriptor]

    func discoverEffects() -> [AudioUnitComponentDescriptor] {
        components
    }
}

private enum PR82MockPreparationError: Error {
    case unexpectedCall
    case deliberateFailure
}

private struct PR82UnexpectedPreparationBackend:
    AudioUnitOfflinePreparing {
    func prepare(
        component: AudioUnitComponentDescriptor,
        format: AudioUnitRackProcessingFormat,
        restoringState: Data?
    ) async throws -> AudioUnitOfflinePreparationReport {
        throw PR82MockPreparationError.unexpectedCall
    }
}

private struct PR82ThrowingPreparationBackend:
    AudioUnitOfflinePreparing {
    func prepare(
        component: AudioUnitComponentDescriptor,
        format: AudioUnitRackProcessingFormat,
        restoringState: Data?
    ) async throws -> AudioUnitOfflinePreparationReport {
        throw PR82MockPreparationError.deliberateFailure
    }
}
