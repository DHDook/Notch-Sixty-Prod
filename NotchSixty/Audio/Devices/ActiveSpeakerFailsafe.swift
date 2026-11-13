import CoreAudio
import Foundation

// E9 S9: active-speaker failsafe.
//
// Finding (software, recorded in docs/epics/E9.md): the app is a driverless process tap. While it runs, the tap
// mutes the originating apps and the app plays the processed result to the selected device. When the app is not
// running, has crashed or was force-quit, the tap and aggregate are gone and macOS plays app audio, unprocessed and
// full range, to the macOS default output. A DAC that feeds drivers directly through an any-way crossover is
// therefore exposed only when it is the macOS default output. Selecting a different default output is the whole
// software mitigation; a capacitor in series with each tweeter covers power loss and other software.

/// Reads the macOS default output device UID. nil when there is none or it cannot be read.
protocol DefaultOutputDeviceReading: Sendable {
    func defaultOutputDeviceUID() -> String?
}

struct CoreAudioDefaultOutputDeviceReader: DefaultOutputDeviceReading {
    func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == 0,
            deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, $0)
        }
        return status == 0 ? uid as String : nil
    }
}

enum ActiveSpeakerFailsafe {
    enum Verdict: Equatable, Sendable {
        case safe
        /// The macOS default output is a device that feeds drivers through the routing crossover.
        case defaultOutputIsCrossoverDevice(uid: String, name: String)

        var isSafe: Bool { self == .safe }
    }

    /// Devices whose outputs feed drivers directly through an any-way crossover: with routing enabled, every device
    /// carrying a way of a speaker that has two or more ways, or a way with a high-pass filter (a tweeter-side band).
    static func crossoverDeviceUIDs(_ configuration: SpeakerRoutingConfiguration) -> Set<String> {
        guard configuration.enabled else { return [] }
        var uids = Set<String>()
        for speaker in configuration.speakers {
            let multiWay = speaker.ways.count >= 2
            for way in speaker.ways where multiWay || way.highPass != nil {
                uids.insert(way.endpoint.deviceUID)
            }
        }
        return uids
    }

    static func verdict(
        _ configuration: SpeakerRoutingConfiguration,
        defaultOutputUID: String?,
        devices: [AudioOutputDevice]
    ) -> Verdict {
        guard let defaultOutputUID, crossoverDeviceUIDs(configuration).contains(defaultOutputUID) else { return .safe }
        let name = devices.first { $0.uid == defaultOutputUID }?.name ?? defaultOutputUID
        return .defaultOutputIsCrossoverDevice(uid: defaultOutputUID, name: name)
    }

    /// The text shown by the setup gate and the launch warning. nil when safe.
    static func message(_ verdict: Verdict, launch: Bool) -> String? {
        guard case .defaultOutputIsCrossoverDevice(_, let name) = verdict else { return nil }
        let base = "\(name) feeds your drivers through an active crossover and is also the macOS default output. "
            + "When Notch Sixty is not running, macOS plays full-range audio straight to it, which can damage a tweeter. "
        if launch {
            return base + "Set another device (for example the built-in speakers or a headset) as the default in "
                + "System Settings > Sound > Output, and fit a protection capacitor in series with each tweeter."
        }
        return base + "Choose a different macOS default output in System Settings > Sound > Output, then set up the crossover."
    }
}
