import Foundation

// E12 S28b1: the one audition override slot. What the engine plays instead of the stored system settings while a
// blind comparison (the room-correction ABX sheet, later the Blind Listening page) is open.
//
// Control plane only. The override chooses which plan the normal graph build publishes, so one faded republish moves
// every changed domain at once; no DSP moves to Swift. Stored configuration is never written, so a restore is "clear
// the slot and republish". Never persisted: Stop, an output change, a rate change, a session teardown and a crash all
// leave the next launch with none. Allocation: allocates (control thread). Synchronisation: none (main actor). Latency:
// `latencyPadFrames` is added to every source lane so the shorter side arrives with the longer. Sample rate: any rate
// to 384 kHz (frames, not seconds). `.off` or another lane design changes the built graph latency (convolver engine
// latency plus declared), so the pad must come from the built graphs, not the declared latencies alone. Channels: up to N60_LAYOUT_MAX_CHANNELS source lanes. Reset: `clear`.
struct AuditionOverride: Equatable, Sendable {
    /// What replaces the stored room correction.
    enum RoomCorrection: Equatable, Sendable {
        /// The stored room correction, unchanged.
        case applied
        /// No room correction at all (no FIR, so no declared latency).
        case off
        /// This lane design in place of the stored one (the ABX sheet's candidates and a saved profile's design).
        case lanes(RoomCorrectionLaneInstall)
    }

    var roomCorrection: RoomCorrection = .applied
    /// Replaces the stored bass-management configuration for the graph build; nil keeps the stored one.
    var bassManagement: BassManagementConfiguration?
    /// Output gain of this side relative to the stored one, in dB (a saved profile's different gain); nil keeps it.
    var outputGainDB: Double?
    /// Linear trim applied to the whole program (the louder side is trimmed down, so nothing clips). At most 1.
    var gain: Float = 1
    /// Frames added to every source lane (mains and subwoofers) before bass management, so both sides arrive together.
    var latencyPadFrames: UInt32 = 0

    /// The ABX sheet's override: a lane design, level trim and latency match.
    static func lanes(_ install: RoomCorrectionLaneInstall, gain: Float, latencyPadFrames: UInt32) -> AuditionOverride {
        AuditionOverride(roomCorrection: .lanes(install), gain: gain, latencyPadFrames: latencyPadFrames)
    }

    /// The linear program gain this override applies (trim and output-gain offset).
    var programGain: Float { gain * (outputGainDB.map { Float(pow(10.0, $0 / 20.0)) } ?? 1) }

    /// The lane design the override installs, or nil when it keeps or removes the stored one.
    var installedLanes: RoomCorrectionLaneInstall? {
        if case .lanes(let install) = roomCorrection { return install }
        return nil
    }

    /// False for a value the engine must refuse before building anything: a gain or total program gain above 1 (it could
    /// clip) or not finite, or a non-finite output gain.
    var isWellFormed: Bool {
        gain.isFinite && gain > 0 && gain <= 1 && (outputGainDB.map { $0.isFinite && abs($0) <= 60 } ?? true)
            && programGain <= 1
    }
}

/// Why the audition slot cannot take an override now. The reason text is the plain-words line a page shows.
enum AuditionOverrideError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case malformed
    case padTooLong

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .malformed: return "The comparison settings are not valid."
        case .padTooLong: return "The two sides differ in delay by more than the engine can match."
        }
    }
}
