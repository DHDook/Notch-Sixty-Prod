import Foundation

/// E4 S25 follow-up: the engine's side of the live reference driver. Everything here is behind
/// `e4.feedforward-live` (`speakerDriveFeatureEnabled`) and never arms the filter.
@MainActor
extension AudioIOEngine: FeedForwardLiveDriverHost {
    var liveDriverAllowed: Bool { speakerDriveFeatureEnabled && ambientPlaybackReferenceAvailable }

    var liveDriverOutputRate: Double? { ambientPlaybackReferenceSampleRate }

    func liveDriverOutputLatencySeconds() -> Double {
        guard let device = selectedOutputDevice, let rate = ambientPlaybackReferenceSampleRate else { return 0 }
        let reading = AudioDeviceLatencyReader.read(deviceID: device.deviceID, input: false, fallbackRate: rate)
        return reading.latencySeconds + reading.bufferSeconds
    }

    func pullPumpAnchors() -> [N60SpeakerDriveAnchor] { pullSpeakerDriveAnchors(for: .pump) }
}

@MainActor
extension AudioIOEngine: FeedForwardLiveReferenceDriving {
    func startLiveReference(device: AudioInputDevice, channel: Int) {
        guard feedForwardLiveDriver.state == .idle else { return }
        let reading = AudioDeviceLatencyReader.read(
            deviceID: device.deviceID, input: true, fallbackRate: ambientPlaybackReferenceSampleRate ?? 48_000)
        feedForwardLiveDriver.start(
            latencies: FeedForwardLiveDriver.Latencies(
                inputBufferingSeconds: reading.bufferSeconds, inputLatencySeconds: reading.latencySeconds)
        ) {
            try FeedForwardReferenceTransport(microphone: device, inputChannelIndex: channel)
        }
    }

    func stopLiveReference() { feedForwardLiveDriver.stop() }
}
