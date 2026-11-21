import Accelerate
import Foundation

// E33 S17: analysis on every session type. The View selector, the pair picker and the wide-session feed.
//
// Threading: everything here runs on the analysis worker's queue (or the main actor for the pure helpers); nothing
// touches the audio callback. The wide feed reads the `N60LoudnessCapture` ring the N-channel and binaural bridges
// already own (E28 S6b), so no new capture tap exists.
// Allocation: buffers are sized on the first block after a demand change and reused; a hidden card holds no state.
// Latency: the capture adds none; each view is at most one 50 ms drain old.
// Sample rate: every meter takes the session rate; nothing assumes a rate.
// Channels: 1 to `N60_MAX_PROGRAM_CHANNELS` programme channels plus up to eight subwoofer feeds.
// Reset: a changed View or pair starts the windows of the views that depend on it again.

// MARK: - View and pair selection

/// Which signal the Spectrum, RTA and Spectrogram analyse. One view is analysed at a time, so the cost stays that of a
/// single analysis (decision 18).
enum AnalysisView: Hashable, Sendable {
    /// Stereo bridge: Stereo (both sides). Wide session: All. Binaural: the ear pair.
    case standard
    /// Stereo bridge only.
    case left, right, mid, side
    /// Wide session: one named group of speakers.
    case group(WideGroup)
    /// Binaural only: the programme channels before rendering.
    case programme
    /// Wide session: one speaker by its place in the programme layout.
    case speaker(Int)

    static let maxSpeakerIndex = 223

    /// The 8-bit code carried in the demand mask (0 is `standard`).
    var code: UInt8 {
        switch self {
        case .standard: return 0
        case .left: return 1
        case .right: return 2
        case .mid: return 3
        case .side: return 4
        case .group(let g): return 8 + g.rawValue
        case .programme: return 16
        case .speaker(let i): return UInt8(32 + min(max(i, 0), Self.maxSpeakerIndex))
        }
    }

    init(code: UInt8) {
        switch code {
        case 1: self = .left
        case 2: self = .right
        case 3: self = .mid
        case 4: self = .side
        case 9...13: self = WideGroup(rawValue: code - 8).map { .group($0) } ?? .standard
        case 16: self = .programme
        case 32...255: self = .speaker(Int(code) - 32)
        default: self = .standard
        }
    }
}

/// The speaker groups of the wide-session View selector.
enum WideGroup: UInt8, CaseIterable, Sendable {
    case front = 1, centre, surrounds, heights, sub

    var title: String {
        switch self {
        case .front: return "Front"
        case .centre: return "Centre"
        case .surrounds: return "Surrounds"
        case .heights: return "Heights"
        case .sub: return "Sub"
        }
    }

    init(role: OutputProgramRole) {
        switch role {
        case .frontLeft, .frontRight, .wideLeft, .wideRight: self = .front
        case .frontCenter: self = .centre
        case .lowFrequencyEffects: self = .sub
        case .sideLeft, .sideRight, .rearLeft, .rearRight: self = .surrounds
        case .topFrontLeft, .topFrontRight, .topMiddleLeft, .topMiddleRight, .topRearLeft, .topRearRight: self = .heights
        }
    }
}

/// The pair the Stereo page measures (G30).
enum AnalysisPair: UInt8, CaseIterable, Sendable {
    /// Stereo bridge: the output pair. Wide session: the front pair. Binaural: the ear pair (what is heard).
    case standard = 0
    case surrounds, rears, heights
    /// Binaural: the programme's front pair before rendering.
    case programme

    var title: String {
        switch self {
        case .standard: return "Front"
        case .surrounds: return "Surrounds"
        case .rears: return "Rears"
        case .heights: return "Heights"
        case .programme: return "Programme front"
        }
    }
}

/// Carries the selection in the analysis demand mask: bits 16 to 23 the view, bits 24 to 27 the pair. The mask is the
/// one channel between the Meters page and the sessions, so no engine entry point changes.
enum ProductionAnalysisSelection {
    static let viewShift: UInt32 = 16
    static let pairShift: UInt32 = 24
    static let viewBits: UInt32 = 0xFF << 16
    static let pairBits: UInt32 = 0xF << 24
    static let allBits: UInt32 = viewBits | pairBits

    static func encode(view: AnalysisView, pair: AnalysisPair = .standard) -> UInt32 {
        (UInt32(view.code) << viewShift) | (UInt32(pair.rawValue) << pairShift)
    }

    static func decode(_ mask: UInt32) -> (view: AnalysisView, pair: AnalysisPair) {
        let view = AnalysisView(code: UInt8((mask & viewBits) >> viewShift))
        let pair = AnalysisPair(rawValue: UInt8((mask & pairBits) >> pairShift)) ?? .standard
        return (view, pair)
    }
}

/// Left, Right, Mid and Side of a stereo pair. The same value goes on both sides so a one-signal view feeds the
/// two-sided analysers unchanged. Mid and Side are the half sum and half difference, so a mono signal has no Side.
enum StereoViewTransform {
    static func apply(_ view: AnalysisView, left: Float, right: Float) -> (Float, Float) {
        switch view {
        case .left: return (left, left)
        case .right: return (right, right)
        case .mid: let m = 0.5 * (left + right); return (m, m)
        case .side: let s = 0.5 * (left - right); return (s, s)
        default: return (left, right)
        }
    }
}

// MARK: - Which channels a view or pair reads

/// Resolves views and pairs to channel indices of the capture ring. Input indices are programme roles in layout order;
/// output indices are the same roles followed by one channel per driven subwoofer feed (or the two ears on a binaural
/// bridge). A ring with no output plane (a routed lane map that cannot map back to roles) falls back to the input plane.
struct WideAnalysisPlan: Equatable, Sendable {
    let roles: [OutputProgramRole]
    let inputChannels: Int
    let outputChannels: Int
    let isBinaural: Bool

    var hasOutput: Bool { outputChannels > 0 }

    struct Source: Equatable, Sendable {
        var input: [Int]
        var output: [Int]
        /// True when `output` indexes the input plane (no output plane, or a programme view).
        var outputFromInput: Bool
    }

    struct Pair: Equatable, Sendable {
        var left: Int
        var right: Int
        var fromInput: Bool
    }

    func source(for view: AnalysisView) -> Source {
        let allInput = Array(0..<inputChannels)
        let standard = Source(
            input: allInput,
            output: hasOutput ? Array(0..<outputChannels) : allInput,
            outputFromInput: !hasOutput)
        switch view {
        case .standard, .left, .right, .mid, .side:
            return standard
        case .programme:
            return Source(input: allInput, output: allInput, outputFromInput: true)
        case .speaker(let i):
            guard i >= 0, i < inputChannels else { return standard }
            return restricted([i], extraOutput: [])
        case .group(let g):
            let members = roles.indices.filter { WideGroup(role: roles[$0]) == g && $0 < inputChannels }
            let feeds = (g == .sub && !isBinaural && hasOutput) ? Array(inputChannels..<outputChannels) : []
            if members.isEmpty && feeds.isEmpty { return standard }
            return restricted(members, extraOutput: feeds)
        }
    }

    private func restricted(_ members: [Int], extraOutput: [Int]) -> Source {
        // A binaural bridge renders to two ears, so a speaker view there is the programme channel itself.
        if isBinaural || !hasOutput {
            return Source(input: members, output: members, outputFromInput: true)
        }
        return Source(input: members, output: members + extraOutput, outputFromInput: false)
    }

    /// The channel pairs the Stereo page offers on this session, always starting with the standard one.
    /// E33 S11 (G72): one role name per bit-activity channel (input channels are programme roles, binaural included); empty
    /// when the roles do not line up with the channels, so the card falls back to the transport's labels.
    func bitChannelNames(bitCount: Int) -> [String] {
        roles.count == bitCount ? roles.map(\.displayName) : []
    }

    var availablePairs: [AnalysisPair] {
        if isBinaural { return pair(.programme) != nil ? [.standard, .programme] : [.standard] }
        return AnalysisPair.allCases.filter { $0 != .programme && (pair($0) != nil || $0 == .standard) }
    }

    func pair(_ choice: AnalysisPair) -> Pair? {
        func find(_ a: OutputProgramRole, _ b: OutputProgramRole) -> (Int, Int)? {
            guard let l = roles.firstIndex(of: a), let r = roles.firstIndex(of: b) else { return nil }
            return (l, r)
        }
        let front = find(.frontLeft, .frontRight)
        let plane = !hasOutput
        switch choice {
        case .standard:
            if isBinaural { return hasOutput ? Pair(left: 0, right: 1, fromInput: false) : nil }
            return (front ?? (inputChannels >= 2 ? (0, 1) : nil)).map { Pair(left: $0.0, right: $0.1, fromInput: plane) }
        case .programme:
            return (front ?? (inputChannels >= 2 ? (0, 1) : nil)).map { Pair(left: $0.0, right: $0.1, fromInput: true) }
        case .surrounds:
            return find(.sideLeft, .sideRight).map { Pair(left: $0.0, right: $0.1, fromInput: plane) }
        case .rears:
            return find(.rearLeft, .rearRight).map { Pair(left: $0.0, right: $0.1, fromInput: plane) }
        case .heights:
            let found = find(.topFrontLeft, .topFrontRight) ?? find(.topMiddleLeft, .topMiddleRight)
                ?? find(.topRearLeft, .topRearRight)
            return found.map { Pair(left: $0.0, right: $0.1, fromInput: plane) }
        }
    }

    /// The chosen pair, or the standard one when this session does not have it.
    func resolvedPair(_ choice: AnalysisPair) -> Pair? { pair(choice) ?? pair(.standard) }

    /// The front pair every balance and per-band correlation reading uses on a wide session.
    var meterPair: Pair? { pair(.standard) }
}

// MARK: - The headroom strip on wide sessions

enum WideHeadroom {
    /// The channel with the largest peak, for the strip to name. nil when no channel has a reading.
    static func worst(_ channels: [ProductionTransportChannelMeter]) -> (label: String, peakLinear: Float)? {
        var best: ProductionTransportChannelMeter?
        for channel in channels where channel.peakLinear > (best?.peakLinear ?? 0) { best = channel }
        return best.map { ($0.label, $0.peakLinear) }
    }
}

// MARK: - The wide-session analysis feed

/// Everything the worker of an N-channel or binaural bridge computes besides loudness, from the same capture ring.
/// Each part runs only while its card is visible. Runs on the analysis queue only.
final class WideAnalysisFeed {
    private static let spectrumCapacity = 32_768
    private static let correlationCapacity = 65_536
    private static let goniometerHistoryFrames = 4_096
    private static let goniometerPointLimit = 384

    let plan: WideAnalysisPlan
    let sampleRate: Double

    private(set) var view = AnalysisView.standard
    private(set) var pair = AnalysisPair.standard

    private var wantsSpectrum = false
    private var wantsStereo = false
    private var wantsMeters = false
    private var wantsRTA = false
    private var wantsSpectrogram = false
    private var wantsBits = false

    private var peakCrest: [PeakCrestMeter] = []
    private var balance: BalanceMeter?
    private var correlation: BandCorrelationMeter?
    private var rta: ThirdOctaveRTA?
    private let spectrogramFeed = ProductionSpectrogramFeed()
    private let spectrumAnalyzer = ProductionSpectrumAnalyzer()

    private var inputPlanar: [[Float]]
    private var outputPlanar: [[Float]]
    private var viewInput: [Float] = []
    private var viewOutput: [Float] = []

    private var specInputRing = [Float](repeating: 0, count: WideAnalysisFeed.spectrumCapacity)
    private var specOutputRing = [Float](repeating: 0, count: WideAnalysisFeed.spectrumCapacity)
    private var specWrite = 0
    private var specCount = 0
    private var pairLeftRing: [Float] = []
    private var pairRightRing: [Float] = []
    private var pairWrite = 0
    private var pairCount = 0
    /// Scratch reused by `spectrum()` and `stereoReadout()` (G71: no allocation per tick beyond the result).
    private var spectrumInScratch: [Float] = []
    private var spectrumOutScratch: [Float] = []
    private var pairLeftScratch: [Float] = []
    private var pairRightScratch: [Float] = []

    init(plan: WideAnalysisPlan, sampleRate: Double) {
        self.plan = plan
        self.sampleRate = sampleRate
        inputPlanar = Array(repeating: [], count: plan.inputChannels)
        outputPlanar = Array(repeating: [], count: plan.outputChannels)
    }

    var isActive: Bool { wantsSpectrum || wantsStereo || wantsMeters || wantsRTA || wantsSpectrogram || wantsBits }

    /// `mask` is the sanitised demand: the bridge bits plus the worker bits. `selection` is the decoded View and pair.
    func setDemand(
        spectrum: Bool, stereo: Bool, meters: Bool, rta wantsRTA: Bool, spectrogram: Bool, spectrogramWindow: SpectrogramWindow,
        bits: Bool, view newView: AnalysisView, pair newPair: AnalysisPair
    ) {
        let viewChanged = newView != view
        let pairChanged = newPair != pair
        view = newView
        pair = newPair
        if spectrum != wantsSpectrum || viewChanged { specWrite = 0; specCount = 0 }
        if stereo != wantsStereo || pairChanged { pairWrite = 0; pairCount = 0 }
        wantsSpectrum = spectrum
        wantsStereo = stereo
        wantsMeters = meters
        self.wantsRTA = wantsRTA
        wantsSpectrogram = spectrogram
        wantsBits = bits

        if meters {
            if peakCrest.isEmpty {
                let planes = max(plan.hasOutput ? plan.outputChannels : plan.inputChannels, 1)
                peakCrest = Array(repeating: PeakCrestMeter(sampleRate: sampleRate), count: (planes + 1) / 2)
                balance = BalanceMeter(sampleRate: sampleRate)
                correlation = BandCorrelationMeter(sampleRate: sampleRate)
            }
        } else {
            peakCrest = []; balance = nil; correlation = nil
        }
        if wantsRTA {
            if rta == nil { rta = ThirdOctaveRTA(sampleRate: sampleRate) } else if viewChanged { rta?.reset() }
        } else {
            rta = nil
        }
        spectrogramFeed.setActiveWide(
            spectrogram: spectrogram, window: spectrogramWindow, bitActivity: bits,
            bitChannels: plan.inputChannels, sampleRate: sampleRate)
        if viewChanged { spectrogramFeed.resetSpectrogram() }
        if !stereo { pairLeftRing = []; pairRightRing = [] }
        if stereo, pairLeftRing.isEmpty {
            pairLeftRing = [Float](repeating: 0, count: Self.correlationCapacity)
            pairRightRing = pairLeftRing
        }
        if !isActive { releaseScratch() }
    }

    private func releaseScratch() {
        for i in inputPlanar.indices { inputPlanar[i] = [] }
        for i in outputPlanar.indices { outputPlanar[i] = [] }
        viewInput = []; viewOutput = []
        spectrumInScratch = []; spectrumOutScratch = []; pairLeftScratch = []; pairRightScratch = []
    }

    func resetMeters() {
        for i in peakCrest.indices { peakCrest[i].reset() }
        balance?.reset(); correlation?.reset()
    }

    func resetBitActivity() { spectrogramFeed.resetBitActivity() }

    /// `input` and `output` are interleaved with the plan's channel counts as the stride.
    func ingest(input: UnsafePointer<Float>, output: UnsafePointer<Float>?, frames: Int) {
        guard isActive, frames > 0 else { return }
        let outputPresent = output != nil && plan.hasOutput
        Self.deinterleave(input, frames: frames, into: &inputPlanar)
        if outputPresent, let output { Self.deinterleave(output, frames: frames, into: &outputPlanar) }
        let heard = outputPresent ? outputPlanar : inputPlanar

        if wantsBits {
            for c in 0..<plan.inputChannels {
                inputPlanar[c].withUnsafeBufferPointer {
                    spectrogramFeed.ingestBits(channel: c, samples: UnsafeBufferPointer(rebasing: $0[0..<frames]))
                }
            }
        }
        if wantsMeters { ingestMeters(heard: heard, frames: frames) }
        if wantsRTA || wantsSpectrogram || wantsSpectrum {
            let source = plan.source(for: view)
            let outPlanes = source.outputFromInput ? inputPlanar : heard
            Self.mix(inputPlanar, indices: source.input, frames: frames, into: &viewInput)
            Self.mix(outPlanes, indices: source.output, frames: frames, into: &viewOutput)
            viewOutput.withUnsafeBufferPointer { out in
                let v = UnsafeBufferPointer(rebasing: out[0..<frames])
                if wantsRTA { rta?.ingest(left: v, right: v) }
                if wantsSpectrogram { spectrogramFeed.ingestWide(viewLeft: v, viewRight: v) }
            }
            if wantsSpectrum {
                Self.ringAppend(&specInputRing, write: specWrite, source: viewInput, frames: frames)
                specWrite = Self.ringAppend(&specOutputRing, write: specWrite, source: viewOutput, frames: frames)
                specCount = min(specCount + frames, Self.spectrumCapacity)
            }
        }
        if wantsStereo, let chosen = plan.resolvedPair(pair) {
            let planes = (chosen.fromInput || !outputPresent) ? inputPlanar : heard
            if chosen.left < planes.count, chosen.right < planes.count {
                Self.ringAppend(&pairLeftRing, write: pairWrite, source: planes[chosen.left], frames: frames)
                pairWrite = Self.ringAppend(&pairRightRing, write: pairWrite, source: planes[chosen.right], frames: frames)
                pairCount = min(pairCount + frames, Self.correlationCapacity)
            }
        }
    }

    private func ingestMeters(heard: [[Float]], frames: Int) {
        // PLR, PSR and crest cover the whole programme: one true-peak pair per two channels, combined by maximum.
        let count = heard.count
        for p in peakCrest.indices {
            let a = min(2 * p, count - 1)
            let b = min(2 * p + 1, count - 1)
            heard[a].withUnsafeBufferPointer { l in
                heard[b].withUnsafeBufferPointer { r in
                    peakCrest[p].process(left: UnsafeBufferPointer(rebasing: l[0..<frames]),
                                         right: UnsafeBufferPointer(rebasing: r[0..<frames]))
                }
            }
        }
        // Balance and per-band correlation use the front pair.
        guard let front = plan.meterPair, front.left < count, front.right < count else { return }
        let fromHeard = !front.fromInput || !plan.hasOutput
        let planes = fromHeard ? heard : inputPlanar
        planes[front.left].withUnsafeBufferPointer { l in
            planes[front.right].withUnsafeBufferPointer { r in
                let lv = UnsafeBufferPointer(rebasing: l[0..<frames])
                let rv = UnsafeBufferPointer(rebasing: r[0..<frames])
                balance?.process(left: lv, right: rv)
                correlation?.process(left: lv, right: rv)
            }
        }
    }

    func meterReadout(loudness: LoudnessReadout?) -> AnalysisMeterReadout? {
        guard wantsMeters, let balance, let correlation, !peakCrest.isEmpty else { return nil }
        var maxTP: Double?, recentTP: Double?, crest: Double?
        for meter in peakCrest {
            let r = meter.readout()
            if let v = r.truePeakMaxDBTP { maxTP = max(maxTP ?? -.infinity, v) }
            if let v = r.truePeakRecentDBTP { recentTP = max(recentTP ?? -.infinity, v) }
            if let v = r.crestDB { crest = max(crest ?? -.infinity, v) }
        }
        var out = AnalysisMeterReadout()
        out.truePeakMaxDBTP = maxTP
        out.truePeakRecentDBTP = recentTP
        out.crestDB = crest
        out.plr = PeakCrestMeter.plr(truePeakMaxDBTP: maxTP, integratedLUFS: loudness?.integrated)
        if let recentTP, let shortTerm = loudness?.shortTerm { out.psr = recentTP - shortTerm }
        out.balanceDB = balance.balanceDB()
        out.correlation = correlation.correlations()
        return out
    }

    func rtaLevels() -> [Float] {
        guard wantsRTA, let levels = rta?.bandLevelsDB() else { return [] }
        return levels
    }

    func spectrogramSnapshot() -> SpectrogramSnapshot? { spectrogramFeed.spectrogramSnapshot() }
    func bitActivity() -> [BitActivityChannel] { spectrogramFeed.bitActivity() }

    func requestPeakHoldReset() { spectrumAnalyzer.requestPeakHoldReset() }

    func spectrum() -> [ProductionSpectrumBand] {
        guard wantsSpectrum else { return [] }
        let size = ProductionAnalysisMath.fftSize(sampleRate: sampleRate)
        guard specCount >= size else { return [] }
        let start = (specWrite - size + Self.spectrumCapacity) % Self.spectrumCapacity
        if spectrumInScratch.count != size {
            spectrumInScratch = [Float](repeating: 0, count: size)
            spectrumOutScratch = spectrumInScratch
        }
        Self.ringCopy(specInputRing, start: start, count: size, into: &spectrumInScratch)
        Self.ringCopy(specOutputRing, start: start, count: size, into: &spectrumOutScratch)
        return spectrumAnalyzer.analyze(
            inputLeft: spectrumInScratch, inputRight: spectrumInScratch,
            outputLeft: spectrumOutScratch, outputRight: spectrumOutScratch, count: size, sampleRate: sampleRate)
    }

    /// Correlation over about 100 ms and the goniometer history of the chosen pair.
    func stereoReadout() -> (correlation: Float?, points: [ProductionGoniometerPoint]) {
        guard wantsStereo, pairCount > 0 else { return (nil, []) }
        let want = Int(min(max(sampleRate * 0.1, 1_024), Double(Self.correlationCapacity)))
        let frames = min(pairCount, want)
        let start = (pairWrite - frames + Self.correlationCapacity) % Self.correlationCapacity
        if pairLeftScratch.count < frames {
            pairLeftScratch = [Float](repeating: 0, count: frames)
            pairRightScratch = pairLeftScratch
        }
        Self.ringCopy(pairLeftRing, start: start, count: frames, into: &pairLeftScratch)
        Self.ringCopy(pairRightRing, start: start, count: frames, into: &pairRightScratch)
        let correlation = ProductionAnalysisMath.phaseCorrelation(left: pairLeftScratch, right: pairRightScratch, count: frames)

        let usable = min(pairCount, Self.goniometerHistoryFrames)
        let pointCount = min(usable, Self.goniometerPointLimit)
        let stride = max(usable / max(pointCount, 1), 1)
        let gStart = (pairWrite - usable + Self.correlationCapacity) % Self.correlationCapacity
        var points: [ProductionGoniometerPoint] = []
        points.reserveCapacity(pointCount)
        var offset = 0
        while offset < usable, points.count < pointCount {
            let s = (gStart + offset) % Self.correlationCapacity
            points.append(ProductionAnalysisMath.goniometerPoint(left: pairLeftRing[s], right: pairRightRing[s]))
            offset += stride
        }
        return (correlation, points)
    }

    // MARK: Helpers

    private static func deinterleave(_ source: UnsafePointer<Float>, frames: Int, into planar: inout [[Float]]) {
        let stride = planar.count
        for c in 0..<stride {
            // Grow only: a plane may be longer than `frames`; every reader takes the first `frames` samples.
            if planar[c].count < frames { planar[c] = [Float](repeating: 0, count: frames) }
            planar[c].withUnsafeMutableBufferPointer { buffer in
                for n in 0..<frames { buffer[n] = source[n * stride + c] }
            }
        }
    }

    /// Sum of the chosen channels, scaled by 1/sqrt(n) so uncorrelated channels keep their power and one channel is
    /// unchanged. Indices outside the planes are skipped.
    static func mix(_ planes: [[Float]], indices: [Int], frames: Int, into out: inout [Float]) {
        if out.count < frames { out = [Float](repeating: 0, count: frames) }
        var validCount = 0
        for c in indices where c >= 0 && c < planes.count && planes[c].count >= frames { validCount += 1 }
        out.withUnsafeMutableBufferPointer { o in
            for n in 0..<frames { o[n] = 0 }
            guard validCount > 0 else { return }
            // Channel by channel in index order, so each sample's sum has the same order as before.
            for c in indices where c >= 0 && c < planes.count && planes[c].count >= frames {
                planes[c].withUnsafeBufferPointer { p in
                    vDSP_vadd(o.baseAddress!, 1, p.baseAddress!, 1, o.baseAddress!, 1, vDSP_Length(frames))
                }
            }
            var scale = 1 / Float(validCount).squareRoot()
            vDSP_vsmul(o.baseAddress!, 1, &scale, o.baseAddress!, 1, vDSP_Length(frames))
        }
    }

    /// Appends `frames` samples of `source` to a ring at `write` in at most two block copies; returns the new write index.
    @discardableResult
    static func ringAppend(_ ring: inout [Float], write: Int, source: [Float], frames: Int) -> Int {
        let capacity = ring.count
        // A block longer than the ring keeps only its newest `capacity` samples.
        let kept = min(frames, capacity)
        let skip = frames - kept
        let begin = (write + skip) % capacity
        let first = min(kept, capacity - begin)
        ring.withUnsafeMutableBufferPointer { r in
            source.withUnsafeBufferPointer { s in
                (r.baseAddress! + begin).update(from: s.baseAddress! + skip, count: first)
                if first < kept { r.baseAddress!.update(from: s.baseAddress! + skip + first, count: kept - first) }
            }
        }
        return (write + frames) % capacity
    }

    /// Copies `count` samples starting at ring index `start` (wrapping) into the front of `out`.
    static func ringCopy(_ ring: [Float], start: Int, count: Int, into out: inout [Float]) {
        let capacity = ring.count
        let first = min(count, capacity - start)
        ring.withUnsafeBufferPointer { r in
            out.withUnsafeMutableBufferPointer { o in
                o.baseAddress!.update(from: r.baseAddress! + start, count: first)
                if first < count { (o.baseAddress! + first).update(from: r.baseAddress!, count: count - first) }
            }
        }
    }
}

// MARK: - What the View selector and pair picker offer

/// The choices for one session, from what the Meters page already knows about it. Pure, so it is tested without a view.
struct AnalysisViewOptions: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case stereo, wide, binaural }

    let kind: Kind
    let views: [Entry]
    let pairs: [PairEntry]

    struct Entry: Equatable, Identifiable, Sendable {
        let view: AnalysisView
        let title: String
        var id: UInt8 { view.code }
    }

    struct PairEntry: Equatable, Identifiable, Sendable {
        let pair: AnalysisPair
        let title: String
        var id: UInt8 { pair.rawValue }
    }

    /// `nil` transport is a stereo session.
    init(transport: ProductionTransportMeterSnapshot?) {
        guard let transport else {
            kind = .stereo
            views = [
                Entry(view: .standard, title: "Stereo"), Entry(view: .left, title: "Left"), Entry(view: .right, title: "Right"),
                Entry(view: .mid, title: "Mid"), Entry(view: .side, title: "Side"),
            ]
            pairs = []
            return
        }
        if transport.kind == .virtualSpeakers {
            kind = .binaural
            views = [Entry(view: .standard, title: "Ear pair"), Entry(view: .programme, title: "Programme (before rendering)")]
            pairs = [PairEntry(pair: .standard, title: "Ear pair"), PairEntry(pair: .programme, title: "Programme front")]
            return
        }
        kind = .wide
        let roles = Self.programRoles(of: transport.programChannels)
        let hasSubFeed = transport.physicalOutputs.contains { $0.id.hasPrefix("physical-sub-") }
        var entries = [Entry(view: .standard, title: "All")]
        for group in WideGroup.allCases {
            let present = roles.contains { WideGroup(role: $0) == group } || (group == .sub && hasSubFeed)
            if present { entries.append(Entry(view: .group(group), title: group.title)) }
        }
        for (index, channel) in transport.programChannels.enumerated() {
            entries.append(Entry(view: .speaker(index), title: channel.label))
        }
        views = entries
        let plan = WideAnalysisPlan(roles: roles, inputChannels: roles.count, outputChannels: roles.count, isBinaural: false)
        pairs = plan.availablePairs.map { PairEntry(pair: $0, title: $0.title) }
    }

    /// The programme roles named by the transport's `program-<role>` channel ids; any other id is skipped.
    static func programRoles(of channels: [ProductionTransportChannelMeter]) -> [OutputProgramRole] {
        channels.compactMap { channel in
            channel.id.hasPrefix("program-") ? OutputProgramRole(rawValue: String(channel.id.dropFirst("program-".count))) : nil
        }
    }

    /// A stored choice that this session does not offer reads as the standard one.
    func resolved(_ view: AnalysisView) -> AnalysisView { views.contains { $0.view == view } ? view : .standard }
    func resolved(_ pair: AnalysisPair) -> AnalysisPair { pairs.contains { $0.pair == pair } ? pair : .standard }
}
