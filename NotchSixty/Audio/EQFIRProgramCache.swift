import Foundation

// E27 S3c: prepared FIR designs for linear-phase EQ A/B.
//
// Designing a linear-phase EQ's taps is the slow part of publishing it (control plane, main
// actor). Without a cache every A/B toggle between two linear-phase slots redesigns the taps.
// This cache keeps the designed FIR of the recent configurations, keyed by the configuration and
// sample rate, so a toggle between two slots that were both designed once designs nothing: the
// engine reuses the taps, and only the cheap per-session step (kernel program transform, or the
// unified graph's own build) runs. A convolver slot is deliberately never reused for a later
// toggle: a slot that was active keeps the old input history in its runtime, so each program is
// freshly prepared (clean runtime) from the cached taps.
//
// Realtime: none of this runs on the audio thread; the render path only sees the immutable graph
// snapshot built from the taps. Allocation: control thread, when a design is stored (at most
// `designCapacity` designs are held). Synchronisation: main actor only. Latency: unchanged (the
// declared latency is stored with the taps). Sample rates: the key includes the rate, so a rate
// change misses. Channels: the stereo (or Mid/Side) tap pair the existing design produces.
// Reset: `removeAll()` on every new transport session.

/// What decides a designed EQ FIR: everything in the configuration except bypass and the page's
/// edit-lane selection, at one sample rate.
struct EQFIRProgramKey: Equatable, Sendable {
    let configuration: StereoEQConfiguration
    let sampleRate: Double

    init(_ configuration: StereoEQConfiguration, sampleRate: Double) {
        var normalised = configuration
        normalised.bypassed = false
        switch normalised.channelMode {
        case .linked: normalised.editChannel = .linked
        case .independent: normalised.editChannel = .left
        case .midSide: normalised.editChannel = .mid
        }
        self.configuration = normalised
        self.sampleRate = sampleRate
    }
}

/// A designed FIR for a configuration.
struct EQFIRDesign {
    var left: [Float]
    var right: [Float]?
    var declaredLatencyFrames: UInt32
    var designInfo: N60LinearPhaseEQDesignInfo?
}

struct EQFIRProgramCache {
    private struct Entry {
        var key: EQFIRProgramKey
        var design: EQFIRDesign
        var lastUsed: UInt64
    }

    /// Designs kept (a soft limit: a protected partner is never evicted): the live one, the A/B
    /// partner and one in-flight edit. Worst case at 384 kHz is three stereo tap pairs of float32.
    static let designCapacity = 3

    private var entries: [Entry] = []
    private var clock: UInt64 = 0
    private var protectedKey: EQFIRProgramKey?
    /// Designs actually run (a hit does not count). Tests read this; nothing else does.
    private(set) var designCount = 0

    var count: Int { entries.count }

    mutating func removeAll() {
        entries.removeAll()
        protectedKey = nil
    }

    /// Keeps the design of `key` while other entries are replaced (the A/B partner).
    mutating func protect(_ key: EQFIRProgramKey?) { protectedKey = key }

    func hasDesign(_ key: EQFIRProgramKey) -> Bool { entries.contains { $0.key == key } }

    /// The designed FIR for `key`, running `make` only on a miss.
    mutating func design(
        for key: EQFIRProgramKey, make: () throws -> EQFIRDesign
    ) rethrows -> EQFIRDesign {
        clock &+= 1
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].lastUsed = clock
            return entries[index].design
        }
        let design = try make()
        designCount += 1
        entries.append(Entry(key: key, design: design, lastUsed: clock))
        while entries.count > Self.designCapacity {
            let victims = entries.indices
                .filter { entries[$0].key != key && entries[$0].key != protectedKey }
                .sorted { entries[$0].lastUsed < entries[$1].lastUsed }
            guard let victim = victims.first else { break }
            entries.remove(at: victim)
        }
        return design
    }
}
