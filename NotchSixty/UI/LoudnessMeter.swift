import Foundation

// E28 S2: ITU-R BS.1770-4 / EBU R128 loudness.
//
// Public sources: ITU-R BS.1770-4 (K-weighting, channel weights, gating),
// EBU Tech 3341 (momentary / short-term / integrated, -70 LUFS and -10 LU
// gates) and EBU Tech 3342 (loudness range, -70 LUFS and -20 LU gates, 10th to
// 95th percentile). Everything here runs on the analysis worker, never on the
// audio callback: it allocates freely and takes no part in the render path.

// MARK: - Channel positions

/// Semantic position of one metered channel, enough to choose the BS.1770-4
/// Table 3 weight. Azimuth is the absolute angle from the centre line (the
/// sign does not matter); elevation is in degrees above the ear plane.
struct LoudnessChannelPosition: Equatable, Sendable {
    var azimuthDegrees: Double
    var elevationDegrees: Double
    var isLFE: Bool

    /// BS.1770-4 Table 3: 1.0 for L, R, C and any channel within 60 degrees of
    /// the centre line or elevated 30 degrees or more; 1.41 (+1.5 dB) for
    /// channels beside and behind the listener below 30 degrees elevation; LFE
    /// is excluded.
    var weight: Double {
        if isLFE { return 0 }
        if abs(elevationDegrees) >= 30 { return 1 }
        return abs(azimuthDegrees) > 60 ? Self.surroundWeight : 1
    }

    static let surroundWeight = 1.41

    static let left = LoudnessChannelPosition(azimuthDegrees: 30, elevationDegrees: 0, isLFE: false)
    static let right = LoudnessChannelPosition(azimuthDegrees: 30, elevationDegrees: 0, isLFE: false)
    static let centre = LoudnessChannelPosition(azimuthDegrees: 0, elevationDegrees: 0, isLFE: false)
    static let lfe = LoudnessChannelPosition(azimuthDegrees: 0, elevationDegrees: 0, isLFE: true)
    static let leftSurround = LoudnessChannelPosition(azimuthDegrees: 110, elevationDegrees: 0, isLFE: false)
    static let rightSurround = LoudnessChannelPosition(azimuthDegrees: 110, elevationDegrees: 0, isLFE: false)
    static let leftRearSurround = LoudnessChannelPosition(azimuthDegrees: 135, elevationDegrees: 0, isLFE: false)
    static let rightRearSurround = LoudnessChannelPosition(azimuthDegrees: 135, elevationDegrees: 0, isLFE: false)
    static let leftHeight = LoudnessChannelPosition(azimuthDegrees: 30, elevationDegrees: 45, isLFE: false)
    static let rightHeight = LoudnessChannelPosition(azimuthDegrees: 30, elevationDegrees: 45, isLFE: false)
    static let leftRearHeight = LoudnessChannelPosition(azimuthDegrees: 135, elevationDegrees: 45, isLFE: false)
    static let rightRearHeight = LoudnessChannelPosition(azimuthDegrees: 135, elevationDegrees: 45, isLFE: false)

    static let stereo: [LoudnessChannelPosition] = [.left, .right]
}

// MARK: - K-weighting

struct LoudnessBiquad: Equatable, Sendable {
    var b0: Double, b1: Double, b2: Double
    var a1: Double, a2: Double
    private var z1 = 0.0
    private var z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    /// Magnitude of the transfer function at `frequency`.
    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return (nr * nr + ni * ni).squareRoot() / (dr * dr + di * di).squareRoot()
    }
}

/// The two-stage K-weighting filter (high shelf, then RLB high-pass) designed
/// for any sample rate by bilinear transform of the analogue prototypes. The
/// prototype parameters reproduce the BS.1770-4 coefficients published for
/// 48 kHz to better than 1e-9.
struct KWeightingFilter: Equatable, Sendable {
    static let shelfFrequency = 1681.974450955533
    static let shelfGainDB = 3.999843853973347
    static let shelfQ = 0.7071752369554196
    static let highPassFrequency = 38.13547087602444
    static let highPassQ = 0.5003270373238773

    private(set) var shelf: LoudnessBiquad
    private(set) var highPass: LoudnessBiquad

    init(sampleRate: Double) {
        let rate = max(sampleRate, 8_000)
        var k = tan(Double.pi * Self.shelfFrequency / rate)
        let vh = pow(10, Self.shelfGainDB / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / Self.shelfQ + k * k
        shelf = LoudnessBiquad(
            b0: (vh + vb * k / Self.shelfQ + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / Self.shelfQ + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / Self.shelfQ + k * k) / a0
        )
        k = tan(Double.pi * Self.highPassFrequency / rate)
        a0 = 1 + k / Self.highPassQ + k * k
        highPass = LoudnessBiquad(
            b0: 1, b1: -2, b2: 1,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / Self.highPassQ + k * k) / a0
        )
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        highPass.process(shelf.process(x))
    }

    mutating func reset() { shelf.reset(); highPass.reset() }

    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        shelf.magnitude(at: frequency, sampleRate: sampleRate)
            * highPass.magnitude(at: frequency, sampleRate: sampleRate)
    }
}

// MARK: - Readout

struct LoudnessReadout: Equatable, Sendable {
    /// LUFS; nil until the window has filled (0.4 s, 3 s) or while it is silent.
    var momentary: Double?
    var shortTerm: Double?
    /// Gated integrated loudness; nil until a block passes the absolute gate.
    var integrated: Double?
    /// Loudness range in LU (EBU Tech 3342); nil until a window passes the gates.
    var range: Double?
    var momentaryMax: Double?
    var shortTermMax: Double?
    /// Capture frames were lost while integrating, so the value may be low.
    var isGapped: Bool
    /// Seconds of audio included in the integrated measurement.
    var measuredSeconds: Double

    static let empty = LoudnessReadout(
        momentary: nil, shortTerm: nil, integrated: nil, range: nil,
        momentaryMax: nil, shortTermMax: nil, isGapped: false, measuredSeconds: 0
    )
}

// MARK: - Meter

/// Multichannel BS.1770-4 loudness meter. Audio is cut into 100 ms sub-blocks;
/// a 400 ms gating block (75 % overlap) is the mean of the last four and a 3 s
/// short-term window the mean of the last thirty.
struct LoudnessMeter {
    static let offsetLU = -0.691
    static let absoluteGateLUFS = -70.0
    static let integratedRelativeGateLU = -10.0
    static let rangeRelativeGateLU = -20.0
    static let momentarySubBlocks = 4
    static let shortTermSubBlocks = 30
    /// The integrated and range histories keep the most recent 24 hours.
    static let maxHistory = 24 * 3_600 * 10

    let sampleRate: Double
    let channels: [LoudnessChannelPosition]
    let subBlockFrames: Int

    private var filters: [KWeightingFilter]
    private let weights: [Double]
    private var fill = 0
    private var sum = 0.0
    private var ring = [Double](repeating: 0, count: LoudnessMeter.shortTermSubBlocks)
    private var ringIndex = 0
    private var ringCount = 0
    private var blockPowers: [Double] = []
    private var shortTermPowers: [Double] = []
    private var momentaryMaxPower = 0.0
    private var shortTermMaxPower = 0.0
    private var gapped = false
    private var currentMomentaryPower: Double?
    private var currentShortTermPower: Double?
    private var cachedIntegrated: Double?
    private var cachedRange: Double?
    private var cachedAtCount = -1

    init(sampleRate: Double, channels: [LoudnessChannelPosition] = LoudnessChannelPosition.stereo) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.subBlockFrames = max(Int((sampleRate * 0.1).rounded()), 1)
        self.filters = channels.map { _ in KWeightingFilter(sampleRate: sampleRate) }
        self.weights = channels.map(\.weight)
    }

    static func loudness(power: Double) -> Double {
        offsetLU + 10 * log10(power)
    }

    static func power(loudness: Double) -> Double {
        pow(10, (loudness - offsetLU) / 10)
    }

    /// Feeds equal-length planar channel buffers, one per configured channel.
    mutating func process(_ buffers: [UnsafeBufferPointer<Float>]) {
        guard buffers.count == channels.count else { return }
        let frames = buffers.map(\.count).min() ?? 0
        let channelCount = channels.count
        var index = 0
        while index < frames {
            var acc = 0.0
            for c in 0..<channelCount where weights[c] > 0 {
                let y = filters[c].process(Double(buffers[c][index]))
                acc += weights[c] * y * y
            }
            sum += acc
            fill += 1
            if fill == subBlockFrames { completeSubBlock() }
            index += 1
        }
    }

    mutating func process(planar: [[Float]]) {
        guard planar.count == channels.count else { return }
        let frames = planar.map(\.count).min() ?? 0
        guard frames > 0 else { return }
        // The pointers stay valid because `planar` outlives the nested calls.
        withExtendedLifetime(planar) {
            var views: [UnsafeBufferPointer<Float>] = []
            views.reserveCapacity(planar.count)
            func gather(_ i: Int) {
                if i == planar.count {
                    process(views)
                    return
                }
                planar[i].withUnsafeBufferPointer { buffer in
                    views.append(UnsafeBufferPointer(rebasing: buffer[0..<frames]))
                    gather(i + 1)
                }
            }
            gather(0)
        }
    }

    private mutating func completeSubBlock() {
        let value = sum / Double(subBlockFrames)
        sum = 0
        fill = 0
        ring[ringIndex] = value
        ringIndex = (ringIndex + 1) % ring.count
        ringCount = min(ringCount + 1, ring.count)

        if ringCount >= Self.momentarySubBlocks {
            let power = meanOfLatest(Self.momentarySubBlocks)
            currentMomentaryPower = power
            momentaryMaxPower = max(momentaryMaxPower, power)
            append(&blockPowers, power)
        }
        if ringCount >= Self.shortTermSubBlocks {
            let power = meanOfLatest(Self.shortTermSubBlocks)
            currentShortTermPower = power
            shortTermMaxPower = max(shortTermMaxPower, power)
            append(&shortTermPowers, power)
        }
    }

    private func meanOfLatest(_ count: Int) -> Double {
        var total = 0.0
        for offset in 1...count {
            total += ring[(ringIndex - offset + ring.count) % ring.count]
        }
        return total / Double(count)
    }

    private func append(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > Self.maxHistory + 1_000 {
            array.removeFirst(1_000)
        }
    }

    /// The input stopped being contiguous (the window was hidden, or capture
    /// frames were dropped). Momentary and short-term windows restart; the
    /// integrated history is kept, and marked gapped when frames were lost.
    mutating func markDiscontinuity(gapped lost: Bool) {
        for i in filters.indices { filters[i].reset() }
        fill = 0
        sum = 0
        ringIndex = 0
        ringCount = 0
        currentMomentaryPower = nil
        currentShortTermPower = nil
        if lost { gapped = true }
    }

    /// Clears every measurement, including integrated loudness, range, maxima
    /// and the gapped flag.
    mutating func reset() {
        markDiscontinuity(gapped: false)
        blockPowers.removeAll(keepingCapacity: true)
        shortTermPowers.removeAll(keepingCapacity: true)
        momentaryMaxPower = 0
        shortTermMaxPower = 0
        gapped = false
        cachedIntegrated = nil
        cachedRange = nil
        cachedAtCount = -1
    }

    /// Readout for the display. The integrated and range values are recomputed
    /// at most once per second of new blocks; use `exactReadout()` in tests.
    mutating func readout() -> LoudnessReadout {
        if cachedAtCount < 0 || blockPowers.count - cachedAtCount >= 10 {
            refreshGatedValues()
        }
        return makeReadout()
    }

    mutating func exactReadout() -> LoudnessReadout {
        refreshGatedValues()
        return makeReadout()
    }

    private mutating func refreshGatedValues() {
        cachedIntegrated = Self.integratedLoudness(blockPowers: blockPowers)
        cachedRange = Self.loudnessRange(shortTermPowers: shortTermPowers)
        cachedAtCount = blockPowers.count
    }

    private func makeReadout() -> LoudnessReadout {
        func lufs(_ power: Double?) -> Double? {
            guard let power, power > 0 else { return nil }
            return Self.loudness(power: power)
        }
        return LoudnessReadout(
            momentary: lufs(currentMomentaryPower),
            shortTerm: lufs(currentShortTermPower),
            integrated: cachedIntegrated,
            range: cachedRange,
            momentaryMax: lufs(momentaryMaxPower),
            shortTermMax: lufs(shortTermMaxPower),
            isGapped: gapped,
            measuredSeconds: Double(blockPowers.count > 0 ? blockPowers.count + 3 : 0) * 0.1
        )
    }

    // MARK: Gating (pure, so the tests can call them directly)

    /// Tech 3341 / BS.1770-4 two-stage gate over 400 ms block powers.
    static func integratedLoudness(blockPowers: [Double]) -> Double? {
        let absoluteGate = power(loudness: absoluteGateLUFS)
        var total = 0.0
        var count = 0
        for p in blockPowers where p >= absoluteGate {
            total += p
            count += 1
        }
        guard count > 0 else { return nil }
        let relativeGate = power(loudness: loudness(power: total / Double(count)) + integratedRelativeGateLU)
        var gatedTotal = 0.0
        var gatedCount = 0
        for p in blockPowers where p >= absoluteGate && p > relativeGate {
            gatedTotal += p
            gatedCount += 1
        }
        guard gatedCount > 0 else { return nil }
        return loudness(power: gatedTotal / Double(gatedCount))
    }

    /// Tech 3342: gate short-term windows at -70 LUFS and 20 LU under their
    /// power mean, then the spread between the 10th and 95th percentiles.
    static func loudnessRange(shortTermPowers: [Double]) -> Double? {
        let absoluteGate = power(loudness: absoluteGateLUFS)
        let absolute = shortTermPowers.filter { $0 >= absoluteGate }
        guard !absolute.isEmpty else { return nil }
        let mean = absolute.reduce(0, +) / Double(absolute.count)
        let relativeGate = power(loudness: loudness(power: mean) + rangeRelativeGateLU)
        let kept = absolute.filter { $0 > relativeGate }.map { loudness(power: $0) }.sorted()
        guard kept.count >= 2 else { return kept.isEmpty ? nil : 0 }
        func percentile(_ p: Double) -> Double {
            let position = p * Double(kept.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, kept.count - 1)
            return kept[lower] + (kept[upper] - kept[lower]) * (position - Double(lower))
        }
        return percentile(0.95) - percentile(0.10)
    }
}

// MARK: - True-peak maximum

/// Highest true peak since the last Reset, fed from the engine's 4x protection
/// detector through the meter hub (no second true-peak implementation).
struct TruePeakMaxHold: Equatable, Sendable {
    private(set) var maxDBTP: Double?

    mutating func update(dbtp: Double) {
        guard dbtp.isFinite, dbtp > ProductionMeterMath.floorDB else { return }
        maxDBTP = max(maxDBTP ?? -.infinity, dbtp)
    }

    mutating func reset() { maxDBTP = nil }
}

// MARK: - Feed from the analysis capture

/// Owns the Input and Output loudness meters for one transport session and
/// turns analysis frames and demand changes into meter calls. The worker holds
/// one of these; it is separate so the behaviour is testable without a bridge.
final class ProductionLoudnessFeed {
    private(set) var input: LoudnessMeter?
    private(set) var output: LoudnessMeter?
    private var active = false
    private var lastDropped: UInt64 = 0
    private var scratch: [[Float]] = Array(repeating: [], count: 4)

    var isActive: Bool { active }

    /// `active` follows the loudness demand. Resuming after a pause restarts
    /// the momentary and short-term windows but keeps the integrated history.
    func setActive(_ nowActive: Bool, sampleRate: Double) {
        if nowActive {
            ensureMeters(sampleRate: sampleRate)
            if !active {
                input?.markDiscontinuity(gapped: false)
                output?.markDiscontinuity(gapped: false)
            }
        }
        active = nowActive
    }

    func reset() {
        input?.reset()
        output?.reset()
    }

    /// The sample rate changed: a new filter set, and the old measurement no
    /// longer describes the new signal path, so everything restarts.
    func ensureMeters(sampleRate: Double) {
        guard sampleRate > 0 else { return }
        if input?.sampleRate != sampleRate {
            input = LoudnessMeter(sampleRate: sampleRate)
            output = LoudnessMeter(sampleRate: sampleRate)
        }
    }

    func ingest(_ frames: UnsafeBufferPointer<N60AnalysisFrame>) {
        guard active, !frames.isEmpty, input != nil, output != nil else { return }
        let count = frames.count
        for i in 0..<4 where scratch[i].count < count {
            scratch[i] = [Float](repeating: 0, count: count)
        }
        for n in 0..<count {
            let f = frames[n]
            scratch[0][n] = f.inputLeft
            scratch[1][n] = f.inputRight
            scratch[2][n] = f.outputLeft
            scratch[3][n] = f.outputRight
        }
        input?.process(planar: [Array(scratch[0][0..<count]), Array(scratch[1][0..<count])])
        output?.process(planar: [Array(scratch[2][0..<count]), Array(scratch[3][0..<count])])
    }

    /// Call after draining. A rising dropped-frame counter means the ring
    /// overflowed, so the signal has a hole: integrated becomes "gapped".
    func noteDroppedFrames(_ total: UInt64) {
        if active, total > lastDropped {
            input?.markDiscontinuity(gapped: true)
            output?.markDiscontinuity(gapped: true)
        }
        lastDropped = total
    }

    func readouts() -> (input: LoudnessReadout, output: LoudnessReadout)? {
        guard active, input != nil, output != nil else { return nil }
        return (input!.readout(), output!.readout())
    }
}

// MARK: - Wide sessions (E28 S6b)

extension LoudnessChannelPosition {
    /// BS.1770-4 position of a semantic program role (ITU-R BS.2051 nominal angles). The weight follows
    /// `weight`: the surround and rear roles get +1.5 dB, height roles and the LFE follow Table 3.
    init(role: OutputProgramRole) {
        switch role {
        case .frontLeft, .frontRight: self = .left
        case .frontCenter: self = .centre
        case .lowFrequencyEffects: self = .lfe
        case .sideLeft, .sideRight: self = LoudnessChannelPosition(azimuthDegrees: 90, elevationDegrees: 0, isLFE: false)
        case .rearLeft, .rearRight: self = .leftRearSurround
        case .wideLeft, .wideRight: self = LoudnessChannelPosition(azimuthDegrees: 60, elevationDegrees: 0, isLFE: false)
        case .topFrontLeft, .topFrontRight: self = .leftHeight
        case .topMiddleLeft, .topMiddleRight:
            self = LoudnessChannelPosition(azimuthDegrees: 90, elevationDegrees: 45, isLFE: false)
        case .topRearLeft, .topRearRight: self = .leftRearHeight
        }
    }

    static func positions(for roles: [OutputProgramRole]) -> [LoudnessChannelPosition] {
        roles.map { LoudnessChannelPosition(role: $0) }
    }
}

/// Loudness feed for the N-channel and binaural sessions: interleaved Input and Output frames drained from the bridge's
/// `N60LoudnessCapture`, one meter per side with that side's own channel positions. Output is nil when the session cannot
/// map its output back to program roles (a routed lane map). Runs on the analysis queue only.
final class WideLoudnessFeed {
    let inputPositions: [LoudnessChannelPosition]
    let outputPositions: [LoudnessChannelPosition]?
    private(set) var input: LoudnessMeter
    private(set) var output: LoudnessMeter?
    private var active = false
    private var lastDropped: UInt64 = 0
    private var inputScratch: [[Float]]
    private var outputScratch: [[Float]]

    var isActive: Bool { active }

    init(sampleRate: Double, inputPositions: [LoudnessChannelPosition], outputPositions: [LoudnessChannelPosition]?) {
        self.inputPositions = inputPositions
        self.outputPositions = outputPositions
        input = LoudnessMeter(sampleRate: sampleRate, channels: inputPositions)
        output = outputPositions.map { LoudnessMeter(sampleRate: sampleRate, channels: $0) }
        inputScratch = Array(repeating: [], count: inputPositions.count)
        outputScratch = Array(repeating: [], count: outputPositions?.count ?? 0)
    }

    /// Resuming after a pause restarts the momentary and short-term windows but keeps the integrated history.
    func setActive(_ nowActive: Bool) {
        if nowActive, !active {
            input.markDiscontinuity(gapped: false)
            output?.markDiscontinuity(gapped: false)
        }
        active = nowActive
    }

    func reset() {
        input.reset()
        output?.reset()
    }

    /// `inputFrames` and `outputFrames` are interleaved with the position count as the stride.
    func ingest(input inputFrames: UnsafePointer<Float>, output outputFrames: UnsafePointer<Float>?, frames: Int) {
        guard active, frames > 0 else { return }
        Self.deinterleave(inputFrames, frames: frames, into: &inputScratch)
        input.process(planar: inputScratch)
        if output != nil, let outputFrames {
            Self.deinterleave(outputFrames, frames: frames, into: &outputScratch)
            output?.process(planar: outputScratch)
        }
    }

    private static func deinterleave(_ source: UnsafePointer<Float>, frames: Int, into planar: inout [[Float]]) {
        let stride = planar.count
        for c in 0..<stride {
            if planar[c].count != frames { planar[c] = [Float](repeating: 0, count: frames) }
            planar[c].withUnsafeMutableBufferPointer { buffer in
                for n in 0..<frames { buffer[n] = source[n * stride + c] }
            }
        }
    }

    /// A rising dropped-frame counter means the ring overflowed, so the signal has a hole.
    func noteDroppedFrames(_ total: UInt64) {
        if active, total > lastDropped {
            input.markDiscontinuity(gapped: true)
            output?.markDiscontinuity(gapped: true)
        }
        lastDropped = total
    }

    func readouts() -> (input: LoudnessReadout, output: LoudnessReadout?)? {
        guard active else { return nil }
        return (input.readout(), output?.readout())
    }
}
