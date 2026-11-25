import Foundation

// E15 S2: the engine entry for Follow macOS output (design note 5, steps b, c and e). Control plane only: the stop
// fades out and tears the transport down exactly as Stop does (cause `.followOutput`), the new output is selected, and
// `start()` rebuilds every graph at the new device's nominal rate off the realtime thread. Lifecycle moves only through
// the existing state machine. Nothing here runs in a render callback.

extension AudioIOEngine {
    /// Plain Stop; the teardown cause is `.stop`. The engine's `stop(cause:)` takes the cause explicitly.
    func stop() { stop(cause: .stop) }

    /// Moves processing to the output with `uid`.
    ///
    /// - Parameter resume: false leaves the engine stopped on the new output ("paused", design note 6), so macOS plays it
    ///   unprocessed while the UI still shows the truthful selection.
    /// If the engine was idle the selection simply updates and nothing starts. A failed start surfaces through the
    /// normal lifecycle (`failed`) and is rethrown.
    /// - Parameter prepare: runs on the control plane after the new output is selected and before `start()` (the S3
    ///   coordinator applies the bound Playback System here, design note 5 step d). A throw leaves the engine stopped
    ///   on the new output and is rethrown.
    func switchFollowedOutput(to uid: String, resume: Bool = true) throws {
        try switchFollowedOutput(to: uid, resume: resume, prepare: {})
    }

    func switchFollowedOutput(to uid: String, resume: Bool, prepare: () throws -> Void) throws {
        let wasActive = lifecycleState != .idle
        if wasActive { stop(cause: .followOutput) }
        try refreshOutputDevices()
        try selectOutput(uid: uid)
        try prepare()
        if wasActive && resume { try start() }
    }
}
