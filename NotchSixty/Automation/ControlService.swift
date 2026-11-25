import Combine
import Foundation

// E16 S1 (behind `e16.automation`): the single command path. It calls the same entry points as the UI (through
// `ControlHost`), so Safe Launch, disarm on output change, `outputChangeRequiresIdle` and E15 follow apply once and
// unchanged. The host protocol deliberately has no arm method and no output-selection method: nothing here can reach
// `LiveTreatmentArm.arm` or choose an output (selected output stays authoritative, AGENTS.md section 3).
// Every command goes through the same profile and engine paths as a manual change, so the E15 scheduler sees it as one.

struct ControlSystemInfo: Equatable, Sendable {
    var id: UUID
    var name: String
    /// The output this system is bound to, if any.
    var outputUID: String?
}

struct ControlPresetInfo: Equatable, Sendable {
    var id: UUID
    var name: String
}

@MainActor
protocol ControlHost: AnyObject {
    var safeLaunchActive: Bool { get }
    var lifecycleState: AudioLifecycleState { get }
    var isFollowingOutput: Bool { get }
    var selectedOutputUID: String? { get }
    func outputName(forUID uid: String) -> String?
    var systems: [ControlSystemInfo] { get }
    var presets: [ControlPresetInfo] { get }
    var selectedSystemID: UUID? { get }
    var selectedPresetID: UUID? { get }
    var volumeLevel: Double { get }
    var isMuted: Bool { get }
    var volumeControlMode: String { get }
    var isBypassed: Bool { get }
    var isRoomCorrectionEnabled: Bool { get }
    var quietZoneStatus: String { get }
    var roomTreatmentStatus: String { get }

    func startProcessing() async throws
    func stopProcessing()
    func setVolume(_ level: Double) throws
    func setMuted(_ muted: Bool) throws
    func setBypassed(_ bypassed: Bool) throws
    func setRoomCorrection(_ enabled: Bool) throws
    func selectPreset(_ id: UUID) async throws
    /// Returns nil on success or the plain reason it was refused.
    func selectSystem(_ id: UUID) -> String?
}

/// A clock the snapshot coalescer reads, so tests control time.
protocol ControlClock {
    var now: Date { get }
}

struct SystemControlClock: ControlClock {
    var now: Date { Date() }
}

@MainActor
final class ControlService {
    private let host: ControlHost
    private let isEnabled: @MainActor () -> Bool

    init(host: ControlHost, isEnabled: @escaping @MainActor () -> Bool) {
        self.host = host
        self.isEnabled = isEnabled
    }

    var isAutomationEnabled: Bool { isEnabled() }
    var systems: [ControlSystemInfo] { host.systems }
    var presets: [ControlPresetInfo] { host.presets }

    var snapshot: ControlStateSnapshot {
        let outputUID = host.selectedOutputUID
        return ControlStateSnapshot(
            processing: Self.isProcessing(host.lifecycleState),
            bypassed: host.isBypassed,
            roomCorrection: host.isRoomCorrectionEnabled,
            volumeLevel: host.volumeLevel,
            muted: host.isMuted,
            controlMode: host.volumeControlMode,
            outputName: outputUID.flatMap { host.outputName(forUID: $0) },
            outputUID: outputUID,
            system: host.selectedSystemID.flatMap { id in
                host.systems.first { $0.id == id }.map { .init(id: $0.id, name: $0.name) }
            },
            preset: host.selectedPresetID.flatMap { id in
                host.presets.first { $0.id == id }.map { .init(id: $0.id, name: $0.name) }
            },
            quietZoneStatus: host.quietZoneStatus,
            roomTreatmentStatus: host.roomTreatmentStatus)
    }

    static func isProcessing(_ state: AudioLifecycleState) -> Bool {
        switch state {
        case .starting, .running, .reconfiguring, .recoveringOutput: return true
        default: return false
        }
    }

    func perform(_ command: ControlCommand) async -> ControlResult {
        guard isEnabled() else { return .refused(ControlRefusal.notAvailable) }
        if command == .readStatus { return .status(snapshot) }

        // Turning processing off is always allowed (the safe direction); everything else waits for Safe Launch.
        if command != .setProcessing(false), host.safeLaunchActive {
            return .refused(ControlRefusal.safeLaunch)
        }
        do {
            switch command {
            case .readStatus:
                return .status(snapshot)
            case .setProcessing(let on):
                if on {
                    if host.lifecycleState == .failed { host.stopProcessing() }
                    guard host.lifecycleState == .idle else {
                        return Self.isProcessing(host.lifecycleState) ? .done : .refused(ControlRefusal.busy)
                    }
                    try await host.startProcessing()
                } else {
                    host.stopProcessing()
                }
            case .setVolume(let level):
                guard Self.validLevel(level) else { return .refused(ControlRefusal.invalidLevel) }
                try host.setVolume(level)
            case .stepVolume(let delta):
                guard delta.isFinite else { return .refused(ControlRefusal.invalidLevel) }
                let range = MasterVolumeConfiguration.levelRange
                try host.setVolume(min(max(host.volumeLevel + delta, range.lowerBound), range.upperBound))
            case .setMuted(let muted):
                try host.setMuted(muted)
            case .toggleMute:
                try host.setMuted(!host.isMuted)
            case .setBypass(let bypassed):
                try host.setBypassed(bypassed)
            case .setRoomCorrection(let enabled):
                try host.setRoomCorrection(enabled)
            case .selectPreset(let id):
                if let refusal = graphChangeRefusal() { return .refused(refusal) }
                guard host.presets.contains(where: { $0.id == id }) else { return .refused(ControlRefusal.unknownPreset) }
                try await host.selectPreset(id)
            case .selectSystem(let id):
                if let refusal = graphChangeRefusal() { return .refused(refusal) }
                guard let system = host.systems.first(where: { $0.id == id }) else {
                    return .refused(ControlRefusal.unknownSystem)
                }
                // Selected output stays authoritative: a system bound to another output is refused here, never
                // applied by moving the output. Following (E15) applies it to the current device without rebinding.
                if !host.isFollowingOutput, let bound = system.outputUID, bound != host.selectedOutputUID {
                    return .refused(ControlRefusal.otherOutput(host.outputName(forUID: bound) ?? "another output"))
                }
                if let reason = host.selectSystem(id) { return .refused(reason) }
            }
            return .done
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    private func graphChangeRefusal() -> String? {
        switch host.lifecycleState {
        case .failed: return ControlRefusal.engineFailed
        case .idle, .running: return nil
        default: return ControlRefusal.busy
        }
    }

    private static func validLevel(_ level: Double) -> Bool {
        level.isFinite && MasterVolumeConfiguration.levelRange.contains(level)
    }
}

/// Publishes the snapshot on change, at most `maxPerSecond` times a second (design note 2). A change inside the window
/// is held and sent by `flush()` once the window ends, so the last state always arrives.
@MainActor
final class ControlSnapshotPublisher {
    private let service: ControlService
    private let clock: ControlClock
    private let minimumInterval: TimeInterval
    private var lastSent: Date?
    private var lastValue: ControlStateSnapshot?
    private(set) var hasPending = false
    private let subject = PassthroughSubject<ControlStateSnapshot, Never>()

    var publisher: AnyPublisher<ControlStateSnapshot, Never> { subject.eraseToAnyPublisher() }

    init(service: ControlService, clock: ControlClock = SystemControlClock(), maxPerSecond: Double = 10) {
        self.service = service
        self.clock = clock
        self.minimumInterval = 1 / maxPerSecond
    }

    /// Call when any observed control state may have changed. Returns true when a snapshot was published now.
    @discardableResult
    func stateMayHaveChanged() -> Bool {
        let value = service.snapshot
        guard value != lastValue else { hasPending = false; return false }
        let now = clock.now
        if let lastSent, now.timeIntervalSince(lastSent) < minimumInterval {
            hasPending = true
            return false
        }
        send(value, at: now)
        return true
    }

    /// Releases a held change once its window has passed.
    @discardableResult
    func flush() -> Bool {
        guard hasPending else { return false }
        let now = clock.now
        if let lastSent, now.timeIntervalSince(lastSent) < minimumInterval { return false }
        let value = service.snapshot
        hasPending = false
        guard value != lastValue else { return false }
        send(value, at: now)
        return true
    }

    private func send(_ value: ControlStateSnapshot, at now: Date) {
        lastSent = now
        lastValue = value
        hasPending = false
        subject.send(value)
    }
}
