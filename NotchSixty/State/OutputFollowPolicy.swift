import Foundation

/// E15 S1: the pure decision behind Follow macOS output (design notes 4, 6, 9 and 11). No Core Audio, no engine, no
/// state of its own: every case is a table row in `OutputFollowPolicyTests`. The coordinator (S3) feeds it events and
/// acts on the answer; the clock is injected so settle and wake windows are deterministic.

/// A device macOS reports as the default output, or the current device's new data source.
struct OutputFollowTarget: Equatable, Sendable {
    var key: OutputKey
    var displayName: String = ""
}

enum OutputFollowEvent: Equatable, Sendable {
    /// `kAudioHardwarePropertyDefaultOutputDevice` changed; `target` is nil when macOS reports no output.
    case defaultOutputChanged(OutputFollowTarget?, receivedAt: Date)
    /// The current device reported a new data source (speakers to headphone jack).
    case dataSourceChanged(OutputFollowTarget, receivedAt: Date)
}

enum OutputFollowBlock: String, Equatable, Sendable {
    case safeLaunch
    case hardwareAcceptance
    case measurementCapture
    case engineFailed
}

enum OutputFollowPauseReason: Equatable, Sendable {
    /// No Playback System is bound to this output (or the bound one was deleted).
    case noBinding
    /// The bound system references hardware that is not mapped yet, so it is never activated.
    case needsMapping(UUID)
    /// The bound system failed to apply on this device (for example a 5.1 arrangement on a two-channel device); the
    /// previous system's state was rolled back and nothing was started.
    case applyFailed(UUID, message: String)
}

enum OutputFollowDeferral: Equatable, Sendable {
    /// The 500 ms settle window has not elapsed; ask again at `until`.
    case settling(until: Date)
    /// Waiting for the pre-sleep device after wake; ask again at `until`.
    case wakeWindow(until: Date)
    /// An excluded state is active; the pending default is applied when it ends.
    case blocked(OutputFollowBlock)
}

enum FollowAction: Equatable, Sendable {
    case none
    case switchTo(uid: String, key: OutputKey, profileID: UUID)
    case pause(uid: String, key: OutputKey, reason: OutputFollowPauseReason)
    case `defer`(OutputFollowDeferral)
}

struct OutputFollowWake: Equatable, Sendable {
    var preSleepUID: String
    var until: Date
}

struct OutputFollowState: Equatable, Sendable {
    /// Already forced to `.fixed` when the flag is off (`OutputSelectionMode.effective`).
    var mode: OutputSelectionMode = .fixed
    var selectedKey: OutputKey?
    var bindings = OutputProfileBindings()
    var existingProfileIDs: Set<UUID> = []
    var needsMappingProfileIDs: Set<UUID> = []
    /// Notch Sixty's own private tap and aggregate devices: never targets.
    var ownDeviceUIDs: Set<String> = []
    var blocks: Set<OutputFollowBlock> = []
    /// Output device UIDs present right now.
    var availableOutputUIDs: Set<String> = []
    /// Set on wake: the device that was selected before sleep and when to stop waiting for it.
    var wake: OutputFollowWake?
}

struct OutputFollowPolicy: Sendable {
    static let settleWindow: TimeInterval = 0.5
    static let wakeWindow: TimeInterval = 3

    /// Injected so tests control time; production passes `Date.init`.
    var now: @Sendable () -> Date = { Date() }

    func decide(event: OutputFollowEvent, state: OutputFollowState) -> FollowAction {
        guard state.mode == .followSystem else { return .none }

        let target: OutputFollowTarget
        let receivedAt: Date
        switch event {
        case .defaultOutputChanged(let candidate, let at):
            guard let candidate else { return .none }
            target = candidate
            receivedAt = at
        case .dataSourceChanged(let candidate, let at):
            // Only the current device's own data source counts; a stale event for another device does nothing.
            guard candidate.key.deviceUID == state.selectedKey?.deviceUID else { return .none }
            target = candidate
            receivedAt = at
        }

        let uid = target.key.deviceUID
        guard !state.ownDeviceUIDs.contains(uid) else { return .none }

        // Excluded states hold the pending default until they end (note 11), in a fixed order.
        for block in [OutputFollowBlock.safeLaunch, .hardwareAcceptance, .measurementCapture, .engineFailed]
        where state.blocks.contains(block) {
            return .defer(.blocked(block))
        }

        let settleEnd = receivedAt.addingTimeInterval(Self.settleWindow)
        if now() < settleEnd { return .defer(.settling(until: settleEnd)) }

        guard target.key != state.selectedKey else { return .none }

        if let wake = state.wake, now() < wake.until, uid != wake.preSleepUID,
           !state.availableOutputUIDs.contains(wake.preSleepUID) {
            return .defer(.wakeWindow(until: wake.until))
        }

        guard let profileID = state.bindings.profileID(for: target.key),
              state.existingProfileIDs.contains(profileID) else {
            return .pause(uid: uid, key: target.key, reason: .noBinding)
        }
        if state.needsMappingProfileIDs.contains(profileID) {
            return .pause(uid: uid, key: target.key, reason: .needsMapping(profileID))
        }
        return .switchTo(uid: uid, key: target.key, profileID: profileID)
    }
}
