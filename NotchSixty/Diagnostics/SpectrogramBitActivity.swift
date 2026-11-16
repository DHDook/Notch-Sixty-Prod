import Accelerate
import Foundation

// E33 S9 (design note 18, D2 and D3): the spectrogram and the bit-activity meter. Plain Swift on the analysis
// worker's queue; allocates only at construction and on a sample-rate or window change, never per frame. The
// worker feeds them only while their card is visible. No engine or flag dependency.

// MARK: - D2 spectrogram

enum SpectrogramWindow: String, CaseIterable, Sendable {
    case tenSeconds, sixtySeconds

    var seconds: Double { self == .tenSeconds ? 10 : 60 }
    var title: String { self == .tenSeconds ? "10 s" : "60 s" }
}

/// An immutable copy of the image ring for drawing. Column-major, `rows` bytes per column; row 0 is the lowest
/// frequency. Column `totalColumns % columns` is the oldest once the ring is full.
struct SpectrogramSnapshot: Equatable, Sendable {
    var image: [UInt8]
    var rows: Int
    var columns: Int
    /// Columns written since the feed started; the newest column index is `totalColumns - 1`.
    var totalColumns: Int
    var window: SpectrogramWindow
    var minHz: Double
    var maxHz: Double
    /// FFT bin spacing, Hz.
    var binHz: Double

    /// RGBA pixels, `columns` wide and `rows` high, oldest column on the left and the lowest frequency at the bottom.
    func rgbaPixels() -> [UInt8] {
        guard rows > 0, columns > 0, image.count == rows * columns else { return [] }
        var out = [UInt8](repeating: 0, count: rows * columns * 4)
        let oldest = totalColumns >= columns ? totalColumns % columns : 0
        let lut = SpectrogramColourMap.table
        for x in 0..<columns {
            let source = ((oldest + x) % columns) * rows
            let written = totalColumns >= columns || x < totalColumns
            for r in 0..<rows {
                let level = written ? Int(image[source + r]) : 0
                let o = ((rows - 1 - r) * columns + x) * 4
                out[o] = lut[level * 3]; out[o + 1] = lut[level * 3 + 1]; out[o + 2] = lut[level * 3 + 2]; out[o + 3] = 255
            }
        }
        return out
    }

    /// The row whose band contains `hz`, or nil outside the displayed range.
    func row(forHz hz: Double) -> Int? {
        guard hz >= minHz, hz <= maxHz, rows > 1 else { return nil }
        let t = log(hz / minHz) / log(maxHz / minHz)
        return min(max(Int((t * Double(rows - 1)).rounded()), 0), rows - 1)
    }
}

/// Viridis-style perceptually uniform map, 256 entries of RGB, from nine published anchor colours.
enum SpectrogramColourMap {
    static let table: [UInt8] = {
        let anchors: [(Double, Double, Double)] = [
            (68, 1, 84), (71, 44, 122), (59, 81, 139), (44, 113, 142), (33, 144, 141),
            (39, 173, 129), (92, 200, 99), (170, 220, 50), (253, 231, 37),
        ]
        var out = [UInt8](repeating: 0, count: 256 * 3)
        for i in 0..<256 {
            let position = Double(i) / 255 * Double(anchors.count - 1)
            let k = min(Int(position), anchors.count - 2)
            let f = position - Double(k)
            let a = anchors[k], b = anchors[k + 1]
            out[i * 3] = UInt8((a.0 + (b.0 - a.0) * f).rounded())
            out[i * 3 + 1] = UInt8((a.1 + (b.1 - a.1) * f).rounded())
            out[i * 3 + 2] = UInt8((a.2 + (b.2 - a.2) * f).rounded())
        }
        return out
    }()
}

/// Worker FFT frames into a ring image, log frequency 20 Hz to 20 kHz (or to 0.45 of the rate when lower).
/// Levels are mono (mean of the two channels), Hann-windowed, one-sided: a full-scale sine reads 0 dBFS,
/// stored as `(dBFS + 100) / 100` in 0...255.
final class SpectrogramRing {
    static let rows = 192
    static let columns = 480
    static let floorDB: Float = -100

    let sampleRate: Double
    let window: SpectrogramWindow
    let fftSize: Int
    /// Samples between columns.
    let hop: Int
    let minHz = 20.0
    let maxHz: Double

    private let rowLow: [Int]
    private let rowHigh: [Int]
    private let log2Size: vDSP_Length
    private let setup: FFTSetup
    private let hann: [Float]
    private let invWindowSum: Float
    private var samples: [Float]
    private var write = 0
    private var total = 0
    private var sinceColumn = 0
    private var work: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var image: [UInt8]
    private(set) var totalColumns = 0

    /// Sample count at which column `index` (counting from 0) is complete.
    static func columnEndSample(index: Int, fftSize: Int, hop: Int) -> Int {
        ((fftSize + hop - 1) / hop + index) * hop
    }

    init(sampleRate: Double, window: SpectrogramWindow) {
        self.sampleRate = sampleRate
        self.window = window
        let size = ProductionAnalysisMath.fftSize(sampleRate: sampleRate)
        fftSize = size
        hop = max(Int((window.seconds * sampleRate / Double(Self.columns)).rounded()), 1)
        maxHz = min(20_000, sampleRate * 0.45)
        let binHz = sampleRate / Double(fftSize)
        let ratio = pow(maxHz / minHz, 1 / Double(Self.rows - 1))
        var lows = [Int](), highs = [Int]()
        for r in 0..<Self.rows {
            let centre = minHz * pow(ratio, Double(r))
            let lo = Int((centre / sqrt(ratio) / binHz).rounded(.down))
            let hi = Int((centre * sqrt(ratio) / binHz).rounded(.up))
            let low = min(max(lo, 1), fftSize / 2 - 1)
            lows.append(low)
            highs.append(min(max(hi, low), fftSize / 2 - 1))
        }
        rowLow = lows
        rowHigh = highs
        log2Size = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
        hann = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
        invWindowSum = 1 / hann.reduce(0, +)
        samples = [Float](repeating: 0, count: fftSize)
        work = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
        image = [UInt8](repeating: 0, count: Self.rows * Self.columns)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    var binHz: Double { sampleRate / Double(fftSize) }

    /// Address of the image storage; the tests compare it across ingests to show the ring never reallocates.
    var imageStorageAddress: UnsafeRawPointer? {
        image.withUnsafeBytes { $0.baseAddress }
    }

    func reset() {
        for i in samples.indices { samples[i] = 0 }
        for i in image.indices { image[i] = 0 }
        write = 0; total = 0; sinceColumn = 0; totalColumns = 0
    }

    func ingest(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        for i in 0..<min(left.count, right.count) { push(0.5 * (left[i] + right[i])) }
    }

    func ingest(_ frames: UnsafeBufferPointer<N60AnalysisFrame>) {
        for frame in frames { push(0.5 * (frame.outputLeft + frame.outputRight)) }
    }

    private func push(_ sample: Float) {
        samples[write] = sample
        write += 1
        if write == fftSize { write = 0 }
        total += 1
        sinceColumn += 1
        if sinceColumn >= hop && total >= fftSize {
            sinceColumn = 0
            writeColumn()
        }
    }

    private func writeColumn() {
        // Newest fftSize samples in time order, windowed.
        let tail = fftSize - write
        samples.withUnsafeBufferPointer { s in
            work.withUnsafeMutableBufferPointer { w in
                hann.withUnsafeBufferPointer { h in
                    vDSP_vmul(s.baseAddress! + write, 1, h.baseAddress!, 1, w.baseAddress!, 1, vDSP_Length(tail))
                    if write > 0 {
                        vDSP_vmul(s.baseAddress!, 1, h.baseAddress! + tail, 1, w.baseAddress! + tail, 1, vDSP_Length(write))
                    }
                }
            }
        }
        let half = fftSize / 2
        work.withUnsafeBufferPointer { src in
            real.withUnsafeMutableBufferPointer { re in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(kFFTDirection_Forward))
                    // The packed real transform is scaled by 2, so |packed| / sum(window) is the sine amplitude.
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                }
            }
        }
        let scale = invWindowSum * invWindowSum
        let column = (totalColumns % Self.columns) * Self.rows
        for r in 0..<Self.rows {
            var peak: Float = 0
            for k in rowLow[r]...rowHigh[r] where power[k] > peak { peak = power[k] }
            let db = peak > 0 ? 10 * log10(peak * scale) : Self.floorDB
            let level = min(max((db - Self.floorDB) / -Self.floorDB, 0), 1)
            image[column + r] = UInt8((level * 255).rounded())
        }
        totalColumns += 1
    }

    func snapshot() -> SpectrogramSnapshot {
        SpectrogramSnapshot(
            image: image, rows: Self.rows, columns: Self.columns, totalColumns: totalColumns,
            window: window, minHz: minHz, maxHz: maxHz, binHz: binHz
        )
    }

    /// Centre frequency of a row, Hz.
    func rowCentreHz(_ row: Int) -> Double {
        minHz * pow(maxHz / minHz, Double(row) / Double(Self.rows - 1))
    }
}

// MARK: - D3 bit activity

struct BitActivityChannel: Equatable, Sendable {
    /// Bit i (0 = least significant) is set when that bit of the 24-bit two's-complement sample has been both 0
    /// and 1 since the reset.
    var toggledMask: UInt32 = 0
    /// Lowest set bit seen, from which the effective depth follows; nil until a non-zero sample.
    var depthBits: Int?
    /// True when every bit toggles but the sample values sit on a coarser lattice (a gain-scaled shorter word).
    var scaledStepLSB: Double?
    var samples: Int = 0

    static let bits = 24

    var toggledCount: Int { toggledMask.nonzeroBitCount }

    enum Verdict: Equatable, Sendable {
        case silent
        case exact(bits: Int)
        case scaled(approximateBits: Int)
    }

    var verdict: Verdict {
        guard let depthBits else { return .silent }
        if let step = scaledStepLSB {
            return .scaled(approximateBits: max(Int((24 - log2(max(step, 1))).rounded()), 1))
        }
        return .exact(bits: depthBits)
    }

    var text: String {
        switch verdict {
        case .silent: return "No signal"
        case .exact(let bits): return "\(bits)-bit content"
        case .scaled(let bits): return "Scaled, not bit-exact (about \(bits)-bit)"
        }
    }
}

/// Which of 24 fixed-point bits toggle per channel, and the effective word depth. Samples are the program
/// input, converted as `round(x * 2^23)` clamped to the 24-bit range.
struct BitActivityMeter {
    static let latticeWindow = 8_192

    private var seenOne: [UInt32] = [0, 0]
    private var seenZero: [UInt32] = [0, 0]
    private var counts = [0, 0]
    private var recent: [[Int32]]
    private var recentWrite = [0, 0]
    private var recentCount = [0, 0]

    init() {
        recent = [[Int32](repeating: 0, count: Self.latticeWindow), [Int32](repeating: 0, count: Self.latticeWindow)]
    }

    mutating func reset() {
        seenOne = [0, 0]; seenZero = [0, 0]; counts = [0, 0]; recentWrite = [0, 0]; recentCount = [0, 0]
    }

    static func fixedPoint(_ x: Float) -> Int32 {
        let scaled = (Double(x) * 8_388_608).rounded()
        return Int32(min(max(scaled, -8_388_608), 8_388_607))
    }

    mutating func process(channel c: Int, samples: UnsafeBufferPointer<Float>) {
        for x in samples { push(channel: c, Self.fixedPoint(x)) }
    }

    mutating func process(left: [Float], right: [Float]) {
        left.withUnsafeBufferPointer { process(channel: 0, samples: $0) }
        right.withUnsafeBufferPointer { process(channel: 1, samples: $0) }
    }

    mutating func process(_ frames: UnsafeBufferPointer<N60AnalysisFrame>) {
        for frame in frames {
            push(channel: 0, Self.fixedPoint(frame.inputLeft))
            push(channel: 1, Self.fixedPoint(frame.inputRight))
        }
    }

    private mutating func push(channel c: Int, _ q: Int32) {
        let v = UInt32(bitPattern: q) & 0xFF_FFFF
        seenOne[c] |= v
        seenZero[c] |= ~v & 0xFF_FFFF
        counts[c] += 1
        recent[c][recentWrite[c]] = q
        recentWrite[c] += 1
        if recentWrite[c] == Self.latticeWindow { recentWrite[c] = 0 }
        if recentCount[c] < Self.latticeWindow { recentCount[c] += 1 }
    }

    func readout() -> [BitActivityChannel] {
        (0..<2).map { c in
            var channel = BitActivityChannel()
            channel.samples = counts[c]
            channel.toggledMask = seenOne[c] & seenZero[c]
            guard seenOne[c] != 0 else { return channel }
            channel.depthBits = max(24 - seenOne[c].trailingZeroBitCount, 1)
            // The least significant bit toggles, so the word is not simply shorter: test for a coarser lattice.
            if seenOne[c] & 1 != 0 { channel.scaledStepLSB = latticeStep(channel: c) }
            return channel
        }
    }

    /// The step, in 24-bit LSBs, of a lattice every consecutive-sample difference sits on, when one exists and is
    /// at least 8 LSBs (a gain-scaled 20-bit or shorter word). Differences are fitted in ascending order so the
    /// step estimate sharpens before it must predict the large ones.
    private func latticeStep(channel c: Int) -> Double? {
        let n = recentCount[c]
        guard n > 512 else { return nil }
        let start = n == Self.latticeWindow ? recentWrite[c] : 0
        var diffs = [Int32]()
        diffs.reserveCapacity(n)
        var previous = recent[c][start]
        for i in 1..<n {
            let x = recent[c][(start + i) % Self.latticeWindow]
            let d = abs(x - previous)
            if d != 0 { diffs.append(d) }
            previous = x
        }
        guard diffs.count > 256 else { return nil }
        diffs.sort()
        // Candidate step: the smallest gap between neighbouring differences that is more than rounding jitter.
        var smallestGap = Int32.max
        for i in 1..<diffs.count {
            let gap = diffs[i] - diffs[i - 1]
            if gap > 6 && gap < smallestGap { smallestGap = gap }
        }
        guard smallestGap != Int32.max else { return nil }
        do {
            var step = Double(smallestGap)
            guard step >= 8 else { return nil }
            // Refine the step on small multiples first, then widen, so the large differences are predicted well.
            for cap in [4.0, 16.0, 64.0, 256.0, Double.infinity] {
                var num = 0.0, den = 0.0
                for d in diffs {
                    let multiple = max((Double(d) / step).rounded(), 1)
                    if multiple > cap { break }
                    num += Double(d) * multiple
                    den += multiple * multiple
                }
                if den > 0 { step = num / den }
            }
            var fits = true
            for d in diffs {
                let multiple = max((Double(d) / step).rounded(), 1)
                if abs(Double(d) - multiple * step) > 3.0 { fits = false; break }
            }
            if fits { return step }
        }
        return nil
    }
}

// MARK: - Worker feed

/// Owns the D2 ring and the D3 meter for one transport session; each runs only while its card is visible.
final class ProductionSpectrogramFeed {
    private var ring: SpectrogramRing?
    private var bits: BitActivityMeter?
    private var rate = 0.0
    private var window = SpectrogramWindow.tenSeconds
    private var cached: SpectrogramSnapshot?
    private var cachedColumns = -1

    var isSpectrogramActive: Bool { ring != nil }
    var isBitActivityActive: Bool { bits != nil }

    func setActive(spectrogram: Bool, window newWindow: SpectrogramWindow, bitActivity: Bool, sampleRate: Double) {
        guard sampleRate > 0 else { return }
        if rate != sampleRate {
            ring = nil; bits = nil; cached = nil
            rate = sampleRate
        }
        if spectrogram {
            if ring == nil || window != newWindow {
                ring = SpectrogramRing(sampleRate: sampleRate, window: newWindow)
                cached = nil; cachedColumns = -1
            }
        } else {
            ring = nil; cached = nil; cachedColumns = -1
        }
        window = newWindow
        if bitActivity {
            if bits == nil { bits = BitActivityMeter() }
        } else {
            bits = nil
        }
    }

    func resetBitActivity() { bits?.reset() }

    func ingest(_ frames: UnsafeBufferPointer<N60AnalysisFrame>) {
        guard !frames.isEmpty else { return }
        ring?.ingest(frames)
        bits?.process(frames)
    }

    func spectrogramSnapshot() -> SpectrogramSnapshot? {
        guard let ring else { return nil }
        if ring.totalColumns != cachedColumns || cached == nil {
            cached = ring.snapshot()
            cachedColumns = ring.totalColumns
        }
        return cached
    }

    func bitActivity() -> [BitActivityChannel] { bits?.readout() ?? [] }
}
