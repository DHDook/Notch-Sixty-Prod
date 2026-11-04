import Foundation

// E25 S7: fold-down of a wider program (3.1, 5.1, 7.1 and the height layouts) to the two feeds of a two-channel system.
// Pure, control-plane and rate-free: it produces a ROUTE matrix and a source-device decision, and starts nothing. The
// speaker output stays on the stereo session, so Quiet Zone and every stereo-session feature survive. The transport
// that captures the wider source and applies this matrix is carried to the slice named in the E25 plan.
// Coefficients: ITU-R BS.775-3 (Recommendation, multichannel stereophonic sound), section on downmixing 3/2 to 2/0:
//   Lo = L + k1*C + k2*Ls,  Ro = R + k1*C + k2*Rs,  with k1 = k2 = 1/sqrt(2) (-3 dB).
// Side and rear surrounds both use k2. Wide and height channels are not covered by BS.775; they fold onto the
// same-side channel at -3 dB (heights onto the front or surround path), documented here as this app's own extension.

/// What happens to the LFE channel when the program is folded.
enum FoldDownLFEMode: String, Codable, CaseIterable, Sendable {
    /// ITU default: the LFE channel is not folded.
    case drop
    /// LFE joins both feeds at +10 dB (the cinema LFE playback offset). It needs a limiter, or `peakSafe` headroom.
    case foldPlus10dBWithLimiter
}

/// How the folded sum is kept inside full scale.
enum FoldDownHeadroom: String, Codable, CaseIterable, Sendable {
    /// ITU coefficients unchanged. Correlated full-scale input can exceed full scale; the output stage limits.
    case none
    /// Every row is scaled so that the worst-case sum of absolute coefficients is 1: no input can clip.
    case peakSafe
}

/// The user's fold-down choice, stored additively on `SystemArrangement.foldDown`.
struct ProgramFoldDown: Codable, Equatable, Sendable {
    /// The device that carries the wider program (the pattern `HeadphoneDeviceProfileConfiguration` uses). nil: no wider
    /// source, so the player or macOS folds upstream and this configuration does nothing.
    var programSourceDeviceUID: String?
    var lfe: FoldDownLFEMode = .drop
    var headroom: FoldDownHeadroom = .none

    static let surroundGain = 0.5.squareRoot()      // 1/sqrt(2), -3 dB
    static let lfeFoldGain = pow(10.0, 10.0 / 20.0) // +10 dB
    static let limiterCeilingDB = -1.0

    var isActive: Bool { programSourceDeviceUID != nil }
}

/// One row (a feed) of the fold-down matrix: gains by program channel index.
struct FoldDownRow: Equatable, Sendable {
    var gains: [Double]
    /// Worst-case output for full-scale input on every channel with matching sign.
    var absoluteSum: Double { gains.reduce(0) { $0 + abs($1) } }
}

struct FoldDownMatrix: Equatable, Sendable {
    var layout: OutputProgramLayout
    var left: FoldDownRow
    var right: FoldDownRow
    /// A limiter is required behind the matrix: the sum can exceed full scale and headroom is not `peakSafe`.
    var needsLimiter: Bool

    func gain(feed: Int, role: OutputProgramRole) -> Double {
        guard let index = layout.roles.firstIndex(of: role) else { return 0 }
        return (feed == 0 ? left : right).gains[index]
    }

    /// The `ROUTE` entries for the two feeds, in the form `SpeakerRoutingCompiler` uses (lane = firstLane + feed).
    /// nil when a feed would need more than `N60_ROUTE_MAX_ENTRIES` entries (9.1.6 with the LFE folded).
    func outputLanes(firstLane: Int) -> [UnifiedGraphOutputLane]? {
        let limit = Int(N60_ROUTE_MAX_ENTRIES)
        guard [left, right].allSatisfy({ $0.gains.filter { $0 != 0 }.count <= limit }) else { return nil }
        return [left, right].enumerated().map { feed, row in
            UnifiedGraphOutputLane(
                lane: firstLane + feed,
                entries: row.gains.enumerated().filter { $0.element != 0 }
                    .map { UnifiedGraphRouteEntry(source: $0.offset, gain: Float($0.element)) },
                crossover: nil, delayFrames: 0, protection: nil, driverFIR: nil)
        }
    }

    /// The output limiter the matrix needs, or nil. Time constants are in milliseconds, so the frame counts follow the
    /// device rate (`lookAheadMilliseconds * rate / 1000`) and the behaviour is the same at every rate.
    var protection: UnifiedGraphProtection? {
        guard needsLimiter else { return nil }
        return UnifiedGraphProtection(
            limiterEnabled: true, ceilingDB: ProgramFoldDown.limiterCeilingDB, attackMilliseconds: 1,
            releaseMilliseconds: 100, lookAheadMilliseconds: 1, truePeakGuard: true, oversampling: 4,
            clipper: nil, rider: nil)
    }
}

enum ProgramFoldDownCompiler {
    /// nil when the layout is already two channels: nothing to fold.
    static func compile(layout: OutputProgramLayout, foldDown: ProgramFoldDown) -> FoldDownMatrix? {
        guard layout != .stereo else { return nil }
        let k = ProgramFoldDown.surroundGain
        let roles = layout.roles
        var left = [Double](repeating: 0, count: roles.count)
        var right = left
        for (i, role) in roles.enumerated() {
            switch role {
            case .frontLeft: left[i] = 1
            case .frontRight: right[i] = 1
            case .frontCenter: left[i] = k; right[i] = k
            case .lowFrequencyEffects:
                if foldDown.lfe == .foldPlus10dBWithLimiter {
                    left[i] = ProgramFoldDown.lfeFoldGain; right[i] = ProgramFoldDown.lfeFoldGain
                }
            case .sideLeft, .rearLeft: left[i] = k
            case .sideRight, .rearRight: right[i] = k
            case .wideLeft, .topFrontLeft: left[i] = k
            case .wideRight, .topFrontRight: right[i] = k
            case .topMiddleLeft, .topRearLeft: left[i] = k * k
            case .topMiddleRight, .topRearRight: right[i] = k * k
            }
        }
        var rowL = FoldDownRow(gains: left)
        var rowR = FoldDownRow(gains: right)
        let worst = max(rowL.absoluteSum, rowR.absoluteSum)
        if foldDown.headroom == .peakSafe, worst > 1 {
            rowL.gains = rowL.gains.map { $0 / worst }
            rowR.gains = rowR.gains.map { $0 / worst }
        }
        let limiter = foldDown.headroom == .none && max(rowL.absoluteSum, rowR.absoluteSum) > 1 + 1e-12
        return FoldDownMatrix(layout: layout, left: rowL, right: rowR, needsLimiter: limiter)
    }
}

/// Where the wider program comes from. The selected output stays authoritative: a source that disappears is waited
/// for, never replaced by another device.
enum ProgramSourceResolution: Equatable, Sendable {
    /// No wider source configured or the program is stereo: the player or macOS folds upstream.
    case upstreamFold
    case source(uid: String)
    /// The configured source is absent. Recovery waits for the same stable UID; there is no fallback.
    case waitForDevice(uid: String)
    case channelCountMismatch(expected: Int, actual: Int)
    case sampleRateUnsupported(Double)
}

extension ProgramFoldDown {
    func resolveSource(
        layout: OutputProgramLayout, availableDevices: [AudioOutputDevice], sampleRate: Double
    ) -> ProgramSourceResolution {
        guard let uid = programSourceDeviceUID, layout != .stereo else { return .upstreamFold }
        guard let device = availableDevices.first(where: { $0.uid == uid }) else { return .waitForDevice(uid: uid) }
        let expected = layout.roles.count
        guard Int(device.outputChannelCount) == expected else {
            return .channelCountMismatch(expected: expected, actual: Int(device.outputChannelCount))
        }
        guard device.supports(sampleRate: sampleRate) else { return .sampleRateUnsupported(sampleRate) }
        return .source(uid: uid)
    }
}

// MARK: - E25 S8a: the plan the engine applies, channel-order mapping and the protection merge

/// Why a fold cannot run. Shown on the Speakers tab (S8b).
enum ProgramFoldDownError: Error, Equatable, LocalizedError, Sendable {
    case sourceUnavailable(uid: String)
    case channelCountMismatch(expected: Int, actual: Int)
    case sampleRateUnsupported(Double)
    case sourceChannelLayoutUnresolved
    case incompatibleOutput(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let uid):
            return "Waiting for the program source device (\(uid)) to return."
        case .channelCountMismatch(let expected, let actual):
            return "The program source has \(actual) channels but the program layout needs \(expected)."
        case .sampleRateUnsupported(let rate):
            return "The program source does not offer the output's sample rate (\(Int(rate)) Hz); the fold never resamples."
        case .sourceChannelLayoutUnresolved:
            return "The program source does not label its channels, so the fold cannot place them."
        case .incompatibleOutput(let reason):
            return "A wider program source cannot be folded with \(reason)."
        }
    }
}

/// What the engine needs to tap a wider source and fold it onto the two feeds: the source UID, the layout and the
/// compiled matrix. nil for a stereo layout or with no source configured (the player or macOS folds upstream).
struct ProgramFoldDownPlan: Equatable, Sendable {
    var foldDown: ProgramFoldDown
    var layout: OutputProgramLayout
    var matrix: FoldDownMatrix

    init?(layout: OutputProgramLayout, foldDown: ProgramFoldDown) {
        guard foldDown.isActive, let matrix = ProgramFoldDownCompiler.compile(layout: layout, foldDown: foldDown) else {
            return nil
        }
        self.foldDown = foldDown
        self.layout = layout
        self.matrix = matrix
    }

    var sourceUID: String { foldDown.programSourceDeviceUID ?? "" }

    /// A fold runs on the stereo session only. These are the setups that cannot host it.
    static func incompatibility(sameDeviceOrAggregateOutput: Bool, headphoneProfileEnabled: Bool) -> ProgramFoldDownError? {
        if sameDeviceOrAggregateOutput { return .incompatibleOutput("a same-device or multi-device output plan") }
        if headphoneProfileEnabled { return .incompatibleOutput("a headphone profile") }
        return nil
    }

    /// The decision `buildStereoTransport` acts on.
    enum BuildDecision: Equatable, Sendable {
        case standard
        case tapSource(AudioOutputDevice)
        case waitForSource(uid: String)
        case refuse(ProgramFoldDownError)
    }

    static func buildDecision(
        plan: ProgramFoldDownPlan?, availableDevices: [AudioOutputDevice], sampleRate: Double
    ) -> BuildDecision {
        guard let plan else { return .standard }
        switch plan.foldDown.resolveSource(layout: plan.layout, availableDevices: availableDevices, sampleRate: sampleRate) {
        case .upstreamFold: return .standard
        case .source(let uid):
            guard let device = availableDevices.first(where: { $0.uid == uid }) else { return .waitForSource(uid: uid) }
            return .tapSource(device)
        case .waitForDevice(let uid): return .waitForSource(uid: uid)
        case .channelCountMismatch(let expected, let actual): return .refuse(.channelCountMismatch(expected: expected, actual: actual))
        case .sampleRateUnsupported(let rate): return .refuse(.sampleRateUnsupported(rate))
        }
    }
}

extension OutputProgramRole {
    init?(realtime role: N60ProgramChannelRole) {
        guard let match = OutputProgramRole.allCases.first(where: { $0.realtimeCType == role }) else { return nil }
        self = match
    }
}

extension FoldDownMatrix {
    /// The two rows reordered into the source device's channel order. `streamRoles[i]` is the role of device channel
    /// `i`. nil unless the stream carries exactly the layout's roles, once each: the fold never guesses a channel.
    func deviceOrderGains(streamRoles: [OutputProgramRole]) -> (left: [Float], right: [Float])? {
        guard streamRoles.count == layout.roles.count, Set(streamRoles) == Set(layout.roles),
              Set(streamRoles).count == streamRoles.count else { return nil }
        let left = streamRoles.map { Float(gain(feed: 0, role: $0)) }
        let right = streamRoles.map { Float(gain(feed: 1, role: $0)) }
        return (left, right)
    }
}

extension DynamicsConfiguration {
    /// Merges the fold's output limiter into the user's protection settings, taking the stricter of each setting
    /// (E25 S8a decision 3). A matrix that needs no limiter (`peakSafe`, or LFE dropped) leaves them unchanged.
    func mergingFoldProtection(_ matrix: FoldDownMatrix?) -> DynamicsConfiguration {
        guard let matrix, matrix.needsLimiter else { return self }
        var merged = self
        let userLimiterOn = limiter.enabled
        merged.limiter.enabled = true
        merged.limiter.ceilingDB = Swift.min(limiter.ceilingDB, ProgramFoldDown.limiterCeilingDB)
        merged.limiter.truePeakGuardEnabled = true
        merged.oversampling = OversamplingFactor.four
        if !userLimiterOn {
            merged.limiter.attackMs = 1
            merged.limiter.releaseMs = 100
            merged.limiter.lookAheadMs = 1
        }
        return merged
    }
}
