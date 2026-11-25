import AppKit
import CoreAudio
import Foundation

// E15 S2: hardware events for Follow macOS output (design note 4). The default-output listener and the current
// device's data-source listener are installed only while following (`start()`), so fixed mode never listens. All
// callbacks arrive on the main queue. Notch Sixty only reads the macOS default; it never writes it (note 2).

protocol FollowOutputEventSource: AnyObject {
    var onDefaultOutputChanged: ((OutputFollowTarget?) -> Void)? { get set }
    var onDataSourceChanged: ((OutputFollowTarget) -> Void)? { get set }
    var onDeviceListChanged: (() -> Void)? { get set }
    var onWillSleep: (() -> Void)? { get set }
    var onDidWake: (() -> Void)? { get set }

    /// Installs the default-output, device-list and power listeners. Idempotent.
    func start() throws
    /// Removes every listener, including the data-source listener.
    func stop()
    /// Watches the data source of the device with this UID (nil removes the watch).
    func monitorDataSource(ofDeviceUID uid: String?)
    /// The macOS default output now, with its data source; nil when there is none.
    func currentDefaultTarget() -> OutputFollowTarget?
    /// The data source the device reports now, nil when it reports none.
    func dataSourceID(forDeviceUID uid: String) -> UInt32?
    /// Output device UIDs present right now, Notch Sixty's own private devices excluded.
    func availableOutputUIDs() -> Set<String>
    /// Notch Sixty's own private tap and aggregate devices: never follow targets.
    func ownDeviceUIDs() -> Set<String>
}

enum FollowOutputOwnDevices {
    /// UID prefixes of the private aggregates the transports create.
    static let uidPrefix = "com.dhdook.NotchSixty."
    static func isOwn(uid: String) -> Bool { uid.hasPrefix(uidPrefix) }
}

final class CoreAudioFollowOutputEventSource: FollowOutputEventSource {
    var onDefaultOutputChanged: ((OutputFollowTarget?) -> Void)?
    var onDataSourceChanged: ((OutputFollowTarget) -> Void)?
    var onDeviceListChanged: (() -> Void)?
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var dataSourceListener: AudioObjectPropertyListenerBlock?
    private var dataSourceDeviceID: AudioDeviceID?
    private var powerTokens: [NSObjectProtocol] = []

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func start() throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        if defaultListener == nil {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.onDefaultOutputChanged?(self.currentDefaultTarget())
            }
            let status = AudioObjectAddPropertyListenerBlock(system, &address, DispatchQueue.main, listener)
            guard status == noErr else {
                throw CoreAudioTransportError.operationFailed(operation: "install default-output listener", status: status)
            }
            defaultListener = listener
        }
        if deviceListListener == nil {
            var address = Self.address(kAudioHardwarePropertyDevices)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onDeviceListChanged?() }
            let status = AudioObjectAddPropertyListenerBlock(system, &address, DispatchQueue.main, listener)
            guard status == noErr else {
                stop()
                throw CoreAudioTransportError.operationFailed(operation: "install follow device-list listener", status: status)
            }
            deviceListListener = listener
        }
        if powerTokens.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            powerTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
                [weak self] _ in self?.onWillSleep?()
            })
            powerTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in self?.onDidWake?()
            })
        }
    }

    func stop() {
        monitorDataSource(ofDeviceUID: nil)
        let system = AudioObjectID(kAudioObjectSystemObject)
        if let defaultListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(system, &address, DispatchQueue.main, defaultListener)
            self.defaultListener = nil
        }
        if let deviceListListener {
            var address = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(system, &address, DispatchQueue.main, deviceListListener)
            self.deviceListListener = nil
        }
        for token in powerTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        powerTokens.removeAll()
    }

    deinit { stop() }

    func monitorDataSource(ofDeviceUID uid: String?) {
        if let deviceID = dataSourceDeviceID, let dataSourceListener {
            var address = Self.address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, dataSourceListener)
        }
        dataSourceDeviceID = nil
        dataSourceListener = nil
        guard let uid, let deviceID = Self.outputDeviceID(forUID: uid) else { return }
        var address = Self.address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.onDataSourceChanged?(OutputFollowTarget(
                key: OutputKey(deviceUID: uid, dataSourceID: self.dataSourceID(forDeviceUID: uid)),
                displayName: Self.name(of: deviceID) ?? ""))
        }
        guard AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener) == noErr else { return }
        dataSourceDeviceID = deviceID
        dataSourceListener = listener
    }

    func currentDefaultTarget() -> OutputFollowTarget? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown,
              let uid = try? CoreAudioDeviceCatalogSupport.readString(
                  deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID, operation: .readDeviceUID)
        else { return nil }
        return OutputFollowTarget(
            key: OutputKey(deviceUID: uid, dataSourceID: Self.dataSource(of: deviceID)),
            displayName: Self.name(of: deviceID) ?? "")
    }

    func dataSourceID(forDeviceUID uid: String) -> UInt32? {
        Self.outputDeviceID(forUID: uid).flatMap { Self.dataSource(of: $0) }
    }

    func availableOutputUIDs() -> Set<String> {
        Set(((try? CoreAudioOutputDeviceCatalog().outputDevices()) ?? []).map(\.uid).filter { !FollowOutputOwnDevices.isOwn(uid: $0) })
    }

    func ownDeviceUIDs() -> Set<String> {
        // Own devices are recognised by prefix; the set is the present ones so the policy can match them exactly.
        Set(((try? CoreAudioOutputDeviceCatalog().outputDevices()) ?? []).map(\.uid).filter(FollowOutputOwnDevices.isOwn(uid:)))
    }

    private static func outputDeviceID(forUID uid: String) -> AudioDeviceID? {
        ((try? CoreAudioOutputDeviceCatalog().outputDevices()) ?? []).first { $0.uid == uid }?.deviceID
    }

    private static func name(of deviceID: AudioDeviceID) -> String? {
        try? CoreAudioDeviceCatalogSupport.readString(
            deviceID: deviceID, selector: kAudioObjectPropertyName, operation: .readDeviceName)
    }

    private static func dataSource(of deviceID: AudioDeviceID) -> UInt32? {
        var address = address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
