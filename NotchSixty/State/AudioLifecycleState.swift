import Foundation

enum AudioLifecycleState: String, CaseIterable, Equatable, Sendable {
    case idle
    case requestingPermission
    case creatingTap
    case creatingAggregate
    case openingOutput
    case starting
    case running
    case reconfiguring
    case recoveringOutput
    case stopping
    case failed
}

struct AudioLifecycleTransitionError: Error, Equatable, Sendable, LocalizedError {
    let from: AudioLifecycleState
    let to: AudioLifecycleState

    var errorDescription: String? {
        "Invalid audio lifecycle transition: \(from.rawValue) → \(to.rawValue)"
    }
}

struct AudioLifecycleStateMachine: Equatable, Sendable {
    private(set) var state: AudioLifecycleState

    init(initialState: AudioLifecycleState = .idle) {
        self.state = initialState
    }

    mutating func transition(to nextState: AudioLifecycleState) throws {
        guard Self.canTransition(from: state, to: nextState) else {
            throw AudioLifecycleTransitionError(from: state, to: nextState)
        }
        state = nextState
    }

    static func canTransition(
        from currentState: AudioLifecycleState,
        to nextState: AudioLifecycleState
    ) -> Bool {
        switch currentState {
        case .idle:
            return nextState == .requestingPermission || nextState == .creatingTap
        case .requestingPermission:
            return nextState == .creatingTap || nextState == .idle || nextState == .failed
        case .creatingTap:
            return nextState == .creatingAggregate || nextState == .stopping || nextState == .failed
        case .creatingAggregate:
            return nextState == .openingOutput || nextState == .stopping || nextState == .failed
        case .openingOutput:
            return nextState == .starting || nextState == .stopping || nextState == .failed
        case .starting:
            return nextState == .running || nextState == .stopping || nextState == .failed
        case .running:
            return nextState == .reconfiguring || nextState == .recoveringOutput || nextState == .stopping || nextState == .failed
        case .reconfiguring:
            return nextState == .running || nextState == .recoveringOutput || nextState == .stopping || nextState == .failed
        case .recoveringOutput:
            return nextState == .running || nextState == .reconfiguring || nextState == .stopping || nextState == .failed
        case .stopping:
            return nextState == .idle || nextState == .failed
        case .failed:
            return nextState == .stopping || nextState == .idle
        }
    }
}
