import Foundation

// E26 S2b: sweep settings for measuring through the whole feed. Pure control-plane maths, no engine access.
//
// With a sub or bass management in the path, the leakage and secondary-path sweeps must start below the sub band
// (15 Hz), be long enough to put usable energy into 15-125 Hz, and leave a tail that covers the sub's low-pass delay
// and the room's ring. Specified in seconds and hertz, so the plan is the same at every device rate.

enum ThroughFeedSweepPlanner {
    static let startFrequencyHz = 15.0
    /// A log sweep spends 1/log2(fmax/fmin) of its time per octave; 12 s over about 10.4 octaves gives about 1.1 s per
    /// octave, enough for the sub octaves to rise above the room noise after the repeats are averaged.
    static let minimumSubSweepSeconds = 12.0
    static let minimumSubTailSeconds = 2.0
    static let minimumLeadInSeconds = 0.5

    /// The settings for a sweep played through `path`. A path without a sub keeps `base` unchanged.
    static func settings(
        base: RoomCorrectionSweepSettings, path: AncBassPath, sampleRate: Double
    ) -> RoomCorrectionSweepSettings {
        var settings = base
        settings.sampleRate = sampleRate
        guard path.hasSubwooferForAnc else { return settings }
        settings.startFrequencyHz = min(base.startFrequencyHz, startFrequencyHz)
        settings.durationSeconds = max(base.durationSeconds, minimumSubSweepSeconds)
        settings.tailSeconds = max(base.tailSeconds, minimumSubTailSeconds)
        settings.leadInSeconds = max(base.leadInSeconds, minimumLeadInSeconds)
        return settings
    }
}
