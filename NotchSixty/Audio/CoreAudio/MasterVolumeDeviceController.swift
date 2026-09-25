import CoreAudio
import Foundation

struct MasterVolumeDeviceSnapshot: Equatable, Sendable {
    var capabilities: MasterVolumeDeviceCapabilities
    var level: Double?
    var muted: Bool?
}

enum MasterVolumeDeviceError: Error, LocalizedError, Equatable {
    case invalidLevel(Double)
    case operationFailed(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidLevel(let level):
            return "Master volume \(level) is outside the supported 0...1 range."
        case .operationFailed(let operation, let status):
            return "Core Audio master-volume operation \(operation) failed with status \(status)."
        }
    }
}

// AudioIOEngine owns this controller on the main actor. HAL listeners are
// explicitly delivered on DispatchQueue.main, so the controller itself does
// not need global-actor isolation (which also keeps its initializer usable as
// a dependency default and its deinit deterministic).
protocol MasterVolumeDeviceControlling: AnyObject {
    var onExternalChange: (() -> Void)? { get set }

    func inspect(deviceID: AudioDeviceID) throws -> MasterVolumeDeviceSnapshot
    func setVolume(_ level: Double, deviceID: AudioDeviceID) throws
    func setMuted(_ muted: Bool, deviceID: AudioDeviceID) throws
    func monitor(deviceID: AudioDeviceID?) throws
    func stopMonitoring()
}

final class CoreAudioMasterVolumeController: MasterVolumeDeviceControlling {
    var onExternalChange: (() -> Void)?

    private var monitoredDeviceID: AudioDeviceID?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?

    func inspect(deviceID: AudioDeviceID) throws -> MasterVolumeDeviceSnapshot {
        let volumeAddress = Self.volumeAddress
        let muteAddress = Self.muteAddress

        let volumeReadable = Self.hasProperty(deviceID: deviceID, address: volumeAddress)
        let volumeWritable: Bool
        if volumeReadable {
            volumeWritable = try Self.isSettable(deviceID: deviceID, address: volumeAddress)
        } else {
            volumeWritable = false
        }

        let muteReadable = Self.hasProperty(deviceID: deviceID, address: muteAddress)
        let muteWritable: Bool
        if muteReadable {
            muteWritable = try Self.isSettable(deviceID: deviceID, address: muteAddress)
        } else {
            muteWritable = false
        }

        let capabilities = MasterVolumeDeviceCapabilities(
            volumeReadable: volumeReadable,
            volumeWritable: volumeWritable,
            muteReadable: muteReadable,
            muteWritable: muteWritable
        )

        let level = volumeReadable ? try Self.readVolume(deviceID: deviceID, address: volumeAddress) : nil
        let muted = muteReadable ? try Self.readMute(deviceID: deviceID, address: muteAddress) : nil
        return MasterVolumeDeviceSnapshot(capabilities: capabilities, level: level, muted: muted)
    }

    func setVolume(_ level: Double, deviceID: AudioDeviceID) throws {
        guard MasterVolumeConfiguration.levelRange.contains(level), level.isFinite else {
            throw MasterVolumeDeviceError.invalidLevel(level)
        }
        var address = Self.volumeAddress
        guard try Self.isSettable(deviceID: deviceID, address: address) else {
            return
        }
        var scalar = Float32(level)
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &scalar
        )
        try Self.check(status, operation: "set output volume")
    }

    func setMuted(_ muted: Bool, deviceID: AudioDeviceID) throws {
        var address = Self.muteAddress
        guard try Self.isSettable(deviceID: deviceID, address: address) else {
            return
        }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        )
        try Self.check(status, operation: "set output mute")
    }

    func monitor(deviceID: AudioDeviceID?) throws {
        stopMonitoring()
        guard let deviceID else { return }

        let snapshot = try inspect(deviceID: deviceID)
        monitoredDeviceID = deviceID

        if snapshot.capabilities.volumeReadable {
            var address = Self.volumeAddress
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onExternalChange?()
            }
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
            do {
                try Self.check(status, operation: "install output-volume listener")
                volumeListener = listener
            } catch {
                monitoredDeviceID = nil
                throw error
            }
        }

        if snapshot.capabilities.muteReadable {
            var address = Self.muteAddress
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onExternalChange?()
            }
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
            do {
                try Self.check(status, operation: "install output-mute listener")
                muteListener = listener
            } catch {
                removeVolumeListener(deviceID: deviceID)
                monitoredDeviceID = nil
                throw error
            }
        }
    }

    func stopMonitoring() {
        guard let deviceID = monitoredDeviceID else {
            volumeListener = nil
            muteListener = nil
            return
        }
        removeVolumeListener(deviceID: deviceID)
        removeMuteListener(deviceID: deviceID)
        monitoredDeviceID = nil
    }

    deinit {
        if let deviceID = monitoredDeviceID {
            if let volumeListener {
                var address = Self.volumeAddress
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, volumeListener)
            }
            if let muteListener {
                var address = Self.muteAddress
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, muteListener)
            }
        }
    }

    private func removeVolumeListener(deviceID: AudioDeviceID) {
        guard let volumeListener else { return }
        var address = Self.volumeAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, volumeListener)
        self.volumeListener = nil
    }

    private func removeMuteListener(deviceID: AudioDeviceID) {
        guard let muteListener else { return }
        var address = Self.muteAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, muteListener)
        self.muteListener = nil
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func hasProperty(deviceID: AudioDeviceID, address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(deviceID, &address)
    }

    private static func isSettable(deviceID: AudioDeviceID, address: AudioObjectPropertyAddress) throws -> Bool {
        var address = address
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        try check(status, operation: "query property writability")
        return settable.boolValue
    }

    private static func readVolume(deviceID: AudioDeviceID, address: AudioObjectPropertyAddress) throws -> Double {
        var address = address
        var value: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        try check(status, operation: "read output volume")
        return min(max(Double(value), 0), 1)
    }

    private static func readMute(deviceID: AudioDeviceID, address: AudioObjectPropertyAddress) throws -> Bool {
        var address = address
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        try check(status, operation: "read output mute")
        return value != 0
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw MasterVolumeDeviceError.operationFailed(operation: operation, status: status)
        }
    }
}
