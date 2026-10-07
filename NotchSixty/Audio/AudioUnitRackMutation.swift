import Foundation

enum AudioUnitRackMutation: Equatable, Sendable {
    case install(
        component: AudioUnitComponentIdentity,
        slot: Int,
        initiallyBypassed: Bool
    )
    case remove(slot: Int)
    case move(from: Int, to: Int)
    case setBypassed(slot: Int, bypassed: Bool)
    case setWetDryMix(slot: Int, mix: Double)
    case setOpaqueFullState(slot: Int, state: Data?)
}

struct AudioUnitRackMutationCandidate {
    let configuration: AudioUnitRackConfiguration
    let format: AudioUnitRackProcessingFormat
    let plan: AudioUnitRackExecutionPlan
    let reportsBySlotID: [
        UUID: AudioUnitOfflinePreparationReport
    ]
    let runtime: AudioUnitLiveRackRuntime?

    var totalLatencyFrames: Int {
        plan.totalLatencyFrames
    }

    var requiresControlledRestart: Bool {
        false
    }
}

enum AudioUnitRackMutationError: Error, Equatable, LocalizedError {
    case slotIndexOutOfRange(Int)
    case destinationSlotIndexOutOfRange(Int)
    case componentNotDiscovered(AudioUnitComponentIdentity)
    case candidatePreparationFailed(slot: Int, reason: String)
    case liveMutationRequiresRunningOrIdle(AudioLifecycleState)
    case liveTransitionUnavailable
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .slotIndexOutOfRange(let slot):
            return "Audio Unit rack mutation slot \(slot + 1) is out of range."
        case .destinationSlotIndexOutOfRange(let slot):
            return "Audio Unit rack destination slot \(slot + 1) is out of range."
        case .componentNotDiscovered(let component):
            return "Audio Unit \(component.fourCCSummary) is not in the current component catalog."
        case .candidatePreparationFailed(let slot, let reason):
            return "Audio Unit rack candidate slot \(slot + 1) failed offline preparation. \(reason)"
        case .liveMutationRequiresRunningOrIdle(let state):
            return "Audio Unit rack mutation is unavailable while audio is \(state.rawValue)."
        case .liveTransitionUnavailable:
            return "The active transport does not expose a live Audio Unit rack transition surface."
        case .rollbackFailed(let reason):
            return "Audio Unit rack mutation failed and the previous transport could not be fully restored. \(reason)"
        }
    }
}

enum AudioUnitRackMutationActivation: Equatable, Sendable {
    case stagedForNextStart
    case seamlessCrossfade(generation: UInt64)
    case controlledRestart
}
