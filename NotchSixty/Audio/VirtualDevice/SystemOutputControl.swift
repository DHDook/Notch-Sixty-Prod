import CoreAudio
import Foundation

// E36 S5: control-plane access to the macOS default output, so switching to the virtual driver can take it over and give
// it back. Main thread only; never called from an audio callback. Allocation: Core Audio property calls only. Reset: none.

protocol SystemOutputControlling: AnyObject {
    func defaultOutputUID() -> String?
    /// Makes the device with this UID the macOS default output. False when the device is absent or macOS refuses.
    func setDefaultOutput(uid: String) -> Bool
}

/// The previous default output UID, persisted so the next launch can restore it after a crash.
protocol PreviousOutputStoring: AnyObject {
    var previousOutputUID: String? { get set }
}

final class UserDefaultsPreviousOutputStore: PreviousOutputStoring {
    static let key = "e36.previousOutputUID"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var previousOutputUID: String? {
        get { defaults.string(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

final class CoreAudioSystemOutputController: SystemOutputControlling {
    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func defaultOutputUID() -> String? {
        CoreAudioDefaultOutputDeviceReader().defaultOutputDeviceUID()
    }

    func setDefaultOutput(uid: String) -> Bool {
        guard var deviceID = deviceID(forUID: uid) else { return false }
        var address = Self.defaultOutputAddress
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID) == noErr
    }

    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var qualifier = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &deviceID)
        }
        return status == noErr && deviceID != AudioDeviceID(kAudioObjectUnknown) ? deviceID : nil
    }
}
