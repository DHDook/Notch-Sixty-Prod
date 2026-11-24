import CoreAudio
import Foundation

// E36 S3: the app side of the driver's programme transport (transport A, G1 closed 23 Nov 2026): a read-only mapping of the
// driver's shared-memory ring, read from the DAC's own callback. There is no input stream, so macOS shows no capture
// indicator and asks for no microphone permission. Everything in this file is control plane: it maps, attaches, writes the
// protocol properties and steers the clock on a timer. The realtime part is `N60VirtualRingPump` and `n60/vd_ring.h`.
//
// Rates: the source follows the DAC's rate (any, to 384 kHz); the driver is told the DAC's rates and runs at its rate.
// Channels: the ring carries the layout's channels; the stereo bridge takes the first two (surround folding is S6b).
// Reset: `close()` stops steering, destroys the pump, then unmaps, in that order.

/// The layouts the driver offers, as the codes in the protocol header (stereo to 7.1.4).
enum VirtualDeviceLayout: UInt32, CaseIterable, Sendable {
    case stereo = 1, surround51, surround71, surround514, surround714

    var channelCount: Int {
        switch self {
        case .stereo: return 2
        case .surround51: return 6
        case .surround71: return 8
        case .surround514: return 10
        case .surround714: return 12
        }
    }
}

/// Where the ring lives. POSIX shared-memory names are limited to 31 characters, and a sandboxed app may only open names
/// that start with its app-group id, so the id has to be short (`<TeamID>.group.n60vd` is 22).
enum VirtualRingNaming {
    static let objectName = "n60vd"
    static let maxLength = 31

    static func shmName(appGroupID: String) -> String? {
        let name = "\(appGroupID)/\(objectName)"
        return !appGroupID.isEmpty && name.utf8.count <= maxLength ? name : nil
    }
}

/// The virtual device must never be the app's own output: the app would play into the device it reads from.
enum VirtualDeviceOutputGuard {
    static func refuses(outputUID: String, virtualDeviceUID: String = N60_VD_DEVICE_UID) -> Bool {
        outputUID == virtualDeviceUID
    }
}

/// A mapped ring. Production maps shared memory; tests hand over plain memory.
protocol VirtualRingMapping: AnyObject {
    var base: UnsafeRawPointer { get }
    var bytes: Int { get }
}

enum VirtualRingMapError: Error, Equatable {
    /// errno from the mapping call. ENOENT means no driver is publishing a ring.
    case unavailable(Int32)
}

protocol VirtualRingMapper {
    func map(name: String) -> Result<any VirtualRingMapping, VirtualRingMapError>
}

struct SystemVirtualRingMapper: VirtualRingMapper {
    private final class Mapping: VirtualRingMapping {
        let base: UnsafeRawPointer
        let bytes: Int
        init(base: UnsafeRawPointer, bytes: Int) { self.base = base; self.bytes = bytes }
        deinit { N60VirtualRingUnmap(base, bytes) }
    }

    func map(name: String) -> Result<any VirtualRingMapping, VirtualRingMapError> {
        var base: UnsafeRawPointer?
        var bytes = 0
        let code = N60VirtualRingMapShm(name, &base, &bytes)
        guard code == 0, let base else { return .failure(.unavailable(code)) }
        return .success(Mapping(base: base, bytes: bytes))
    }
}

/// Writes the protocol properties of E36 S3 (value encodings in `docs/VIRTUAL_DEVICE_PROTOCOL.md`).
struct DriverControlWriter {
    let access: any DriverPluginAccess

    /// The scalar is clamped to 1 +- 0.001 before it is written.
    @discardableResult
    func writeClockScalar(plugIn: AudioObjectID, _ scalar: Double) -> OSStatus {
        let limit = Double(N60_VD_CLOCK_SCALAR_MAX_PPM) * 1e-6
        var value = Swift.min(Swift.max(scalar, 1 - limit), 1 + limit)
        return access.writeData(object: plugIn, selector: N60_VD_PROP_CLOCK_SCALAR, data: withUnsafeBytes(of: &value) { Data($0) })
    }

    /// Ascending, at most `N60_VD_MAX_DAC_RATES` entries. A one-entry list pins the device to that rate.
    @discardableResult
    func writeDACRates(plugIn: AudioObjectID, _ rates: [Double]) -> OSStatus {
        let list = Array(Set(rates.filter { $0 > 0 }).sorted().prefix(Int(N60_VD_MAX_DAC_RATES)))
        guard !list.isEmpty else { return kAudioHardwareIllegalOperationError }
        let data = list.withUnsafeBytes { Data($0) }
        return access.writeData(object: plugIn, selector: N60_VD_PROP_DAC_RATES, data: data)
    }

    @discardableResult
    func writeLayout(plugIn: AudioObjectID, _ layout: VirtualDeviceLayout) -> OSStatus {
        var code = layout.rawValue
        return access.writeData(object: plugIn, selector: N60_VD_PROP_LAYOUT, data: withUnsafeBytes(of: &code) { Data($0) })
    }
}

/// The driver path's capture source. It has no capture device: the DAC's callback reads the ring directly, so
/// `captureDeviceID` is always unknown.
final class VirtualDeviceCaptureSource: CaptureSource {
    enum OpenError: Error, Equatable {
        /// The selected output is the virtual device itself.
        case outputIsVirtualDevice
        case ringNameInvalid
        case ringUnavailable(Int32)
        case ringInvalid(Int32)
        case controlFailed(OSStatus)
        case alreadyOpen
    }

    struct Configuration {
        var outputUID: String
        /// The DAC's current rate and every rate it offers (the driver is told both, ascending).
        var dacRate: Double
        var dacRates: [Double]
        var layout: VirtualDeviceLayout = .stereo
        /// Largest callback the DAC asks for; the reader prime level is two of these or 1024 frames, whichever is more.
        var maxCallbackFrames: UInt32 = 4096
        var appGroupID: String
        var plugIn: AudioObjectID
    }

    private let mapper: any VirtualRingMapper
    private let control: DriverControlWriter
    private let lock = NSLock()
    private var mapping: (any VirtualRingMapping)?
    private var plugIn = AudioObjectID(kAudioObjectUnknown)
    private var steerTimer: (any LeaseTimer)?
    private var steer = n60_vd_steer()
    private var previousSum: UInt64 = 0
    private var previousSamples: UInt64 = 0
    private(set) var pump: OpaquePointer?
    private(set) var lastScalar = 1.0
    private(set) var lastScalarStatus: OSStatus = noErr

    var captureDeviceID: AudioDeviceID { AudioDeviceID(kAudioObjectUnknown) }

    init(mapper: any VirtualRingMapper = SystemVirtualRingMapper(), access: any DriverPluginAccess) {
        self.mapper = mapper
        self.control = DriverControlWriter(access: access)
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return pump != nil
    }

    /// Maps the ring, pins the driver to the DAC's rate and layout, and attaches the reader to the bridge. The IOProc to
    /// register on the DAC is `N60VirtualRingOutputIOProc` with `pump` as its client data.
    func open(_ configuration: Configuration, bridge: OpaquePointer) throws {
        lock.lock(); defer { lock.unlock() }
        guard pump == nil else { throw OpenError.alreadyOpen }
        guard !VirtualDeviceOutputGuard.refuses(outputUID: configuration.outputUID) else { throw OpenError.outputIsVirtualDevice }
        guard let name = VirtualRingNaming.shmName(appGroupID: configuration.appGroupID) else { throw OpenError.ringNameInvalid }

        // Rate pinning: the driver follows the DAC, so tell it the DAC's rates first, with its own rate included.
        let rates = configuration.dacRates + [configuration.dacRate]
        for status in [control.writeDACRates(plugIn: configuration.plugIn, rates),
                       control.writeLayout(plugIn: configuration.plugIn, configuration.layout)] where status != noErr {
            throw OpenError.controlFailed(status)
        }

        let mapped: any VirtualRingMapping
        switch mapper.map(name: name) {
        case .success(let value): mapped = value
        case .failure(.unavailable(let code)): throw OpenError.ringUnavailable(code)
        }
        let prime = Swift.max(UInt32(1024), configuration.maxCallbackFrames * 2)
        guard let created = N60VirtualRingPumpCreate(bridge, mapped.base, mapped.bytes, prime, configuration.maxCallbackFrames) else {
            throw OpenError.ringInvalid(N60_VD_ERR_MAGIC)
        }
        mapping = mapped
        pump = created
        plugIn = configuration.plugIn
        n60_vd_steer_init(&steer, configuration.dacRate, prime)
        previousSum = 0
        previousSamples = 0
        lastScalar = 1.0
    }

    /// One steering step: mean fill since the last step in, the clock scalar out and written to the driver. Control plane.
    @discardableResult
    func steerOnce(dt: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let pump else { return nil }
        let mean = n60_vd_ring_reader_mean_fill(N60VirtualRingPumpReader(pump), &previousSum, &previousSamples)
        guard mean >= 0 else { return nil }  // nothing played in the window (priming): leave the clock alone
        lastScalar = n60_vd_steer_update(&steer, mean, dt)
        lastScalarStatus = control.writeClockScalar(plugIn: plugIn, lastScalar)
        return lastScalar
    }

    /// Steers every 250 ms from a control-plane timer (the lease timer's scheduler; never an audio callback).
    func startSteering(scheduler: any LeaseScheduler) {
        lock.lock(); defer { lock.unlock() }
        guard steerTimer == nil, pump != nil else { return }
        let interval = VirtualDeviceProtocol.leaseRenewMs
        steerTimer = scheduler.schedule(everyMs: interval) { [weak self] in
            self?.steerOnce(dt: Double(interval) / 1000.0)
        }
    }

    /// Counters for the signal-path display and tests.
    var counters: (underrunFrames: UInt64, droppedFrames: UInt64, overruns: UInt64, fillFrames: UInt32)? {
        lock.lock(); defer { lock.unlock() }
        guard let pump else { return nil }
        let reader = N60VirtualRingPumpReader(pump).pointee
        return (reader.underrunFrames, reader.droppedFrames, reader.overruns, reader.fillFrames)
    }

    func close() {
        lock.lock()
        let timer = steerTimer
        steerTimer = nil
        let oldPump = pump
        pump = nil
        let oldMapping = mapping
        mapping = nil
        lock.unlock()
        // Order: stop steering, then the reader, then the memory it reads. The caller has already stopped the IOProc.
        timer?.cancel()
        if let oldPump { N60VirtualRingPumpDestroy(oldPump) }
        if oldPump != nil { _ = control.writeClockScalar(plugIn: plugIn, 1.0) }  // leave the driver's clock nominal
        _ = oldMapping
    }
}
