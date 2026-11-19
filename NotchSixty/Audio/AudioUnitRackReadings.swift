import Foundation

// E33 S24 (`e33.page-enhancements`): the Plugins page readings and the rack-level controls, as plain values so they are
// testable without a view. Control plane only; nothing here runs on the render thread except `AudioUnitLoadReading.units`,
// a pure arithmetic helper.

/// One plug-in's render load since the last read: the largest render time as a fraction of the buffer's time budget, and as a
/// fraction of the watchdog's cut-out budget (`AudioUnitLiveRenderWatchdog`).
struct AudioUnitLoadReading: Equatable, Sendable {
    static let unitsPerOne = 10_000.0
    /// Largest value stored: 40x, far past the watchdog's budget.
    static let maximumUnits: UInt32 = 400_000

    var bufferLoad: Double
    var watchdogLoad: Double

    static let idle = AudioUnitLoadReading(bufferLoad: 0, watchdogLoad: 0)

    /// Fixed-point conversion for the atomic store. Clamps, and maps NaN or negative values to 0.
    static func units(_ fraction: Double) -> UInt32 {
        guard fraction.isFinite, fraction > 0 else { return 0 }
        let scaled = fraction * unitsPerOne
        return scaled >= Double(maximumUnits) ? maximumUnits : UInt32(scaled)
    }
}

enum AudioUnitLoadLevel: Equatable, Sendable {
    case idle
    case normal
    /// Render time is above most of the buffer's time budget.
    case high
    /// Render time is close to the watchdog's cut-out budget: the plug-in is about to be taken out of the rack.
    case nearCutOut
}

struct AudioUnitLoadDisplay: Equatable, Sendable {
    static let highBufferLoad = 0.75
    /// Warn at half the watchdog's budget, well before three overruns in a row cut the plug-in out.
    static let warnWatchdogLoad = 0.5

    let percentOfBuffer: Int?
    let level: AudioUnitLoadLevel
    let text: String
    let warning: String?

    init(_ reading: AudioUnitLoadReading?) {
        guard let reading, reading.bufferLoad > 0 else {
            percentOfBuffer = nil
            level = .idle
            text = "Load: no reading"
            warning = nil
            return
        }
        let percent = Int((reading.bufferLoad * 100).rounded())
        percentOfBuffer = percent
        text = "Load \(percent)%"
        if reading.watchdogLoad >= Self.warnWatchdogLoad {
            level = .nearCutOut
            warning = "This plug-in is taking so long that it may be taken out of the rack. Raise the buffer size or bypass it."
        } else if reading.bufferLoad >= Self.highBufferLoad {
            level = .high
            warning = "This plug-in uses most of the time available for each buffer."
        } else {
            level = .normal
            warning = nil
        }
    }
}

enum AudioUnitLatencyDisplay {
    /// "12.50 ms", or "none" for a plug-in that adds no delay.
    static func milliseconds(frames: Int, sampleRate: Double) -> String {
        guard frames > 0 else { return "none" }
        guard sampleRate > 0 else { return "\(frames) frames" }
        return String(format: "%.2f ms", Double(frames) / sampleRate * 1_000)
    }
}

/// Whole-rack bypass. Every occupied slot is bypassed through the normal rack transaction; a bypassed slot keeps its
/// latency (`AudioUnitLiveBypassStage`), so the rack's delay, and so level and timing, do not change.
enum AudioUnitRackBypass {
    static func isBypassed(_ configuration: AudioUnitRackConfiguration) -> Bool {
        let occupied = configuration.slots.filter { !$0.isEmpty }
        return !occupied.isEmpty && occupied.allSatisfy(\.bypassed)
    }

    /// The configuration with every occupied slot bypassed, and each slot's earlier bypass flag by slot id.
    static func bypassing(
        _ configuration: AudioUnitRackConfiguration
    ) -> (configuration: AudioUnitRackConfiguration, saved: [UUID: Bool]) {
        var updated = configuration
        var saved: [UUID: Bool] = [:]
        for index in updated.slots.indices where !updated.slots[index].isEmpty {
            saved[updated.slots[index].id] = updated.slots[index].bypassed
            updated.slots[index].bypassed = true
        }
        return (updated, saved)
    }

    /// Puts each slot back as it was. A slot with no saved flag (the rack was bypassed in an earlier session) is switched on.
    static func restoring(
        _ configuration: AudioUnitRackConfiguration,
        saved: [UUID: Bool]
    ) -> AudioUnitRackConfiguration {
        var updated = configuration
        for index in updated.slots.indices where !updated.slots[index].isEmpty {
            updated.slots[index].bypassed = saved[updated.slots[index].id] ?? false
        }
        return updated
    }
}

/// Drag to reorder. The same `move(from:to:)` mutation the Move buttons use, so the order is identical.
enum AudioUnitRackDrag {
    static func mutation(
        draggedID: UUID,
        onto targetID: UUID,
        in configuration: AudioUnitRackConfiguration
    ) -> AudioUnitRackMutation? {
        guard draggedID != targetID,
              let from = configuration.slots.firstIndex(where: { $0.id == draggedID }),
              let to = configuration.slots.firstIndex(where: { $0.id == targetID }) else { return nil }
        return .move(from: from, to: to)
    }
}

/// Plain catalog wording: why a plug-in cannot be used, and what to do about it.
struct AudioUnitCatalogReason: Equatable, Sendable {
    let reason: String
    let advice: String
    var text: String { "\(reason) \(advice)" }
}

enum AudioUnitCatalogReasons {
    /// One entry per rejection reason, in a fixed order. Empty for a compatible plug-in with no quarantine.
    static func reasons(
        for descriptor: AudioUnitComponentDescriptor,
        format: AudioUnitRackProcessingFormat,
        separateProcess: Bool = AudioUnitLoadingPolicy.separateProcessEnabled,
        quarantine: AudioUnitQuarantineEntry? = nil
    ) -> [AudioUnitCatalogReason] {
        var result: [AudioUnitCatalogReason] = []
        if descriptor.kind == .unsupported {
            result.append(AudioUnitCatalogReason(
                reason: "This is not an audio effect.",
                advice: "Notch Sixty hosts effects only; instruments and generators are not used."
            ))
        }
        if !descriptor.passesAUVal {
            result.append(AudioUnitCatalogReason(
                reason: "macOS's Audio Unit validation does not pass this plug-in.",
                advice: "Update the plug-in, or ask its maker for a version that passes validation."
            ))
        }
        if !descriptor.sandboxSafe, !separateProcess {
            result.append(AudioUnitCatalogReason(
                reason: "This plug-in is not marked safe to run inside Notch Sixty's sandbox.",
                advice: "Turn on the page enhancements so it can load in its own process, or use a sandbox-safe version."
            ))
        }
        if !descriptor.supports(channelCount: format.channelCount) {
            result.append(AudioUnitCatalogReason(
                reason: "This plug-in does not handle \(format.channelCount) channels.",
                advice: format.channelCount == 2
                    ? "It needs a stereo version."
                    : "Only plug-ins that process this many channels the same on every channel can be used on this session."
            ))
        }
        if let quarantine, result.isEmpty {
            result.append(quarantineReason(for: descriptor, entry: quarantine))
        }
        return result
    }

    /// The sandbox-safe rule still applies (owner, 18 Nov 2026) to a plug-in that is not marked safe and that macOS would
    /// not load in its own process.
    static func quarantineReason(
        for descriptor: AudioUnitComponentDescriptor,
        entry: AudioUnitQuarantineEntry
    ) -> AudioUnitCatalogReason {
        if !descriptor.sandboxSafe,
           entry.reason == .instantiationFailed || entry.reason == .sandboxUnsafe {
            return AudioUnitCatalogReason(
                reason: "The sandbox-safe rule still applies to this plug-in: macOS would not load it in its own process inside Notch Sixty's sandbox.",
                advice: "Ask the plug-in's maker for a sandbox-safe version."
            )
        }
        if entry.reason == .processStopped {
            return AudioUnitCatalogReason(
                reason: "The plug-in's own process stopped while playing, so it was taken out of the rack.",
                advice: "Clear the quarantine to try it again."
            )
        }
        return AudioUnitCatalogReason(
            reason: entry.lastFailureDescription,
            advice: "Clear the quarantine to try it again."
        )
    }

    /// The catalog hides what cannot be used unless the switch is on.
    static func visible(
        _ descriptors: [AudioUnitComponentDescriptor],
        format: AudioUnitRackProcessingFormat,
        showIncompatible: Bool,
        separateProcess: Bool = AudioUnitLoadingPolicy.separateProcessEnabled
    ) -> [AudioUnitComponentDescriptor] {
        showIncompatible
            ? descriptors
            : descriptors.filter {
                $0.compatibility(for: format, separateProcess: separateProcess).compatible
            }
    }
}
