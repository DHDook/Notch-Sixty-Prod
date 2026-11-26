import Foundation

/// E23 S4 part 4 (G20): the output-recovery and low-latency-profile state of `AudioIOEngine`, in a box so the
/// recovery extension can change it while no other file can write a field. Fields are `private(set)`; they change
/// only through the intent-named methods, which keep the generation and the retry counters consistent.
///
/// Main actor only. Never touched from an audio callback.
@MainActor
@Observable
final class OutputRecoveryState {
    @ObservationIgnored private(set) var reconfigurationWorkItem: DispatchWorkItem?
    @ObservationIgnored private(set) var recoveryWorkItem: DispatchWorkItem?
    /// Bumped whenever a pending recovery must be discarded; a scheduled attempt carries the value it was made under.
    @ObservationIgnored private(set) var recoveryGeneration: UInt64 = 0
    @ObservationIgnored private(set) var recoveryConsecutiveBuildFailures = 0
    @ObservationIgnored private(set) var resumeAfterWake = false
    /// Restore deferred to the rebuild, so the physical output never changes size under a live tap aggregate.
    @ObservationIgnored private(set) var lowLatencyRestorePending = false
    /// E4 S7: the low-latency output profile Quiet Zone requests.
    private(set) var lowLatencyOutputProfileActive = false
    /// The buffer size the profile set on the current output (nil when off or not applied).
    private(set) var lowLatencyOutputBufferFrames: UInt32?
    private(set) var recoveryAttempts: UInt64 = 0
    private(set) var recoverySuccesses: UInt64 = 0
    private(set) var recoveryFailures: UInt64 = 0
    private(set) var sampleRateChangesHandled: UInt64 = 0

    /// Discards every pending reconfiguration and recovery (Stop, quit). Later attempts see a stale generation.
    func cancelAllPending() {
        recoveryGeneration &+= 1
        reconfigurationWorkItem?.cancel()
        recoveryWorkItem?.cancel()
        reconfigurationWorkItem = nil
        recoveryWorkItem = nil
    }

    /// Starts a recovery pass and returns the generation its attempts must carry.
    func beginRecoveryGeneration() -> UInt64 {
        recoveryGeneration &+= 1
        recoveryConsecutiveBuildFailures = 0
        return recoveryGeneration
    }

    func cancelReconfiguration() { reconfigurationWorkItem?.cancel() }
    func scheduleReconfiguration(_ item: DispatchWorkItem) { reconfigurationWorkItem = item }
    func finishReconfiguration() { reconfigurationWorkItem = nil }

    func scheduleRecovery(_ item: DispatchWorkItem) {
        recoveryWorkItem?.cancel()
        recoveryWorkItem = item
    }
    func finishRecovery() { recoveryWorkItem = nil }

    func recordRecoveryAttempt() { recoveryAttempts &+= 1 }
    func recordRecoverySuccess() {
        recoverySuccesses &+= 1
        recoveryConsecutiveBuildFailures = 0
    }
    /// Returns the consecutive failure count after this one.
    func recordRecoveryBuildFailure() -> Int {
        recoveryFailures &+= 1
        recoveryConsecutiveBuildFailures += 1
        return recoveryConsecutiveBuildFailures
    }
    func recordSampleRateChange() { sampleRateChangesHandled &+= 1 }

    func setResumeAfterWake(_ value: Bool) { resumeAfterWake = value }
    func setLowLatencyRestorePending(_ value: Bool) { lowLatencyRestorePending = value }
    func setLowLatencyOutputProfileActive(_ value: Bool) { lowLatencyOutputProfileActive = value }
    func setLowLatencyOutputBufferFrames(_ value: UInt32?) { lowLatencyOutputBufferFrames = value }
}

extension AudioIOEngine {
    /// Read-forwarders so callers and the UI keep the old names.
    var recoveryGeneration: UInt64 { recovery.recoveryGeneration }
    var recoveryConsecutiveBuildFailures: Int { recovery.recoveryConsecutiveBuildFailures }
    var resumeAfterWake: Bool { recovery.resumeAfterWake }
    var lowLatencyRestorePending: Bool { recovery.lowLatencyRestorePending }
    var lowLatencyOutputProfileActive: Bool { recovery.lowLatencyOutputProfileActive }
    var lowLatencyOutputBufferFrames: UInt32? { recovery.lowLatencyOutputBufferFrames }
    var recoveryAttempts: UInt64 { recovery.recoveryAttempts }
    var recoverySuccesses: UInt64 { recovery.recoverySuccesses }
    var recoveryFailures: UInt64 { recovery.recoveryFailures }
    var sampleRateChangesHandled: UInt64 { recovery.sampleRateChangesHandled }
}
