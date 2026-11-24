import CoreAudio
import Foundation
import Security

// E36 S3b: how a transport session takes its programme from the virtual driver's ring instead of a process tap (design notes
// 2, 7 and 9). Control plane only. The sessions call `DriverCaptureSelection.shared.current` while they are built, so a source
// change is "stop the session, set the selection, build a new session" and the existing fade-out (`stop(fadeOut: true)`) and
// output-gate fade-in (`AudioStartupGatePolicy`) are the fades.
//
// Realtime: nothing here runs in a callback. The DAC callback is `N60VirtualRingOutputIOProc` (allocation: none; locks: none;
// latency: the ring prime, two callbacks or 1024 frames; rates: the DAC's, any to 384 kHz; channels: the layout's, 2 to 12;
// reset: the reader re-primes on attach, epoch change and underrun).

/// What a session needs to build the ring source. Nil `current` means the process tap, which is the default.
final class DriverCaptureSelection: @unchecked Sendable {
    struct Request {
        var plugIn: AudioObjectID
        var appGroupID: String
        var access: any DriverPluginAccess
        var mapper: any VirtualRingMapper = SystemVirtualRingMapper()
        var scheduler: any LeaseScheduler = DispatchLeaseScheduler()
        /// The rates the DAC offers; the default reads Core Audio.
        var dacRates: (AudioDeviceID, Double) -> [Double] = DriverCaptureAttachment.availableRates
    }

    static let shared = DriverCaptureSelection()

    private let lock = NSLock()
    private var request: Request?

    var current: Request? {
        lock.lock(); defer { lock.unlock() }
        return request
    }

    func set(_ request: Request?) {
        lock.lock(); defer { lock.unlock() }
        self.request = request
    }
}

enum DriverCaptureError: Error, LocalizedError, Equatable {
    /// The session shape cannot read the ring (a tap on another device as the programme, or a multi-device aggregate output).
    case unsupportedSession(String)
    case unsupportedChannelCount(Int)
    case appGroupUnavailable
    case open(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSession(let what): return "The virtual audio driver cannot feed \(what)."
        case .unsupportedChannelCount(let count): return "The virtual audio driver has no \(count)-channel layout."
        case .appGroupUnavailable: return "This build has no app group for the virtual audio driver."
        case .open(let message): return "The virtual audio driver ring could not be opened: \(message)"
        }
    }
}

extension VirtualDeviceLayout {
    /// The layout with this many channels, if the driver offers one.
    static func layout(channelCount: Int) -> VirtualDeviceLayout? {
        allCases.first { $0.channelCount == channelCount }
    }

    /// Ring channel order (protocol spec): SMPTE-style, front pair, centre, LFE, side surrounds, rear surrounds, then top front
    /// and top rear pairs. The N-channel and binaural sessions resolve their program map from these labels instead of reading
    /// a device layout.
    var channelLabels: [AudioChannelLabel] {
        let base: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
        let bed = [kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
        let rear = [kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight]
        let tops = [kAudioChannelLabel_LeftTopFront, kAudioChannelLabel_RightTopFront, kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_RightTopRear]
        switch self {
        case .stereo: return base
        case .surround51: return base + bed
        case .surround71: return base + bed + rear
        case .surround514: return base + bed + [kAudioChannelLabel_LeftTopFront, kAudioChannelLabel_RightTopFront]
            + [kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_RightTopRear]
        case .surround714: return base + bed + rear + tops
        }
    }

    var channelDescriptions: [AudioChannelDescription] {
        channelLabels.map { label in
            var description = AudioChannelDescription()
            description.mChannelLabel = label
            return description
        }
    }

    /// What the capture IOProc is handed: interleaved Float32 at the DAC's rate. Stands in for the tap's format.
    func streamFormat(sampleRate: Double) -> AudioStreamFormatDescription {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = sampleRate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        asbd.mChannelsPerFrame = UInt32(channelCount)
        asbd.mBitsPerChannel = 32
        asbd.mBytesPerFrame = UInt32(channelCount) * 4
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerPacket = asbd.mBytesPerFrame
        return AudioStreamFormatDescription(asbd)
    }
}

/// The ring and its pump for one session. The session owns the IOProcs; this owns the mapping and the steering timer.
final class DriverCaptureAttachment {
    /// The app-group id the driver and the app share (`<TeamID>.group.n60vd`), read from the app's own entitlements so no
    /// team id is written in source. Nil when the build has no such group.
    static func appGroupID(entitlementGroups: [String]? = DriverCaptureAttachment.readEntitlementGroups()) -> String? {
        entitlementGroups?.first { $0.hasSuffix("group.\(VirtualRingNaming.objectName)") && VirtualRingNaming.shmName(appGroupID: $0) != nil }
    }

    static func readEntitlementGroups() -> [String]? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) else { return nil }
        return value as? [String]
    }

    static func availableRates(device: AudioDeviceID, current: Double) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [current] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges) == noErr else { return [current] }
        let standard: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
        var rates = Set<Double>([current])
        for range in ranges {
            if range.mMinimum == range.mMaximum { rates.insert(range.mMinimum) }
            else { for rate in standard where rate >= range.mMinimum && rate <= range.mMaximum { rates.insert(rate) } }
        }
        return rates.sorted()
    }

    let source: VirtualDeviceCaptureSource
    let layout: VirtualDeviceLayout
    /// The client data for `N60VirtualRingOutputIOProc` on the DAC.
    let outputClientData: UnsafeMutableRawPointer

    private init(source: VirtualDeviceCaptureSource, layout: VirtualDeviceLayout, pump: OpaquePointer) {
        self.source = source
        self.layout = layout
        self.outputClientData = UnsafeMutableRawPointer(pump)
    }

    /// Maps the ring, pins the driver to the DAC's rate and layout, and starts steering. `clientData`, `captureProc` and
    /// `outputProc` are the session's own bridge and IOProcs.
    static func open(
        _ request: DriverCaptureSelection.Request, outputUID: String, outputDeviceID: AudioDeviceID, dacRate: Double,
        maxCallbackFrames: UInt32, channelCount: Int, clientData: UnsafeMutableRawPointer, captureProc: AudioDeviceIOProc,
        outputProc: AudioDeviceIOProc
    ) throws -> DriverCaptureAttachment {
        guard let layout = VirtualDeviceLayout.layout(channelCount: channelCount) else {
            throw DriverCaptureError.unsupportedChannelCount(channelCount)
        }
        let source = VirtualDeviceCaptureSource(mapper: request.mapper, access: request.access)
        let configuration = VirtualDeviceCaptureSource.Configuration(
            outputUID: outputUID, dacRate: dacRate, dacRates: request.dacRates(outputDeviceID, dacRate), layout: layout,
            maxCallbackFrames: Swift.max(maxCallbackFrames, 64), appGroupID: request.appGroupID, plugIn: request.plugIn)
        do {
            try source.open(configuration, clientData: clientData, captureProc: captureProc, outputProc: outputProc)
        } catch {
            throw DriverCaptureError.open(String(describing: error))
        }
        guard let pump = source.pump else { throw DriverCaptureError.open("no pump") }
        source.startSteering(scheduler: request.scheduler)
        return DriverCaptureAttachment(source: source, layout: layout, pump: pump)
    }

    /// The session has already stopped its IOProc.
    func close() { source.close() }
}
