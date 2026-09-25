import AppKit
import CoreAudio
import CoreGraphics
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

protocol MasterVolumeDeviceControlling: AnyObject {
    var onExternalChange: (() -> Void)? { get set }

    func inspect(deviceID: AudioDeviceID) throws -> MasterVolumeDeviceSnapshot
    func setVolume(_ level: Double, deviceID: AudioDeviceID) throws
    func setMuted(_ muted: Bool, deviceID: AudioDeviceID) throws
    func monitor(deviceID: AudioDeviceID?) throws
    func stopMonitoring()
}

final class CoreAudioMasterVolumeController: MasterVolumeDeviceControlling {
    private struct ListenerRegistration {
        let address: AudioObjectPropertyAddress
        let listener: AudioObjectPropertyListenerBlock
    }

    var onExternalChange: (() -> Void)?

    private var monitoredDeviceID: AudioDeviceID?
    private var volumeListeners: [ListenerRegistration] = []
    private var muteListener: AudioObjectPropertyListenerBlock?

    func inspect(deviceID: AudioDeviceID) throws -> MasterVolumeDeviceSnapshot {
        let volumeAddresses = try Self.preferredVolumeAddresses(deviceID: deviceID)
        let muteAddress = Self.muteAddress

        let volumeReadable = !volumeAddresses.isEmpty
        var volumeWritable = volumeReadable
        for address in volumeAddresses where volumeWritable {
            if !(try Self.isSettable(deviceID: deviceID, address: address)) {
                volumeWritable = false
            }
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

        let level = volumeReadable ? try Self.readVolume(deviceID: deviceID, addresses: volumeAddresses) : nil
        let muted = muteReadable ? try Self.readMute(deviceID: deviceID, address: muteAddress) : nil
        return MasterVolumeDeviceSnapshot(capabilities: capabilities, level: level, muted: muted)
    }

    func setVolume(_ level: Double, deviceID: AudioDeviceID) throws {
        guard MasterVolumeConfiguration.levelRange.contains(level), level.isFinite else {
            throw MasterVolumeDeviceError.invalidLevel(level)
        }

        let addresses = try Self.preferredVolumeAddresses(deviceID: deviceID)
        guard !addresses.isEmpty else { return }
        for address in addresses {
            guard try Self.isSettable(deviceID: deviceID, address: address) else { return }
        }

        for candidate in addresses {
            var address = candidate
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
    }

    func setMuted(_ muted: Bool, deviceID: AudioDeviceID) throws {
        var address = Self.muteAddress
        guard try Self.isSettable(deviceID: deviceID, address: address) else { return }
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
            let addresses = try Self.preferredVolumeAddresses(deviceID: deviceID)
            do {
                for candidate in addresses {
                    var address = candidate
                    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                        self?.onExternalChange?()
                    }
                    let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
                    try Self.check(status, operation: "install output-volume listener")
                    volumeListeners.append(ListenerRegistration(address: candidate, listener: listener))
                }
            } catch {
                removeVolumeListeners(deviceID: deviceID)
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
                removeVolumeListeners(deviceID: deviceID)
                monitoredDeviceID = nil
                throw error
            }
        }
    }

    func stopMonitoring() {
        guard let deviceID = monitoredDeviceID else {
            volumeListeners.removeAll(keepingCapacity: false)
            muteListener = nil
            return
        }
        removeVolumeListeners(deviceID: deviceID)
        removeMuteListener(deviceID: deviceID)
        monitoredDeviceID = nil
    }

    deinit {
        if let deviceID = monitoredDeviceID {
            removeVolumeListeners(deviceID: deviceID)
            removeMuteListener(deviceID: deviceID)
        }
    }

    private func removeVolumeListeners(deviceID: AudioDeviceID) {
        for registration in volumeListeners {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, registration.listener)
        }
        volumeListeners.removeAll(keepingCapacity: false)
    }

    private func removeMuteListener(deviceID: AudioDeviceID) {
        guard let muteListener else { return }
        var address = Self.muteAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, muteListener)
        self.muteListener = nil
    }

    private static var mainVolumeAddress: AudioObjectPropertyAddress {
        volumeAddress(element: kAudioObjectPropertyElementMain)
    }

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func preferredVolumeAddresses(deviceID: AudioDeviceID) throws -> [AudioObjectPropertyAddress] {
        let main = mainVolumeAddress
        if hasProperty(deviceID: deviceID, address: main),
           try isSettable(deviceID: deviceID, address: main) {
            return [main]
        }

        let channelAddresses = preferredStereoChannelElements(deviceID: deviceID)
            .map { volumeAddress(element: $0) }
            .filter { hasProperty(deviceID: deviceID, address: $0) }
        if !channelAddresses.isEmpty { return channelAddresses }

        if hasProperty(deviceID: deviceID, address: main) { return [main] }
        return []
    }

    private static func preferredStereoChannelElements(deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var channels: [UInt32] = [1, 2]
        var dataSize = UInt32(MemoryLayout<UInt32>.size * channels.count)

        if AudioObjectHasProperty(deviceID, &address) {
            let status = channels.withUnsafeMutableBytes { buffer -> OSStatus in
                guard let baseAddress = buffer.baseAddress else { return noErr }
                return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, baseAddress)
            }
            if status != noErr || channels.contains(kAudioObjectPropertyElementMain) {
                channels = [1, 2]
            }
        }

        var seen = Set<UInt32>()
        let result = channels.compactMap { channel -> AudioObjectPropertyElement? in
            guard channel != kAudioObjectPropertyElementMain,
                  seen.insert(channel).inserted else { return nil }
            return AudioObjectPropertyElement(channel)
        }
        return result.isEmpty ? [1, 2] : result
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

    private static func readVolume(deviceID: AudioDeviceID, addresses: [AudioObjectPropertyAddress]) throws -> Double {
        guard !addresses.isEmpty else { return 1.0 }
        var sum = 0.0
        for candidate in addresses {
            var address = candidate
            var value: Float32 = 0
            var dataSize = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
            try check(status, operation: "read output volume")
            sum += min(max(Double(value), 0), 1)
        }
        return sum / Double(addresses.count)
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

enum GlobalVolumeKeyMonitoringState: Equatable, Sendable {
    case stopped
    case permissionRequired
    case active
}

enum GlobalVolumeKeyMonitorError: Error, LocalizedError, Equatable {
    case permissionRequired
    case eventTapUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Keyboard volume control requires Input Monitoring permission in System Settings > Privacy & Security > Input Monitoring."
        case .eventTapUnavailable:
            return "Unable to create the listen-only system volume-key event tap."
        }
    }
}

protocol GlobalVolumeKeyMonitoring: AnyObject {
    var onVolumeIncrement: (() -> Void)? { get set }
    var onVolumeDecrement: (() -> Void)? { get set }
    var state: GlobalVolumeKeyMonitoringState { get }

    func start() throws
    func stop()
}

enum GlobalVolumeKeyAction: Equatable, Sendable {
    case increment
    case decrement
}

/// Listen-only public Core Graphics event tap for fixed-volume outputs. macOS
/// handles hardware volume keys below ordinary AppKit key delivery; the event
/// tap observes their system-defined auxiliary-control events without seizing,
/// suppressing, synthesizing, or reposting input.
final class CoreGraphicsGlobalVolumeKeyMonitor: GlobalVolumeKeyMonitoring {
    var onVolumeIncrement: (() -> Void)?
    var onVolumeDecrement: (() -> Void)?
    private(set) var state: GlobalVolumeKeyMonitoringState = .stopped

    private static let auxiliaryControlButtonSubtype: Int16 = 8
    private static let soundUpKeyCode = 0
    private static let soundDownKeyCode = 1
    private static let keyDownState = 0xA

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    static func action(subtype: Int16, data1: Int) -> GlobalVolumeKeyAction? {
        guard subtype == auxiliaryControlButtonSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyState = (data1 & 0x0000FF00) >> 8
        guard keyState == keyDownState else { return nil }

        switch keyCode {
        case soundUpKeyCode:
            return .increment
        case soundDownKeyCode:
            return .decrement
        default:
            return nil
        }
    }

    func start() throws {
        guard eventTap == nil else { return }

        guard CGPreflightListenEventAccess() else {
            _ = CGRequestListenEventAccess()
            state = .permissionRequired
            throw GlobalVolumeKeyMonitorError.permissionRequired
        }

        guard let systemDefinedType = CGEventType(
            rawValue: UInt32(NSEvent.EventType.systemDefined.rawValue)
        ) else {
            state = .stopped
            throw GlobalVolumeKeyMonitorError.eventTapUnavailable
        }
        let eventMask = CGEventMask(1) << systemDefinedType.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<CoreGraphicsGlobalVolumeKeyMonitor>
                    .fromOpaque(context)
                    .takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue),
                      let nsEvent = NSEvent(cgEvent: event),
                      let action = CoreGraphicsGlobalVolumeKeyMonitor.action(
                        subtype: nsEvent.subtype.rawValue,
                        data1: nsEvent.data1
                      ) else {
                    return Unmanaged.passUnretained(event)
                }

                switch action {
                case .increment:
                    monitor.onVolumeIncrement?()
                case .decrement:
                    monitor.onVolumeDecrement?()
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            state = .stopped
            throw GlobalVolumeKeyMonitorError.eventTapUnavailable
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            state = .stopped
            throw GlobalVolumeKeyMonitorError.eventTapUnavailable
        }

        self.eventTap = tap
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        state = .active
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        state = .stopped
    }

    deinit {
        stop()
    }
}
