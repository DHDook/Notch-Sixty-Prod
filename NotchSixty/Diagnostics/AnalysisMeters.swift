import Accelerate
import Foundation

// E33 S8 (design note 18): off-callback analysis meters. Every type here is plain Swift that runs on the
// analysis worker's queue, allocates only at construction and on a sample-rate change, and has no engine
// or flag dependency. The worker feeds them only while their card is visible.

// MARK: - Biquad design

extension LoudnessBiquad {
    /// Second-order Butterworth-family low-pass (RBJ bilinear form).
    static func lowPass(frequency: Double, q: Double, sampleRate: Double) -> LoudnessBiquad {
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        let a0 = 1 + alpha
        return LoudnessBiquad(
            b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0,
            a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> LoudnessBiquad {
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        let a0 = 1 + alpha
        return LoudnessBiquad(
            b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0,
            a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
}

// MARK: - True peak

/// 4x polyphase true-peak interpolator: a 48-tap Kaiser-windowed sinc split into four 12-tap phases, the
/// structure of ITU-R BS.1770-4 Annex 2 (which publishes its own coefficients; these are independently
/// designed). `process` returns the largest magnitude among the input sample and the three interpolated
/// points between it and the previous sample.
struct TruePeakInterpolator {
    static let factor = 4
    static let phaseLength = 12
    private static let beta = 5.0

    /// `phases[p][k]` multiplies `x[m - k]` to give the output at offset `p / 4` sample.
    private static let phases: [[Double]] = {
        let taps = factor * phaseLength
        func i0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1..<40 {
                term *= (x / (2 * Double(k))) * (x / (2 * Double(k)))
                sum += term
            }
            return sum
        }
        let centre = Double(taps - 1) / 2
        var h = (0..<taps).map { n -> Double in
            let t = (Double(n) - centre) / Double(factor)
            let sinc = abs(t) < 1e-12 ? 1.0 : sin(Double.pi * t) / (Double.pi * t)
            let r = (Double(n) - centre) / centre
            return sinc * i0(beta * (1 - r * r).squareRoot()) / i0(beta)
        }
        let total = h.reduce(0, +)
        h = h.map { $0 * Double(factor) / total }
        return (0..<factor).map { p in (0..<phaseLength).map { h[factor * $0 + p] } }
    }()

    private var history = [Double](repeating: 0, count: TruePeakInterpolator.phaseLength)
    private var position = 0

    mutating func reset() {
        for i in history.indices { history[i] = 0 }
        position = 0
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let n = Self.phaseLength
        position = (position + 1) % n
        history[position] = x
        var peak = abs(x)
        for p in 0..<Self.factor {
            var acc = 0.0
            let kernel = Self.phases[p]
            for k in 0..<n {
                acc += kernel[k] * history[(position - k + n) % n]
            }
            peak = max(peak, abs(acc))
        }
        return peak
    }
}

// MARK: - PLR, PSR and crest (D1)

struct PeakCrestReadout: Equatable, Sendable {
    /// True peak since the last Reset, dBTP; nil until a block completes.
    var truePeakMaxDBTP: Double?
    /// True peak over the last 3 s.
    var truePeakRecentDBTP: Double?
    /// Crest factor over 300 ms: sample peak minus RMS, the larger of the two channels, dB.
    var crestDB: Double?
}

/// Tracks true peak (maximum and last 3 s) and the 300 ms crest factor of a stereo pair in 100 ms blocks.
struct PeakCrestMeter {
    static let blockSeconds = 0.1
    static let recentBlocks = 30
    static let crestBlocks = 3

    let sampleRate: Double
    let blockFrames: Int
    private var interpolators = [TruePeakInterpolator(), TruePeakInterpolator()]
    private var fill = 0
    private var blockTruePeak = 0.0
    private var blockPeak = [0.0, 0.0]
    private var blockSumSquares = [0.0, 0.0]
    private var recentTruePeaks = [Double](repeating: 0, count: PeakCrestMeter.recentBlocks)
    private var crestPeaks = [[Double]](repeating: [0, 0, 0], count: 2)
    private var crestSums = [[Double]](repeating: [0, 0, 0], count: 2)
    private var completed = 0
    private var maxTruePeak = 0.0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.blockFrames = max(Int((sampleRate * Self.blockSeconds).rounded()), 1)
    }

    mutating func reset() {
        interpolators = [TruePeakInterpolator(), TruePeakInterpolator()]
        fill = 0
        blockTruePeak = 0
        blockPeak = [0, 0]
        blockSumSquares = [0, 0]
        for i in recentTruePeaks.indices { recentTruePeaks[i] = 0 }
        for c in 0..<2 { for i in 0..<Self.crestBlocks { crestPeaks[c][i] = 0; crestSums[c][i] = 0 } }
        completed = 0
        maxTruePeak = 0
    }

    mutating func process(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        let frames = min(left.count, right.count)
        for i in 0..<frames {
            let l = Double(left[i]), r = Double(right[i])
            blockTruePeak = max(blockTruePeak, interpolators[0].process(l), interpolators[1].process(r))
            blockPeak[0] = max(blockPeak[0], abs(l))
            blockPeak[1] = max(blockPeak[1], abs(r))
            blockSumSquares[0] += l * l
            blockSumSquares[1] += r * r
            fill += 1
            if fill == blockFrames { completeBlock() }
        }
    }

    mutating func process(left: [Float], right: [Float]) {
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in process(left: l, right: r) }
        }
    }

    private mutating func completeBlock() {
        let slot = completed % Self.recentBlocks
        recentTruePeaks[slot] = blockTruePeak
        maxTruePeak = max(maxTruePeak, blockTruePeak)
        let crestSlot = completed % Self.crestBlocks
        for c in 0..<2 {
            crestPeaks[c][crestSlot] = blockPeak[c]
            crestSums[c][crestSlot] = blockSumSquares[c]
        }
        completed += 1
        fill = 0
        blockTruePeak = 0
        blockPeak = [0, 0]
        blockSumSquares = [0, 0]
    }

    func readout() -> PeakCrestReadout {
        guard completed > 0 else { return PeakCrestReadout() }
        func dbtp(_ linear: Double) -> Double? { linear > 1e-9 ? 20 * log10(linear) : nil }
        let recentCount = min(completed, Self.recentBlocks)
        var recent = 0.0
        for i in 0..<recentCount { recent = max(recent, recentTruePeaks[i]) }

        var crest: Double?
        if completed >= Self.crestBlocks {
            let frames = Double(Self.crestBlocks * blockFrames)
            for c in 0..<2 {
                let peak = crestPeaks[c].max() ?? 0
                let rms = (crestSums[c].reduce(0, +) / frames).squareRoot()
                guard rms > 1e-9, peak > 0 else { continue }
                let value = 20 * log10(peak / rms)
                crest = max(crest ?? -.infinity, value)
            }
        }
        return PeakCrestReadout(
            truePeakMaxDBTP: dbtp(maxTruePeak),
            truePeakRecentDBTP: dbtp(recent),
            crestDB: crest)
    }

    /// PLR = true-peak maximum minus integrated loudness; PSR = true peak (last 3 s) minus short-term loudness.
    static func plr(truePeakMaxDBTP: Double?, integratedLUFS: Double?) -> Double? {
        guard let truePeakMaxDBTP, let integratedLUFS else { return nil }
        return truePeakMaxDBTP - integratedLUFS
    }
}

// MARK: - Balance (D5)

/// K-weighted short-term (3 s) level difference, left minus right, in dB.
struct BalanceMeter {
    static let subBlocks = 30
    static let minimumBlocks = 10
    static let clampDB = 30.0

    let sampleRate: Double
    let blockFrames: Int
    private var filters: [KWeightingFilter]
    private var fill = 0
    private var sums = [0.0, 0.0]
    private var ring = [[Double]](repeating: [Double](repeating: 0, count: BalanceMeter.subBlocks), count: 2)
    private var completed = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.blockFrames = max(Int((sampleRate * 0.1).rounded()), 1)
        self.filters = [KWeightingFilter(sampleRate: sampleRate), KWeightingFilter(sampleRate: sampleRate)]
    }

    mutating func reset() {
        for i in filters.indices { filters[i].reset() }
        fill = 0
        sums = [0, 0]
        completed = 0
        for c in 0..<2 { for i in 0..<Self.subBlocks { ring[c][i] = 0 } }
    }

    mutating func process(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        let frames = min(left.count, right.count)
        for i in 0..<frames {
            let l = filters[0].process(Double(left[i]))
            let r = filters[1].process(Double(right[i]))
            sums[0] += l * l
            sums[1] += r * r
            fill += 1
            if fill == blockFrames {
                let slot = completed % Self.subBlocks
                ring[0][slot] = sums[0] / Double(blockFrames)
                ring[1][slot] = sums[1] / Double(blockFrames)
                completed += 1
                fill = 0
                sums = [0, 0]
            }
        }
    }

    mutating func process(left: [Float], right: [Float]) {
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in process(left: l, right: r) }
        }
    }

    /// nil until one second is measured or while both sides are silent. One silent side clamps to +/-30 dB.
    func balanceDB() -> Double? {
        guard completed >= Self.minimumBlocks else { return nil }
        let count = min(completed, Self.subBlocks)
        var left = 0.0, right = 0.0
        for i in 0..<count { left += ring[0][i]; right += ring[1][i] }
        left /= Double(count); right /= Double(count)
        guard max(left, right) > 1e-12 else { return nil }
        let floor = max(max(left, right) * 1e-9, 1e-15)
        let value = 10 * log10(max(left, floor) / max(right, floor))
        return min(max(value, -Self.clampDB), Self.clampDB)
    }
}

// MARK: - Per-band correlation (D6)

/// L/R correlation in three bands split at 200 Hz and 2 kHz with 4th-order Linkwitz-Riley crossovers, over
/// a 300 ms window (six 50 ms blocks). Each band reads -1...+1; nil while a band is silent or filling.
struct BandCorrelationMeter {
    static let splitFrequencies = [200.0, 2_000.0]
    static let blockSeconds = 0.05
    static let blocks = 6
    static let bandCount = 3

    private struct Crossover {
        var low: [LoudnessBiquad]
        var high: [LoudnessBiquad]

        init(frequency: Double, sampleRate: Double) {
            let q = 0.5.squareRoot()
            low = [LoudnessBiquad.lowPass(frequency: frequency, q: q, sampleRate: sampleRate),
                   LoudnessBiquad.lowPass(frequency: frequency, q: q, sampleRate: sampleRate)]
            high = [LoudnessBiquad.highPass(frequency: frequency, q: q, sampleRate: sampleRate),
                    LoudnessBiquad.highPass(frequency: frequency, q: q, sampleRate: sampleRate)]
        }

        mutating func split(_ x: Double) -> (low: Double, high: Double) {
            (low[1].process(low[0].process(x)), high[1].process(high[0].process(x)))
        }
    }

    let sampleRate: Double
    let blockFrames: Int
    /// Crossovers per channel: index 0 splits at 200 Hz, index 1 splits the upper part at 2 kHz.
    private var lower: [Crossover]
    private var upper: [Crossover]
    private var fill = 0
    private var cross = [Double](repeating: 0, count: bandCount)
    private var leftEnergy = [Double](repeating: 0, count: bandCount)
    private var rightEnergy = [Double](repeating: 0, count: bandCount)
    private var ring = [[Double]](repeating: [Double](repeating: 0, count: BandCorrelationMeter.blocks * 3),
                                  count: BandCorrelationMeter.bandCount)
    private var completed = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.blockFrames = max(Int((sampleRate * Self.blockSeconds).rounded()), 1)
        let low = Self.splitFrequencies[0], high = Self.splitFrequencies[1]
        lower = [Crossover(frequency: low, sampleRate: sampleRate), Crossover(frequency: low, sampleRate: sampleRate)]
        upper = [Crossover(frequency: high, sampleRate: sampleRate), Crossover(frequency: high, sampleRate: sampleRate)]
    }

    mutating func reset() {
        self = BandCorrelationMeter(sampleRate: sampleRate)
    }

    private mutating func bands(channel: Int, _ x: Double) -> (Double, Double, Double) {
        let first = lower[channel].split(x)
        let second = upper[channel].split(first.high)
        return (first.low, second.low, second.high)
    }

    mutating func process(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        let frames = min(left.count, right.count)
        for i in 0..<frames {
            let l = bands(channel: 0, Double(left[i]))
            let r = bands(channel: 1, Double(right[i]))
            cross[0] += l.0 * r.0; leftEnergy[0] += l.0 * l.0; rightEnergy[0] += r.0 * r.0
            cross[1] += l.1 * r.1; leftEnergy[1] += l.1 * l.1; rightEnergy[1] += r.1 * r.1
            cross[2] += l.2 * r.2; leftEnergy[2] += l.2 * l.2; rightEnergy[2] += r.2 * r.2
            fill += 1
            if fill == blockFrames {
                let slot = completed % Self.blocks
                for b in 0..<Self.bandCount {
                    ring[b][slot * 3] = cross[b]
                    ring[b][slot * 3 + 1] = leftEnergy[b]
                    ring[b][slot * 3 + 2] = rightEnergy[b]
                    cross[b] = 0; leftEnergy[b] = 0; rightEnergy[b] = 0
                }
                completed += 1
                fill = 0
            }
        }
    }

    mutating func process(left: [Float], right: [Float]) {
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in process(left: l, right: r) }
        }
    }

    func correlations() -> [Double?] {
        guard completed >= Self.blocks else { return [Double?](repeating: nil, count: Self.bandCount) }
        return (0..<Self.bandCount).map { b in
            var c = 0.0, l = 0.0, r = 0.0
            for slot in 0..<Self.blocks {
                c += ring[b][slot * 3]; l += ring[b][slot * 3 + 1]; r += ring[b][slot * 3 + 2]
            }
            let denominator = (l * r).squareRoot()
            guard denominator > 1e-12 else { return nil }
            return min(max(c / denominator, -1), 1)
        }
    }
}

// MARK: - Headroom strip (D7)

/// One point on the headroom strip: where in the chain, and the peak with its hold.
struct HeadroomPoint: Equatable, Sendable {
    let id: String
    let title: String
    var peakDBFS: Double
    var holdDBFS: Double
    /// Distance below full scale, dB (never negative).
    var headroomDB: Double { max(-holdDBFS, 0) }
}

/// Peak hold at the input, post-EQ and output meter points, from the hub's own readings (no second reader).
/// The post-dynamics point joins when the analyser tap feeds it (`docs/epics/E33.md` Gaps).
struct HeadroomStripModel: Equatable, Sendable {
    static let floorDB = -120.0
    private(set) var points: [HeadroomPoint] = [
        HeadroomPoint(id: "input", title: "Input", peakDBFS: floorDB, holdDBFS: floorDB),
        HeadroomPoint(id: "postEQ", title: "Post-EQ", peakDBFS: floorDB, holdDBFS: floorDB),
        HeadroomPoint(id: "output", title: "Output", peakDBFS: floorDB, holdDBFS: floorDB),
    ]

    /// `peaks` are linear maxima since the last call (the hub's read-and-reset values), keyed by point id.
    mutating func update(peaks: [String: Float]) {
        for i in points.indices {
            guard let linear = peaks[points[i].id] else { continue }
            let db = linear > 1e-6 ? max(20 * Double(log10(linear)), Self.floorDB) : Self.floorDB
            points[i].peakDBFS = db
            points[i].holdDBFS = max(points[i].holdDBFS, db)
        }
    }

    mutating func reset() {
        for i in points.indices { points[i].holdDBFS = Self.floorDB; points[i].peakDBFS = Self.floorDB }
    }
}

// MARK: - Dropout counter

/// Dropout events, frames and last time from the transport's cumulative underrun and overrun frame counts.
/// An event is one observation in which either count rose. Reset clears the totals and rebaselines.
struct DropoutCounter: Equatable, Sendable {
    private(set) var events = 0
    private(set) var frames: UInt64 = 0
    private(set) var lastEvent: Date?
    private var lastUnderrun: UInt64?
    private var lastOverrun: UInt64?

    mutating func observe(underrunFrames: UInt64, overrunFrames: UInt64, now: Date) {
        defer { lastUnderrun = underrunFrames; lastOverrun = overrunFrames }
        guard let lastUnderrun, let lastOverrun else { return }
        // A lower count means a new transport session: rebaseline without an event.
        guard underrunFrames >= lastUnderrun, overrunFrames >= lastOverrun else { return }
        let delta = (underrunFrames - lastUnderrun) + (overrunFrames - lastOverrun)
        guard delta > 0 else { return }
        events += 1
        frames += delta
        lastEvent = now
    }

    mutating func reset() {
        events = 0
        frames = 0
        lastEvent = nil
        lastUnderrun = nil
        lastOverrun = nil
    }
}

// MARK: - Third-octave RTA (D8)

/// Fractional-bin integration of one-sided FFT bin power into IEC 61260 third-octave bands.
struct RTABandMap {
    let startBin: [Int]
    let weights: [[Double]]

    /// Index `n` -> centre `1000 * 10^(n/10)`, n = -17...13 (20 Hz...19.95 kHz).
    static let bandIndices = Array(-17...13)
    static let bandCount = 31
    static func centre(_ n: Int) -> Double { 1_000 * pow(10, Double(n) / 10) }
    static let nominal: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
        1_000, 1_250, 1_600, 2_000, 2_500, 3_150, 4_000, 5_000, 6_300, 8_000, 10_000, 12_500, 16_000, 20_000,
    ]

    /// `indices` selects bands; bins are `fft / sampleRate` apart for a transform of `size` samples.
    init(indices: [Int], size: Int, sampleRate: Double) {
        let df = sampleRate / Double(size)
        let top = size / 2
        var starts: [Int] = []
        var all: [[Double]] = []
        let edge = pow(10, 0.05)
        for n in indices {
            let fc = Self.centre(n)
            let lo = fc / edge / df, hi = fc * edge / df
            let first = max(Int((lo + 0.5).rounded(.down)), 1)
            let last = min(Int((hi + 0.5).rounded(.down)), top - 1)
            var w: [Double] = []
            if first <= last {
                for k in first...last {
                    let overlap = min(hi, Double(k) + 0.5) - max(lo, Double(k) - 0.5)
                    w.append(max(overlap, 0))
                }
            }
            starts.append(first)
            all.append(w)
        }
        startBin = starts
        weights = all
    }

    /// `spectrum[k]` is the power of bin k in sine-power units (a sine of amplitude A sums to A^2/2).
    func integrate(_ spectrum: UnsafeBufferPointer<Double>, into out: inout [Double]) {
        for b in 0..<weights.count {
            var sum = 0.0
            let start = startBin[b]
            for (i, w) in weights[b].enumerated() where start + i < spectrum.count {
                sum += w * spectrum[start + i]
            }
            out[b] = sum
        }
    }
}

/// 31 third-octave bars, 20 Hz to 20 kHz. Bands from 1 kHz up come from an FFT of the full-rate signal
/// (about 50 Hz bins); the 17 bands below 1 kHz come from a second 32,768-point FFT of the signal decimated
/// to at most 50 kHz, so a 20 Hz band spans at least three bins at every device rate.
final class ThirdOctaveRTA {
    static let lowSize = 32_768
    static let lowBandCount = 17
    static let floorDB: Float = -120

    let sampleRate: Double
    let decimation: Int
    let highSize: Int

    private let lowRate: Double
    private let lowMap: RTABandMap
    private let highMap: RTABandMap
    private var lowFilters: [[LoudnessBiquad]]
    private var decimationPhase = 0
    private var lowRings: [[Float]]
    private var highRings: [[Float]]
    private var lowWrite = 0
    private var highWrite = 0
    private var lowCount = 0
    private var highCount = 0

    private let lowSetup: FFTSetup
    private let highSetup: FFTSetup
    private let lowWindow: [Float]
    private let highWindow: [Float]
    private let lowWindowPower: Double
    private let highWindowPower: Double
    private var work: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var lowPower: [Double]
    private var highPower: [Double]
    private var lowBands: [Double]
    private var highBands: [Double]

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        var d = 1
        while sampleRate / Double(d) > 50_000 { d *= 2 }
        decimation = d
        lowRate = sampleRate / Double(d)
        var size = 256
        while Double(size) < sampleRate / 50 { size *= 2 }
        highSize = size

        let lowIndices = Array(RTABandMap.bandIndices.prefix(Self.lowBandCount))
        let highIndices = Array(RTABandMap.bandIndices.dropFirst(Self.lowBandCount))
        lowMap = RTABandMap(indices: lowIndices, size: Self.lowSize, sampleRate: lowRate)
        highMap = RTABandMap(indices: highIndices, size: size, sampleRate: sampleRate)

        // 8th-order Butterworth anti-alias filter at a quarter of the decimated rate (none when d == 1).
        let qs = [0.5098, 0.6013, 0.9000, 2.5629]
        let cutoff = lowRate * 0.25
        lowFilters = (0..<2).map { _ in
            d == 1 ? [] : qs.map { LoudnessBiquad.lowPass(frequency: cutoff, q: $0, sampleRate: sampleRate) }
        }
        lowRings = [[Float]](repeating: [Float](repeating: 0, count: Self.lowSize), count: 2)
        highRings = [[Float]](repeating: [Float](repeating: 0, count: size), count: 2)

        func hann(_ n: Int) -> [Float] {
            (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        }
        lowWindow = hann(Self.lowSize)
        highWindow = hann(size)
        lowWindowPower = lowWindow.reduce(0.0) { $0 + Double($1) * Double($1) }
        highWindowPower = highWindow.reduce(0.0) { $0 + Double($1) * Double($1) }
        lowSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(Self.lowSize))), FFTRadix(kFFTRadix2))!
        highSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(size))), FFTRadix(kFFTRadix2))!
        work = [Float](repeating: 0, count: Self.lowSize)
        real = [Float](repeating: 0, count: Self.lowSize / 2)
        imag = [Float](repeating: 0, count: Self.lowSize / 2)
        lowPower = [Double](repeating: 0, count: Self.lowSize / 2 + 1)
        highPower = [Double](repeating: 0, count: size / 2 + 1)
        lowBands = [Double](repeating: 0, count: lowMap.weights.count)
        highBands = [Double](repeating: 0, count: highMap.weights.count)
    }

    deinit {
        vDSP_destroy_fftsetup(lowSetup)
        vDSP_destroy_fftsetup(highSetup)
    }

    func reset() {
        for c in 0..<2 {
            for i in lowRings[c].indices { lowRings[c][i] = 0 }
            for i in highRings[c].indices { highRings[c][i] = 0 }
            for f in lowFilters[c].indices { lowFilters[c][f].reset() }
        }
        lowWrite = 0; highWrite = 0; lowCount = 0; highCount = 0; decimationPhase = 0
    }

    func ingest(left: [Float], right: [Float]) {
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in ingest(left: l, right: r) }
        }
    }

    func ingest(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        let frames = min(left.count, right.count)
        for i in 0..<frames {
            highRings[0][highWrite] = left[i]
            highRings[1][highWrite] = right[i]
            highWrite += 1
            if highWrite == highSize { highWrite = 0 }
            if highCount < highSize { highCount += 1 }

            var l = Double(left[i]), r = Double(right[i])
            if decimation > 1 {
                for f in 0..<lowFilters[0].count {
                    l = lowFilters[0][f].process(l)
                    r = lowFilters[1][f].process(r)
                }
            }
            decimationPhase += 1
            if decimationPhase >= decimation {
                decimationPhase = 0
                lowRings[0][lowWrite] = Float(l)
                lowRings[1][lowWrite] = Float(r)
                lowWrite += 1
                if lowWrite == Self.lowSize { lowWrite = 0 }
                if lowCount < Self.lowSize { lowCount += 1 }
            }
        }
    }

    /// Band levels in dBFS (a full-scale sine reads 0 dB in its band), 31 values, or nil until both rings fill.
    /// Left and right are combined by averaging power.
    func bandLevelsDB() -> [Float]? {
        guard lowCount == Self.lowSize, highCount == highSize else { return nil }
        accumulate(rings: lowRings, write: lowWrite, size: Self.lowSize, window: lowWindow,
                   windowPower: lowWindowPower, setup: lowSetup, into: &lowPower)
        accumulate(rings: highRings, write: highWrite, size: highSize, window: highWindow,
                   windowPower: highWindowPower, setup: highSetup, into: &highPower)
        lowPower.withUnsafeBufferPointer { lowMap.integrate($0, into: &lowBands) }
        highPower.withUnsafeBufferPointer { highMap.integrate($0, into: &highBands) }
        return Self.levelsDB(low: lowBands, high: highBands)
    }

    static func levelsDB(low: [Double], high: [Double]) -> [Float] {
        (low + high).map { power in
            power > 1e-18 ? max(Float(10 * log10(power * 2)), floorDB) : floorDB
        }
    }

    private func accumulate(
        rings: [[Float]], write: Int, size: Int, window: [Float], windowPower: Double,
        setup: FFTSetup, into power: inout [Double]
    ) {
        for k in power.indices { power[k] = 0 }
        let scale = 2.0 / (Double(size) * windowPower) / 2.0   // one-sided, then the mean of two channels
        let half = size / 2
        for c in 0..<2 {
            for i in 0..<size { work[i] = rings[c][(write + i) % size] * window[i] }
            work.withUnsafeBufferPointer { src in
                real.withUnsafeMutableBufferPointer { re in
                    imag.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(size))), FFTDirection(kFFTDirection_Forward))
                    }
                }
            }
            // vDSP's packed real transform is scaled by 2: |X|^2 = (re^2 + im^2) / 4.
            for k in 1..<half {
                let re = Double(real[k]), im = Double(imag[k])
                power[k] += (re * re + im * im) / 4 * scale
            }
        }
    }
}

// MARK: - Worker feed

struct AnalysisMeterReadout: Equatable, Sendable {
    /// True peak maximum since Reset, dBTP, minus integrated loudness (output).
    var plr: Double?
    /// True peak over the last 3 s minus short-term loudness.
    var psr: Double?
    var crestDB: Double?
    var truePeakMaxDBTP: Double?
    var truePeakRecentDBTP: Double?
    /// K-weighted short-term left minus right, dB.
    var balanceDB: Double?
    /// Low (below 200 Hz), mid (200 Hz to 2 kHz), high (above 2 kHz).
    var correlation: [Double?] = [nil, nil, nil]
}

/// Owns the D1, D5, D6 and D8 meters for one transport session and feeds them from the analysis capture's
/// output channels. Each part runs only while its card is visible (`setActive`); a hidden part keeps no
/// state and does no work. Separate from the worker so it is testable without a bridge.
final class ProductionAnalysisMeterFeed {
    private var peakCrest: PeakCrestMeter?
    private var balance: BalanceMeter?
    private var correlation: BandCorrelationMeter?
    private var rta: ThirdOctaveRTA?
    private var metersActive = false
    private var rtaActive = false
    private var rate = 0.0
    private var left: [Float] = []
    private var right: [Float] = []

    var isMeterActive: Bool { metersActive }
    var isRTAActive: Bool { rtaActive }

    func setActive(meters: Bool, rta wantsRTA: Bool, sampleRate: Double) {
        guard sampleRate > 0 else { return }
        if rate != sampleRate {
            peakCrest = nil; balance = nil; correlation = nil; rta = nil
            rate = sampleRate
        }
        if meters {
            if peakCrest == nil {
                peakCrest = PeakCrestMeter(sampleRate: sampleRate)
                balance = BalanceMeter(sampleRate: sampleRate)
                correlation = BandCorrelationMeter(sampleRate: sampleRate)
            }
        } else {
            peakCrest = nil; balance = nil; correlation = nil
        }
        if wantsRTA {
            if rta == nil { rta = ThirdOctaveRTA(sampleRate: sampleRate) }
        } else {
            rta = nil
        }
        metersActive = meters
        rtaActive = wantsRTA
    }

    func reset() {
        peakCrest?.reset(); balance?.reset(); correlation?.reset()
    }

    func ingest(_ frames: UnsafeBufferPointer<N60AnalysisFrame>) {
        guard (metersActive || rtaActive), !frames.isEmpty else { return }
        let count = frames.count
        if left.count < count {
            left = [Float](repeating: 0, count: count)
            right = [Float](repeating: 0, count: count)
        }
        for i in 0..<count {
            left[i] = frames[i].outputLeft
            right[i] = frames[i].outputRight
        }
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                let lv = UnsafeBufferPointer(rebasing: l[0..<count])
                let rv = UnsafeBufferPointer(rebasing: r[0..<count])
                if metersActive {
                    peakCrest?.process(left: lv, right: rv)
                    balance?.process(left: lv, right: rv)
                    correlation?.process(left: lv, right: rv)
                }
                if rtaActive { rta?.ingest(left: lv, right: rv) }
            }
        }
    }

    func meterReadout(loudness: LoudnessReadout?) -> AnalysisMeterReadout? {
        guard metersActive, let peakCrest, let balance, let correlation else { return nil }
        let peaks = peakCrest.readout()
        var out = AnalysisMeterReadout()
        out.truePeakMaxDBTP = peaks.truePeakMaxDBTP
        out.truePeakRecentDBTP = peaks.truePeakRecentDBTP
        out.crestDB = peaks.crestDB
        out.plr = PeakCrestMeter.plr(truePeakMaxDBTP: peaks.truePeakMaxDBTP, integratedLUFS: loudness?.integrated)
        if let recent = peaks.truePeakRecentDBTP, let shortTerm = loudness?.shortTerm {
            out.psr = recent - shortTerm
        }
        out.balanceDB = balance.balanceDB()
        out.correlation = correlation.correlations()
        return out
    }

    func rtaLevels() -> [Float] {
        guard rtaActive, let levels = rta?.bandLevelsDB() else { return [] }
        return levels
    }
}
