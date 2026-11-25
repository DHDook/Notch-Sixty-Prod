import CoreAudio
import Foundation

// E23 S4 part 2: output-device recovery, low-latency profile, sample-rate reconfiguration and
// sleep/wake handling, moved verbatim from AudioIOEngine.swift (no behaviour change).
extension AudioIOEngine {
    /// E4 S7: switches the lowest-latency output buffer on or off. The buffer
    /// size is read when a transport is built, so a running transport is
    /// rebuilt through the reconfigure path (one short dropout). Off restores
    /// the size each device had before.
    func setLowLatencyOutputProfile(_ enabled: Bool) {
        guard enabled != lowLatencyOutputProfileActive else { return }
        lowLatencyOutputProfileActive = enabled
        if enabled {
            lowLatencyRestorePending = false
            lowLatencyBufferProfile.activate()
        } else {
            lowLatencyOutputBufferFrames = nil
            if lifecycle.state == .running {
                lowLatencyRestorePending = true
            } else {
                restoreLowLatencyBuffers()
            }
        }
        scheduleSampleRateReconfiguration(
            countsAsSampleRateChange: false,
            cause: .plannedProfileChange
        )
    }

    /// Puts back the buffer sizes the profile replaced. Only while no
    /// transport is open.
    func restoreLowLatencyBuffers() {
        lowLatencyRestorePending = false
        let devices = outputDevices
        let result = lowLatencyBufferProfile.deactivate { uid in
            devices.first { $0.uid == uid }?.deviceID
        }
        if let failure = result.failures.first {
            lastErrorDescription = failure.localizedDescription
        }
    }

    func applyLowLatencyOutputProfile(to output: AudioOutputDevice) {
        guard lowLatencyOutputProfileActive else { return }
        do {
            lowLatencyOutputBufferFrames = try lowLatencyBufferProfile.apply(
                to: output.deviceID,
                uid: output.uid,
                sampleRate: output.nominalSampleRate
            )
        } catch {
            // Best effort: the transport opens at the device's current size.
            lowLatencyOutputBufferFrames = nil
            lastErrorDescription = error.localizedDescription
        }
    }

    /// `fadeOut` ramps the live session to silence before teardown (about 20 ms, bridge-owned) so a
    /// user-initiated session rebuild never steps the output; device-driven rebuilds cannot fade
    /// because the device is already changing. `settleDelay` is the wait before the rebuild.
    func scheduleSampleRateReconfiguration(
        countsAsSampleRateChange: Bool = true,
        fadeOut: Bool = false,
        settleDelay: TimeInterval = 0.15,
        cause: TransportTeardownCause = .reconfiguration
    ) {
        guard lifecycle.state == .running else { return }

        reconfigurationWorkItem?.cancel()
        do {
            try setLifecycle(.reconfiguring)
            eventMonitor.removeSelectedOutputSampleRateMonitor()
            tearDownTransport(fadeOut: fadeOut, cause: cause)
        } catch {
            tearDownTransport(fadeOut: false)
            forceFailedState(error)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.performSampleRateReconfiguration(countsAsSampleRateChange: countsAsSampleRateChange)
        }
        reconfigurationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: workItem)
    }

    func performSampleRateReconfiguration(countsAsSampleRateChange: Bool) {
        guard lifecycle.state == .reconfiguring else { return }
        do {
            try refreshOutputDevices()
            guard let output = selectedOutputDevice else {
                beginOutputRecovery()
                return
            }
            detachAudioUnitRackIfIncompatible(with: output)
            if lowLatencyRestorePending { restoreLowLatencyBuffers() }
            try buildTransport(output: output)
            try eventMonitor.monitorSampleRate(of: output.deviceID)
            try syncMasterVolumeMonitorToSelectedOutput()
            if countsAsSampleRateChange { sampleRateChangesHandled &+= 1 }
            reconfigurationWorkItem = nil
            try setLifecycle(.running)
            lastErrorDescription = nil
            requestAudioUnitRackRebuildIfPending()
        } catch {
            tearDownTransport(fadeOut: false)
            forceFailedState(error)
        }
    }

    func beginOutputRecovery() {
        guard lifecycle.state == .running || lifecycle.state == .reconfiguring else { return }
        recoveryGeneration &+= 1
        recoveryConsecutiveBuildFailures = 0
        let generation = recoveryGeneration
        try? setLifecycle(.recoveringOutput)
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        tearDownTransport(fadeOut: false, cause: .outputLost)
        scheduleRecoveryAttempt(
            generation: generation,
            delay: OutputRecoveryRetryPolicy.absentOutputPollInterval
        )
    }

    func scheduleRecoveryAttempt(generation: UInt64, delay: TimeInterval) {
        guard generation == recoveryGeneration, lifecycle.state == .recoveringOutput else { return }
        recoveryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.performRecoveryAttempt(generation: generation) }
        recoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func performRecoveryAttempt(generation: UInt64) {
        guard generation == recoveryGeneration, lifecycle.state == .recoveringOutput else { return }
        recoveryAttempts &+= 1

        do {
            try refreshOutputDevices()
            guard let output = selectedOutputDevice else {
                lastErrorDescription = "Waiting for selected output to return."
                scheduleRecoveryAttempt(
                    generation: generation,
                    delay: OutputRecoveryRetryPolicy.absentOutputPollInterval
                )
                return
            }

            if case .waitForSource(let uid) = programFoldBuildDecision(for: output) {
                // The wider source is absent: wait for the same UID, never tap the DAC or another 6-channel device.
                // Not a build failure, so it never counts toward the retry limit.
                lastErrorDescription = ProgramFoldDownError.sourceUnavailable(uid: uid).errorDescription
                scheduleRecoveryAttempt(
                    generation: generation,
                    delay: OutputRecoveryRetryPolicy.absentOutputPollInterval
                )
                return
            }
            do {
                detachAudioUnitRackIfIncompatible(with: output)
                try buildTransport(output: output)
                try eventMonitor.monitorSampleRate(of: output.deviceID)
                try syncMasterVolumeMonitorToSelectedOutput()
                recoverySuccesses &+= 1
                recoveryConsecutiveBuildFailures = 0
                try setLifecycle(.running)
                lastErrorDescription = nil
                recoveryWorkItem = nil
                requestAudioUnitRackRebuildIfPending()
                return
            } catch {
                recoveryFailures &+= 1
                recoveryConsecutiveBuildFailures += 1
                tearDownTransport(fadeOut: false)
                if OutputRecoveryRetryPolicy.shouldFail(
                    afterConsecutiveFailures: recoveryConsecutiveBuildFailures
                ) {
                    recoveryWorkItem = nil
                    forceFailedState(error)
                    return
                }
                lastErrorDescription = "Selected output is present but not ready yet: \(error.localizedDescription)"
                scheduleRecoveryAttempt(
                    generation: generation,
                    delay: OutputRecoveryRetryPolicy.buildRetryDelay(
                        afterConsecutiveFailures: recoveryConsecutiveBuildFailures
                    )
                )
                return
            }
        } catch {
            lastErrorDescription = error.localizedDescription
        }

        scheduleRecoveryAttempt(
            generation: generation,
            delay: OutputRecoveryRetryPolicy.absentOutputPollInterval
        )
    }

    func handleWillSleep() {
        guard lifecycle.state == .running else {
            resumeAfterWake = false
            return
        }
        resumeAfterWake = true
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        masterVolumeController.stopMonitoring()
        try? setLifecycle(.stopping)
        tearDownTransport(fadeOut: true, cause: .sleep)
        try? setLifecycle(.idle)
    }

    func handleDidWake() {
        guard resumeAfterWake else { return }
        resumeAfterWake = false
        guard lifecycle.state == .idle else { return }
        // USB and Thunderbolt outputs often re-enumerate after didWake. Wait for
        // the same output UID through the recovery loop instead of making one
        // start attempt that leaves processing stopped if the device is late.
        recoveryGeneration &+= 1
        recoveryConsecutiveBuildFailures = 0
        do {
            try setLifecycle(.recoveringOutput)
        } catch {
            lastErrorDescription = error.localizedDescription
            return
        }
        scheduleRecoveryAttempt(generation: recoveryGeneration, delay: 0)
    }
}
