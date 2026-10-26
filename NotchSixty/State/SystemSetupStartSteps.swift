import Foundation

// E12 S3: pure logic behind the first steps of the guided setup (Output, Topology, Microphone and
// level). No SwiftUI, no engine, nothing here runs on an audio thread; the flow view feeds these
// values to the existing profile and generator paths. Gated by `e12.guided-setup` at the call sites.

// MARK: - Topology presets (design note 4)

/// What the Topology step writes. Today's routing supports a stereo pair with an optional
/// bass-managed subwoofer; E8 replaces the crossover controls, the contract (a bass-management
/// configuration) stays.
struct SystemSetupTopologyPreset: Equatable, Sendable {
    static let crossoverRangeHz = BassManagementConfiguration.frequencyRange
    static let defaultCrossoverHz = 80.0
    static let defaultSlope: CrossoverTopology = .linkwitzRiley24

    var topology: SystemSetupTopology
    var crossoverHz = SystemSetupTopologyPreset.defaultCrossoverHz
    var slope: CrossoverTopology = SystemSetupTopologyPreset.defaultSlope

    var title: String {
        switch topology {
        case .stereo: return "2.0 stereo speakers"
        case .twoPointOne: return "2.1 stereo speakers and one subwoofer"
        case .twoPointTwo: return "2.2 stereo speakers and two subwoofers"
        }
    }

    /// Returns `state` with the preset's bass management applied. Nothing else is touched; in
    /// particular no routing, correction, ANC or Active Acoustics setting changes.
    func applying(to state: PlaybackSystemState) -> PlaybackSystemState {
        var next = state
        var bass = state.bassManagement
        if topology.hasSubwoofer {
            bass.enabled = true
            bass.physicalOutputMode = .mainsSub
            bass.frequencyHz = min(max(crossoverHz, Self.crossoverRangeHz.lowerBound), Self.crossoverRangeHz.upperBound)
            bass.topology = slope
        } else {
            bass.enabled = false
            bass.physicalOutputMode = nil
        }
        next.bassManagement = bass
        return next
    }

    /// The topology a state already describes, for pre-filling the step.
    static func current(from state: PlaybackSystemState) -> SystemSetupTopologyPreset {
        let bass = state.bassManagement
        guard bass.enabled else { return SystemSetupTopologyPreset(topology: .stereo) }
        return SystemSetupTopologyPreset(topology: .twoPointOne, crossoverHz: bass.frequencyHz, slope: bass.topology)
    }
}

// MARK: - Level plan (design note 5)

/// Safe level ramp for the Level step: band-limited pink noise from the E11 generator, starting at
/// -40 dBFS, raised only on user request, never above the generator ceiling.
struct SystemSetupLevelPlan: Equatable, Sendable {
    static let startLevelDB = -40.0
    static let rampStepDB = 3.0
    static let targetSPLdBC = 75.0
    static let minimumSweepLevelDB = -60.0

    /// The LFE channel starts lower and is band-limited to bass (E12 S4a).
    static let lfeStartLevelDB = -50.0
    static let lfeHighHz = 120.0

    private(set) var levelDB = SystemSetupLevelPlan.startLevelDB
    /// Which program lanes the noise plays on. Default: every lane except the LFE.
    private(set) var target: SignalGeneratorLaneSelection = .allProgram(includeLFE: false)
    private(set) var targetIsLFE = false
    /// The level the user settled on for each single lane (informational; the sweep level comes from the SPL reading).
    private(set) var recordedLevelsDB: [Int: Double] = [:]

    /// True when the noise reaches the LFE together with other lanes. One parameter set serves every lane, so this
    /// pass is full band at the LFE-safe level and the UI must warn that full-band noise goes to the sub.
    var showsFullBandLFEWarning: Bool {
        if case .allProgram(let includeLFE) = target { return includeLFE }
        return false
    }

    private var startLevelForTarget: Double {
        (targetIsLFE || showsFullBandLFEWarning) ? Self.lfeStartLevelDB : Self.startLevelDB
    }

    /// Switches the noise to another lane (or all lanes) and drops back to that target's starting level, or the level
    /// already recorded for that lane. Never carries a raised level onto a new channel.
    mutating func selectTarget(_ newTarget: SignalGeneratorLaneSelection, isLFE: Bool) {
        target = newTarget
        targetIsLFE = isLFE
        if case .lane(let lane) = newTarget, let recorded = recordedLevelsDB[lane] {
            levelDB = min(recorded, Self.ceilingDB)
        } else {
            levelDB = startLevelForTarget
        }
    }

    /// Remembers the current level for the selected lane.
    mutating func recordLevel() {
        if case .lane(let lane) = target { recordedLevelsDB[lane] = levelDB }
    }

    /// The generator's own ceiling (never above -6 dBFS).
    static var ceilingDB: Double { SignalGeneratorSettings.hardCeilingDB }

    var atCeiling: Bool { levelDB >= Self.ceilingDB }

    /// One user-requested step up; stops at the ceiling.
    mutating func raise() {
        levelDB = min(levelDB + Self.rampStepDB, Self.ceilingDB)
    }

    mutating func lower() {
        levelDB = max(levelDB - Self.rampStepDB, Self.minimumSweepLevelDB)
    }

    mutating func reset() { levelDB = startLevelForTarget }

    /// Generator settings for the current level: band-limited pink noise at the ceiling-clamped level.
    func generatorSettings(sampleRate: Double = 48_000) -> SignalGeneratorSettings {
        var settings = SignalGeneratorSettings()
        settings.highHz = min(settings.highHz, 0.45 * sampleRate)
        settings.kind = .bandLimitedPink
        if targetIsLFE { settings.highHz = min(settings.highHz, Self.lfeHighHz) }
        settings.levelDB = levelDB
        settings.ceilingDB = Self.ceilingDB
        return settings
    }

    /// The sweep level that would give about `targetSPLdBC` at the main seat, from a C-weighted SPL
    /// reading taken while the noise played at the current level. Clamped to the ceiling and floor.
    func sweepLevel(measuredSPLdBC: Double, targetSPLdBC: Double = SystemSetupLevelPlan.targetSPLdBC) -> Double {
        guard measuredSPLdBC.isFinite else { return levelDB }
        let wanted = levelDB + (targetSPLdBC - measuredSPLdBC)
        return min(max(wanted, Self.minimumSweepLevelDB), Self.ceilingDB)
    }
}

// MARK: - Entry points (design note 10)

enum SystemSetupEntryPolicy {
    enum Availability: Equatable, Sendable {
        /// Flag off or nothing to offer.
        case hidden
        /// Headphone outputs are pointed at the Headphones workspace instead.
        case headphonesPointer
        case offer
    }

    static func isHeadphoneOutput(name: String?, uid: String?, state: PlaybackSystemState?) -> Bool {
        if let profile = state?.headphoneDeviceProfile, profile.enabled,
           profile.outputDeviceUID == nil || profile.outputDeviceUID == uid {
            return true
        }
        let lowered = (name ?? "").lowercased()
        return ["headphone", "airpods", "earbuds", "earphone", "buds", "headset"].contains { lowered.contains($0) }
    }

    /// Whether the "Set up my system" card shows for the selected output.
    static func availability(
        flagEnabled: Bool,
        outputName: String?,
        outputUID: String?,
        state: PlaybackSystemState?,
        calibration: SystemCalibrationStatus
    ) -> Availability {
        guard flagEnabled, outputUID != nil else { return .hidden }
        if isHeadphoneOutput(name: outputName, uid: outputUID, state: state) { return .headphonesPointer }
        if case .verified = calibration { return .hidden }
        return .offer
    }
}
