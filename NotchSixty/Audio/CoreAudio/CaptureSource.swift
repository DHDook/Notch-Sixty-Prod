import CoreAudio
import Foundation

// E36 S1: the input-source seam. Control-plane only: nothing here runs on an audio callback, and the IOProcs, the
// realtime bridge and the output path are untouched.

/// The slice of the Core Audio object API the capture sources need. The production implementation calls Core Audio; tests
/// pass a fake that records the requests (E36 design note 2). S2 and S3 add the property reads and writes the driver
/// protocol needs.
protocol HALPropertyStore: AnyObject {
    func createProcessTap(_ description: CATapDescription) -> (status: OSStatus, tapID: AudioObjectID)
    func destroyProcessTap(_ tapID: AudioObjectID)
    func createAggregateDevice(_ description: [String: Any]) -> (status: OSStatus, deviceID: AudioDeviceID)
    func destroyAggregateDevice(_ deviceID: AudioDeviceID)
}

final class SystemHALPropertyStore: HALPropertyStore {
    func createProcessTap(_ description: CATapDescription) -> (status: OSStatus, tapID: AudioObjectID) {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        return (status, tapID)
    }

    func destroyProcessTap(_ tapID: AudioObjectID) {
        AudioHardwareDestroyProcessTap(tapID)
    }

    func createAggregateDevice(_ description: [String: Any]) -> (status: OSStatus, deviceID: AudioDeviceID) {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        return (status, deviceID)
    }

    func destroyAggregateDevice(_ deviceID: AudioDeviceID) {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }
}

/// Where a transport session gets its captured programme: today the process tap and its private aggregate; with
/// E36 S3, the virtual device. The session owns the IOProcs; the source owns the Core Audio objects it created.
protocol CaptureSource: AnyObject {
    /// The device whose input the capture IOProc reads. `kAudioObjectUnknown` before the source is open.
    var captureDeviceID: AudioDeviceID { get }
    /// Destroys everything the source created, in reverse creation order. Safe to call twice.
    func close()
}

/// A process tap description, as the three sessions built it before the seam.
struct ProcessTapSpec: Equatable {
    var excludedProcess: AudioObjectID
    /// The output device the tap is scoped to (the selected output, or the programme source).
    var deviceUID: String
    var name: String
    /// True keeps every source channel (no mixdown, not mono).
    var keepsAllChannels: Bool

    func makeDescription() -> CATapDescription {
        let description = CATapDescription(excludingProcesses: [excludedProcess], deviceUID: deviceUID, stream: 0)
        description.name = name
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        if keepsAllChannels {
            description.isMixdown = false
            description.isMono = false
        }
        return description
    }
}

/// The private aggregate device that carries a tap, as the three sessions built it before the seam.
struct TapAggregateSpec: Equatable {
    struct SubDevice: Equatable {
        var uid: String
        var driftCompensation: Bool
    }

    var name: String
    var uidPrefix: String
    var tapUID: String
    var tapDriftCompensation: Bool
    /// Empty: the aggregate has no sub-device list (the tap's own device is the clock).
    var subDevices: [SubDevice] = []
    var mainSubDeviceUID: String?

    func dictionary(uidSuffix: String = UUID().uuidString) -> [String: Any] {
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: tapDriftCompensation,
        ]
        var result: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "\(uidPrefix).\(uidSuffix)",
            kAudioAggregateDeviceTapListKey: [tapEntry],
            // The session owns capture lifecycle explicitly through its IOProc; the aggregate must not run the tap itself.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true,
        ]
        if !subDevices.isEmpty {
            result[kAudioAggregateDeviceSubDeviceListKey] = subDevices.map { sub -> [String: Any] in
                [kAudioSubDeviceUIDKey: sub.uid, kAudioSubDeviceDriftCompensationKey: sub.driftCompensation]
            }
        }
        if let mainSubDeviceUID {
            result[kAudioAggregateDeviceMainSubDeviceKey] = mainSubDeviceUID
        }
        return result
    }
}

/// Today's capture path, moved out of the three transport sessions without a behaviour change: a private process tap and
/// a private aggregate device that carries it. Creation is two steps because the sessions read the tap's format between
/// them.
final class ProcessTapCaptureSource: CaptureSource {
    private let store: any HALPropertyStore
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)

    var captureDeviceID: AudioDeviceID { aggregateDeviceID }

    init(store: any HALPropertyStore = SystemHALPropertyStore()) {
        self.store = store
    }

    /// Creates the tap; the status is the Core Audio result for the session's own `check`.
    func createTap(_ description: CATapDescription) -> OSStatus {
        let result = store.createProcessTap(description)
        tapID = result.tapID
        return result.status
    }

    func createAggregate(_ spec: TapAggregateSpec) -> OSStatus {
        let result = store.createAggregateDevice(spec.dictionary())
        aggregateDeviceID = result.deviceID
        return result.status
    }

    func close() {
        if aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) {
            store.destroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            store.destroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
