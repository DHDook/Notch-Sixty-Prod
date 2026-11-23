import CoreAudio
import Foundation

// E36 S2: app side of the virtual driver protocol (docs/VIRTUAL_DEVICE_PROTOCOL.md). Control plane only: nothing here
// runs on, or is called from, an audio callback. Allocation, locks and timers are fine because of that. Rates and
// channel counts do not appear: the protocol carries no audio. Reset: `DriverLeaseWriter.release()` ends the lease.

enum VirtualDeviceProtocol {
    /// Versions this app build speaks. Anything else is refused as "unknown driver version".
    static let acceptedVersions: Set<UInt32> = [N60_VD_PROTOCOL_VERSION]
    /// Oldest version still worth running; an older driver reads as "needs update".
    static let minimumVersion: UInt32 = N60_VD_PROTOCOL_VERSION
    static let currentVersion: UInt32 = N60_VD_PROTOCOL_VERSION
    static let bundleID = N60_VD_PLUGIN_BUNDLE_ID
    static let leaseRenewMs = N60_VD_LEASE_RENEW_MS
    static let leaseExpiryMs = N60_VD_LEASE_EXPIRY_MS
}

/// What the Settings sheet and the switch (S4, S5) read.
enum DriverStatus: Equatable, Sendable {
    case notInstalled
    case installed(version: UInt32)
    case needsUpdate(version: UInt32)
    /// A version this app does not speak (usually a newer driver than the app).
    case unknownVersion(UInt32)
    case inUse(version: UInt32)
    /// The driver is there and speaks our version but refused the first lease write.
    case leaseRefused(OSStatus)

    /// Only these two let the app take the driver path.
    var isUsable: Bool {
        switch self {
        case .installed, .inUse: return true
        case .notInstalled, .needsUpdate, .unknownVersion, .leaseRefused: return false
        }
    }
}

/// The version gate, a pure function so every case is testable without Core Audio.
struct DriverVersionGate: Equatable, Sendable {
    var accepted: Set<UInt32> = VirtualDeviceProtocol.acceptedVersions
    var minimum: UInt32 = VirtualDeviceProtocol.minimumVersion

    func status(forDriverVersion version: UInt32, leaseHeld: Bool) -> DriverStatus {
        if version < minimum { return .needsUpdate(version: version) }
        guard accepted.contains(version) else { return .unknownVersion(version) }
        return leaseHeld ? .inUse(version: version) : .installed(version: version)
    }
}

/// The plug-in object calls the protocol needs. `SystemHALPropertyStore` is the production implementation; tests pass a
/// fake plug-in. Kept apart from `HALPropertyStore` (taps and aggregates) so each fake stays small.
protocol DriverPluginAccess: AnyObject {
    /// The plug-in object for a bundle ID, or nil when no such plug-in is loaded.
    func pluginObject(forBundleID bundleID: String) -> AudioObjectID?
    func readUInt32(object: AudioObjectID, selector: UInt32) -> (status: OSStatus, value: UInt32)
    func writeData(object: AudioObjectID, selector: UInt32, data: Data) -> OSStatus
}

extension SystemHALPropertyStore: DriverPluginAccess {
    func pluginObject(forBundleID bundleID: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateBundleIDToPlugIn,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = bundleID as CFString
        var plugIn = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifierPointer, &size, &plugIn
            )
        }
        guard status == noErr, plugIn != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return plugIn
    }

    func readUInt32(object: AudioObjectID, selector: UInt32) -> (status: OSStatus, value: UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return (status, value)
    }

    func writeData(object: AudioObjectID, selector: UInt32, data: Data) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        return data.withUnsafeBytes { buffer in
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(buffer.count), buffer.baseAddress!)
        }
    }
}

/// Finds the driver's plug-in and reads its protocol version. Read-only: it never installs, loads or restarts anything.
struct DriverDiscovery {
    let access: any DriverPluginAccess
    var gate = DriverVersionGate()
    var bundleID = VirtualDeviceProtocol.bundleID

    /// The plug-in object and the status for it. `leaseHeld` is true while this run's lease writer is active.
    func probe(leaseHeld: Bool) -> (plugIn: AudioObjectID?, status: DriverStatus) {
        guard let plugIn = access.pluginObject(forBundleID: bundleID) else { return (nil, .notInstalled) }
        let read = access.readUInt32(object: plugIn, selector: N60_VD_PROP_PROTOCOL_VERSION)
        // A plug-in that is present but will not answer the version property is not ours at a version we speak.
        guard read.status == noErr else { return (plugIn, .unknownVersion(0)) }
        return (plugIn, gate.status(forDriverVersion: read.value, leaseHeld: leaseHeld))
    }
}

/// A repeating control-plane timer. Production uses a dispatch timer on a utility queue; tests step a fake by hand.
protocol LeaseTimer: AnyObject {
    func cancel()
}

protocol LeaseScheduler: AnyObject {
    func schedule(everyMs interval: UInt32, _ handler: @escaping @Sendable () -> Void) -> any LeaseTimer
}

final class DispatchLeaseScheduler: LeaseScheduler {
    private final class Timer: LeaseTimer {
        let source: DispatchSourceTimer
        init(source: DispatchSourceTimer) { self.source = source }
        func cancel() { source.cancel() }
    }

    private let queue = DispatchQueue(label: "com.dhdook.NotchSixty.driver-lease", qos: .utility)

    func schedule(everyMs interval: UInt32, _ handler: @escaping @Sendable () -> Void) -> any LeaseTimer {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(Int(interval)), repeating: .milliseconds(Int(interval)))
        source.setEventHandler(handler: handler)
        source.resume()
        return Timer(source: source)
    }
}

/// Renews the driver lease every 250 ms and releases it at once on Quit. The driver publishes its device only while a
/// lease is valid and removes it 2 s after the last write, so a crash leaves macOS on a real output.
final class DriverLeaseWriter {
    enum StartError: Error, Equatable { case alreadyStarted, firstWriteFailed(OSStatus) }

    private let access: any DriverPluginAccess
    private let scheduler: any LeaseScheduler
    private let lock = NSLock()
    private var plugIn = AudioObjectID(kAudioObjectUnknown)
    private var timer: (any LeaseTimer)?
    private var sequence: UInt64 = 0
    private let sessionToken: UInt32
    private var failure: OSStatus?
    var lastFailure: OSStatus? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    init(access: any DriverPluginAccess, scheduler: any LeaseScheduler = DispatchLeaseScheduler(),
         sessionToken: UInt32 = UInt32.random(in: 1...UInt32.max)) {
        self.access = access
        self.scheduler = scheduler
        self.sessionToken = sessionToken
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return timer != nil
    }

    /// Writes the first lease and starts the renewal timer. A failed first write starts nothing.
    func start(plugIn: AudioObjectID) throws {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { throw StartError.alreadyStarted }
        self.plugIn = plugIn
        let status = writeLocked(validMs: VirtualDeviceProtocol.leaseExpiryMs)
        guard status == noErr else { throw StartError.firstWriteFailed(status) }
        timer = scheduler.schedule(everyMs: VirtualDeviceProtocol.leaseRenewMs) { [weak self] in self?.renew() }
    }

    func renew() {
        lock.lock(); defer { lock.unlock() }
        guard timer != nil else { return }
        let status = writeLocked(validMs: VirtualDeviceProtocol.leaseExpiryMs)
        failure = status == noErr ? nil : status
    }

    /// Stops renewing and tells the driver to drop the device now. Safe to call twice.
    func release() {
        lock.lock(); defer { lock.unlock() }
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
        _ = writeLocked(validMs: 0)
    }

    private func writeLocked(validMs: UInt32) -> OSStatus {
        sequence += 1
        var lease = N60VDLease(
            protocolVersion: VirtualDeviceProtocol.currentVersion, sessionToken: sessionToken,
            sequence: sequence, validMs: validMs, reserved: 0
        )
        let data = withUnsafeBytes(of: &lease) { Data($0) }
        return access.writeData(object: plugIn, selector: N60_VD_PROP_LEASE, data: data)
    }
}

/// The status the UI reads: discovery plus whether this run holds the lease. Refresh from the control plane only.
final class DriverStatusModel {
    private let discovery: DriverDiscovery
    private let lease: DriverLeaseWriter
    private(set) var status: DriverStatus = .notInstalled
    /// The plug-in object seen by the last probe (E36 S6: where the latency writer sends its value).
    private(set) var plugIn: AudioObjectID?

    init(discovery: DriverDiscovery, lease: DriverLeaseWriter) {
        self.discovery = discovery
        self.lease = lease
    }

    @discardableResult
    func refresh() -> DriverStatus {
        let probed = discovery.probe(leaseHeld: lease.isActive)
        plugIn = probed.plugIn
        status = probed.status
        return status
    }

    /// Takes the lease when the driver is usable; refuses (and says why) otherwise. Never falls back to the tap.
    func acquireLease() -> DriverStatus {
        let probed = discovery.probe(leaseHeld: lease.isActive)
        guard probed.status.isUsable, let plugIn = probed.plugIn else { status = probed.status; return status }
        if !lease.isActive {
            do { try lease.start(plugIn: plugIn) } catch DriverLeaseWriter.StartError.firstWriteFailed(let code) {
                status = .leaseRefused(code)
                return status
            } catch {
                status = probed.status
                return status
            }
        }
        return refresh()
    }

    func releaseLease() {
        lease.release()
        refresh()
    }
}
