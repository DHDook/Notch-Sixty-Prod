import Foundation

// E12 S14 (G10): change the output device while audio runs. The remote panel's output picker used to be disabled unless
// the engine was idle. The switch is an explicit user choice, so AGENTS.md section 3 is unchanged: the engine never follows
// a macOS default-output change and never falls back silently. This type only sequences the existing lifecycle: fade out
// and stop, select the new device, start again through the normal start path. A refused or failed switch returns to the
// previous device with a named reason. Control plane only; it adds nothing to the audio callback.

/// What the switch needs from the engine and the product start path. `OutputSwitchEngineTransport` adapts the real ones.
@MainActor
protocol OutputSwitchTransport: AnyObject {
    var isProcessing: Bool { get }
    var selectedOutputUID: String? { get }
    /// UID and display name of every output the engine currently lists. Never reads the macOS default output.
    var availableOutputs: [(uid: String, name: String)] { get }
    /// Fades out and tears down (the engine's normal stop).
    func stopProcessing()
    func selectOutput(uid: String?) throws
    /// The normal start path, including the active-speaker failsafe and the first-start routing check.
    func startProcessing() async throws
}

enum OutputSwitchOutcome: Equatable {
    /// The chosen output was already selected.
    case unchanged
    /// Selected while stopped; nothing was running.
    case selected(name: String)
    /// Stopped, selected and started again on the new device.
    case switched(name: String)
    /// Cleared the output; processing stopped.
    case cleared
    /// The device is not listed. Nothing changed and audio was not interrupted.
    case refused(reason: String)
    /// The new device would not start; the previous device is running again.
    case rolledBack(reason: String)
    /// The new device would not start and the previous device did not start either; processing is stopped.
    case stoppedAfterFailure(reason: String)

    var errorMessage: String? {
        switch self {
        case .unchanged, .selected, .switched, .cleared: return nil
        case let .refused(reason), let .rolledBack(reason), let .stoppedAfterFailure(reason): return reason
        }
    }
}

@MainActor
final class LiveOutputSwitch {
    private let transport: OutputSwitchTransport
    private(set) var isSwitching = false

    init(transport: OutputSwitchTransport) { self.transport = transport }

    func switchOutput(to uid: String?) async -> OutputSwitchOutcome {
        guard !isSwitching else { return .refused(reason: "An output switch is already in progress.") }
        isSwitching = true
        defer { isSwitching = false }

        let previous = transport.selectedOutputUID
        if uid == previous { return .unchanged }
        let outputs = transport.availableOutputs
        func name(_ uid: String?) -> String { outputs.first { $0.uid == uid }?.name ?? "the previous output" }

        guard let uid else {
            if transport.isProcessing { transport.stopProcessing() }
            do { try transport.selectOutput(uid: nil) } catch { return .refused(reason: error.localizedDescription) }
            return .cleared
        }
        guard outputs.contains(where: { $0.uid == uid }) else {
            return .refused(reason: "That output is not available, so the output was not changed.")
        }

        guard transport.isProcessing else {
            do { try transport.selectOutput(uid: uid) } catch { return .refused(reason: error.localizedDescription) }
            return .selected(name: name(uid))
        }

        transport.stopProcessing()
        do {
            try transport.selectOutput(uid: uid)
            try await transport.startProcessing()
            return .switched(name: name(uid))
        } catch {
            let reason = "Could not play on \(name(uid)): \(error.localizedDescription)"
            return await restore(previous, reason: reason)
        }
    }

    private func restore(_ previous: String?, reason: String) async -> OutputSwitchOutcome {
        transport.stopProcessing()
        do {
            try transport.selectOutput(uid: previous)
            guard previous != nil else { return .stoppedAfterFailure(reason: reason) }
            try await transport.startProcessing()
            return .rolledBack(reason: reason + " Back on the previous output.")
        } catch {
            return .stoppedAfterFailure(reason: reason + " The previous output would not start either, so processing is stopped.")
        }
    }
}

/// The real transport: the engine's stop and select, and the product start path.
@MainActor
final class OutputSwitchEngineTransport: OutputSwitchTransport {
    private let engine: AudioIOEngine
    private let start: () async throws -> Void

    init(engine: AudioIOEngine, start: @escaping () async throws -> Void) {
        self.engine = engine
        self.start = start
    }

    var isProcessing: Bool {
        switch engine.lifecycleState {
        case .idle, .stopping: return false
        default: return true
        }
    }
    var selectedOutputUID: String? { engine.routeConfiguration.selectedOutputUID }
    var availableOutputs: [(uid: String, name: String)] { engine.outputDevices.map { ($0.uid, $0.name) } }
    func stopProcessing() { engine.stop() }
    func selectOutput(uid: String?) throws { try engine.selectOutput(uid: uid) }
    func startProcessing() async throws { try await start() }
}

extension MenuBarRemoteModel {
    /// The picker works while processing runs (E12 S14). It is off only during the start-up and tear-down states and
    /// while a switch is already in progress.
    static func outputPickerEnabled(lifecycle: AudioLifecycleState, switching: Bool) -> Bool {
        guard !switching else { return false }
        switch lifecycle {
        case .idle, .running, .recoveringOutput, .failed: return true
        default: return false
        }
    }
}
