import Foundation

// E23 S4 part 4: the master-volume and keyboard-volume region, moved out of `AudioIOEngine.swift`. The state it changes
// lives in `MasterVolumeState`.
extension AudioIOEngine {
    var currentMasterSoftwareGain: Float {
        masterVolumeConfiguration.softwareGain(for: masterVolumeCapabilities)
    }

    func applyMasterVolumeConfiguration(
        _ configuration: MasterVolumeConfiguration,
        writeDevice: Bool
    ) throws {
        guard configuration.level.isFinite,
              MasterVolumeConfiguration.levelRange.contains(configuration.level) else {
            throw MasterVolumeConfigurationError.invalidLevel(configuration.level)
        }

        if writeDevice, let output = selectedOutputDevice {
            if masterVolumeCapabilities.controlMode == .device {
                try masterVolumeController.setVolume(configuration.level, deviceID: output.deviceID)
            }
            if masterVolumeCapabilities.usesDeviceMute {
                try masterVolumeController.setMuted(configuration.muted, deviceID: output.deviceID)
            }
        }

        let oldSoftwareGain = currentMasterSoftwareGain
        let newSoftwareGain = configuration.softwareGain(for: masterVolumeCapabilities)
        if let session = transportSession, abs(oldSoftwareGain - newSoftwareGain) > 0.000_001 {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: newSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(to: &graph, stereoConfiguration: renderStereoEQConfiguration, playbackConfiguration: playbackControlConfiguration)
            try attachActiveRoomCorrectionProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)
            try attachActiveSpeakerIRProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)
            try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
        }
        if let session = nChannelTransportSession, abs(oldSoftwareGain - newSoftwareGain) > 0.000_001 {
            session.setOutputGain(newSoftwareGain)
        }
        if let session = binauralHeadphoneTransportSession, abs(oldSoftwareGain - newSoftwareGain) > 0.000_001 {
            session.setOutputGain(newSoftwareGain)
        }

        masterVolume.setConfiguration(configuration)
        persistSoftwareMasterVolumeIfNeeded()
        setLastError(nil)
    }

    func persistSoftwareMasterVolumeIfNeeded() {
        guard masterVolumeCapabilities.controlMode == .softwareDSP,
              let uid = selectedOutputDevice?.uid,
              uid == masterVolumeSynchronizedOutputUID else { return }
        masterVolumeStore?.storeSoftwareVolume(masterVolumeConfiguration, forOutputUID: uid)
    }

    func syncMasterVolumeMonitorToSelectedOutput() throws {
        guard let output = selectedOutputDevice else {
            masterVolumeController.stopMonitoring()
            masterVolume.setCapabilities(.softwareOnly)
            onVolumeKeyRouteChange?(false)
            return
        }
        try masterVolumeController.monitor(deviceID: output.deviceID)
        try synchronizeMasterVolumeFromSelectedDevice()
        onVolumeKeyRouteChange?(masterVolumeCapabilities.controlMode == .softwareDSP)
    }

    func synchronizeMasterVolumeFromSelectedDevice() throws {
        guard let output = selectedOutputDevice else { return }
        let previousCapabilities = masterVolumeCapabilities
        let snapshot = try masterVolumeController.inspect(deviceID: output.deviceID)
        masterVolume.setCapabilities(snapshot.capabilities)

        var updated = masterVolumeConfiguration
        let firstSyncForOutput = masterVolumeSynchronizedOutputUID != output.uid
        if snapshot.capabilities.controlMode == .device, let level = snapshot.level {
            updated.level = min(max(level, 0), 1)
        } else if snapshot.capabilities.controlMode == .softwareDSP,
                  firstSyncForOutput,
                  let restored = masterVolumeStore?.restoredSoftwareVolume(forOutputUID: output.uid) {
            updated.level = min(max(restored.level, 0), 1)
            if !snapshot.capabilities.usesDeviceMute {
                updated.muted = restored.muted
            }
        }
        if snapshot.capabilities.usesDeviceMute, let muted = snapshot.muted {
            updated.muted = muted
        }
        masterVolume.setSynchronizedOutputUID(output.uid)

        let oldGain = masterVolumeConfiguration.softwareGain(for: previousCapabilities)
        let newGain = updated.softwareGain(for: snapshot.capabilities)
        if let session = transportSession, abs(oldGain - newGain) > 0.000_001 {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: newGain
            )
            try attachActiveEQFIRProgramIfNeeded(to: &graph, stereoConfiguration: renderStereoEQConfiguration, playbackConfiguration: playbackControlConfiguration)
            try attachActiveRoomCorrectionProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)
            try attachActiveSpeakerIRProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)
            try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
        }
        if let session = nChannelTransportSession, abs(oldGain - newGain) > 0.000_001 {
            session.setOutputGain(newGain)
        }
        if let session = binauralHeadphoneTransportSession, abs(oldGain - newGain) > 0.000_001 {
            session.setOutputGain(newGain)
        }
        masterVolume.setConfiguration(updated)
    }

    func handleMasterVolumeDeviceChange() {
        do {
            try synchronizeMasterVolumeFromSelectedDevice()
            setLastError(nil)
        } catch {
            setLastError(error.localizedDescription)
        }
    }

    /// E16 S2: a media-key level change. Software volume only; never writes the device.
    func applySoftwareVolumeKey(level: Double) {
        guard masterVolumeCapabilities.controlMode == .softwareDSP else { return }
        var updated = masterVolumeConfiguration
        updated.level = level
        do {
            try applyMasterVolumeConfiguration(updated, writeDevice: false)
            setLastError(nil)
        } catch {
            setLastError(error.localizedDescription)
        }
    }
}
