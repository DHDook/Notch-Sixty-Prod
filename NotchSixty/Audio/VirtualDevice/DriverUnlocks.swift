import CoreAudio
import Foundation

// E36 S6a: the one source of truth for what needs the virtual driver, and the delay the app reports to macOS.
// Control plane only (main actor); nothing here is called from an audio callback. The latency value is in frames at the
// DAC's rate, so the code is rate independent. Reset: `DriverLatencyReporter.reset`.

/// Every feature that is available only with the driver. The Settings notes, and any page that shows such a control as
/// "visible but unavailable", read this list and nothing else, so a feature cannot be gated in one place and not another.
enum DriverUnlock: String, CaseIterable, Equatable, Sendable {
    case reportedLatency
    case surroundOnStereoDAC
    case multichannelDACActiveStereo
    case automaticRateFollowing

    var title: String {
        switch self {
        case .reportedLatency: return "Delay reported to macOS"
        case .surroundOnStereoDAC: return "Surround programme on a stereo DAC"
        case .multichannelDACActiveStereo: return "Active stereo on a multichannel DAC"
        case .automaticRateFollowing: return "Automatic sample-rate following"
        }
    }

    /// What the feature does once the driver path is on.
    var summary: String {
        switch self {
        case .reportedLatency:
            return "Video players read the total delay Notch Sixty adds and keep lip sync without a manual offset."
        case .surroundOnStereoDAC:
            return "5.1 and 7.1.4 programmes are folded to two feeds for a stereo DAC."
        case .multichannelDACActiveStereo:
            return "A multichannel DAC drives active speakers from a stereo source without Audio MIDI Setup changes."
        case .automaticRateFollowing:
            return "The DAC follows the rate the player sets, or its nearest supported multiple. Off by default."
        }
    }

    static let needsDriverNote = "Needs the driver"
}

/// What a feature row shows for the current driver status and input path.
struct DriverUnlockPresentation: Equatable {
    let unlock: DriverUnlock
    let available: Bool
    /// Nil when available; otherwise the reason, always starting with "Needs the driver".
    let note: String?
}

enum DriverUnlockRegistry {
    static var all: [DriverUnlock] { DriverUnlock.allCases }

    /// Available only while the driver path is actually in use.
    static func isAvailable(_ unlock: DriverUnlock, path: AudioInputPath, status: DriverStatus) -> Bool {
        guard path == .virtualDriver else { return false }
        if case .inUse = status { return true }
        return false
    }

    static func presentation(path: AudioInputPath, status: DriverStatus) -> [DriverUnlockPresentation] {
        all.map { unlock in
            let available = isAvailable(unlock, path: path, status: status)
            return DriverUnlockPresentation(unlock: unlock, available: available,
                                            note: available ? nil : note(path: path, status: status))
        }
    }

    private static func note(path: AudioInputPath, status: DriverStatus) -> String {
        let base = DriverUnlock.needsDriverNote
        switch status {
        case .notInstalled: return base + ": install the driver, then switch to it."
        case .needsUpdate, .unknownVersion: return base + ": update the driver or the app."
        case .leaseRefused: return base + ": the driver refused the connection."
        case .installed, .inUse:
            return base + (path == .virtualDriver ? ": waiting for the driver." : ": switch to the driver above.")
        }
    }
}

/// The two parts of the delay macOS is told about, in frames at the DAC's rate.
struct DriverLatencyInputs: Equatable, Sendable {
    /// The total delay the app adds (the E31 total once E31 builds it).
    var addedDelayFrames: UInt32
    /// The DAC's own reported latency.
    var deviceLatencyFrames: UInt32

    var totalFrames: UInt32 {
        let (sum, overflow) = addedDelayFrames.addingReportingOverflow(deviceLatencyFrames)
        return overflow ? .max : sum
    }
}

/// Writes `N60_VD_PROP_LATENCY` (uint32 frames, native endianness) when the value changes.
final class DriverLatencyReporter {
    private let access: any DriverPluginAccess
    private(set) var lastWritten: UInt32?
    private(set) var writeCount = 0

    init(access: any DriverPluginAccess) { self.access = access }

    /// Returns true when a write was made. A failed write is retried on the next call.
    @discardableResult
    func report(plugIn: AudioObjectID, inputs: DriverLatencyInputs) -> Bool {
        let total = inputs.totalFrames
        guard total != lastWritten else { return false }
        var value = total
        let data = withUnsafeBytes(of: &value) { Data($0) }
        guard access.writeData(object: plugIn, selector: N60_VD_PROP_LATENCY, data: data) == noErr else { return false }
        lastWritten = total
        writeCount += 1
        return true
    }

    /// Forget the last value so the next engage writes again (the driver restarts at zero).
    func reset() { lastWritten = nil }
}
