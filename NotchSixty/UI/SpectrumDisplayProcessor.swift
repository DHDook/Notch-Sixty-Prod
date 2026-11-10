import Foundation

// E28 S3: display-side options for the Meters > Spectrum page. Everything here
// runs on the main actor from the worker's published snapshot; nothing touches
// the audio callback or the analysis worker's FFT.

enum SpectrumSmoothing: String, CaseIterable, Identifiable, Sendable {
    case off
    case octave24
    case octave12
    case octave6
    case octave3

    var id: String { rawValue }

    /// Total smoothing window in octaves, nil for Off.
    var octaves: Double? {
        switch self {
        case .off: return nil
        case .octave24: return 1.0 / 24.0
        case .octave12: return 1.0 / 12.0
        case .octave6: return 1.0 / 6.0
        case .octave3: return 1.0 / 3.0
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .octave24: return "1/24 octave"
        case .octave12: return "1/12 octave"
        case .octave6: return "1/6 octave"
        case .octave3: return "1/3 octave"
        }
    }
}

enum SpectrumAveraging: String, CaseIterable, Identifiable, Sendable {
    case off
    case ms125
    case s1
    case infinite

    var id: String { rawValue }

    /// Time constant in seconds; nil for Off, infinity for the running mean.
    var timeConstant: Double? {
        switch self {
        case .off: return nil
        case .ms125: return 0.125
        case .s1: return 1
        case .infinite: return .infinity
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .ms125: return "125 ms"
        case .s1: return "1 s"
        case .infinite: return "Infinite"
        }
    }
}

enum SpectrumTilt: String, CaseIterable, Identifiable, Sendable {
    case flat
    case db3
    case db45

    var id: String { rawValue }

    /// dB per octave about 1 kHz (positive lifts the highs).
    var dbPerOctave: Float {
        switch self {
        case .flat: return 0
        case .db3: return 3
        case .db45: return 4.5
        }
    }

    var title: String {
        switch self {
        case .flat: return "0 dB/oct"
        case .db3: return "3 dB/oct"
        case .db45: return "4.5 dB/oct"
        }
    }
}

/// Persisted spectrum options. The reference trace and freeze are session
/// state and are not stored.
struct SpectrumDisplayOptions: Equatable, Sendable {
    static let smoothingKey = "meters.spectrum.smoothing"
    static let averagingKey = "meters.spectrum.averaging"
    static let tiltKey = "meters.spectrum.tilt"
    static let showInputKey = "meters.spectrum.showInput"
    static let showOutputKey = "meters.spectrum.showOutput"
    static let showPeakHoldKey = "meters.spectrum.showPeakHold"

    var smoothing: SpectrumSmoothing = .off
    var averaging: SpectrumAveraging = .off
    var tilt: SpectrumTilt = .flat
    var showInput = true
    var showOutput = true
    var showPeakHold = true

    static func load(from defaults: UserDefaults) -> SpectrumDisplayOptions {
        var options = SpectrumDisplayOptions()
        options.smoothing = defaults.string(forKey: smoothingKey).flatMap(SpectrumSmoothing.init(rawValue:)) ?? .off
        options.averaging = defaults.string(forKey: averagingKey).flatMap(SpectrumAveraging.init(rawValue:)) ?? .off
        options.tilt = defaults.string(forKey: tiltKey).flatMap(SpectrumTilt.init(rawValue:)) ?? .flat
        options.showInput = defaults.object(forKey: showInputKey) as? Bool ?? true
        options.showOutput = defaults.object(forKey: showOutputKey) as? Bool ?? true
        options.showPeakHold = defaults.object(forKey: showPeakHoldKey) as? Bool ?? true
        return options
    }

    func store(to defaults: UserDefaults) {
        defaults.set(smoothing.rawValue, forKey: Self.smoothingKey)
        defaults.set(averaging.rawValue, forKey: Self.averagingKey)
        defaults.set(tilt.rawValue, forKey: Self.tiltKey)
        defaults.set(showInput, forKey: Self.showInputKey)
        defaults.set(showOutput, forKey: Self.showOutputKey)
        defaults.set(showPeakHold, forKey: Self.showPeakHoldKey)
    }
}

/// Frequency axis shared by the plot, the grid labels and the hover read-out so
/// x to frequency and back always agree.
struct SpectrumAxis: Equatable, Sendable {
    static let minimumFrequency = 20.0
    var maximumFrequency: Double

    init(maximumFrequency: Double) {
        self.maximumFrequency = max(maximumFrequency, Self.minimumFrequency + 1)
    }

    func fraction(frequency: Double) -> Double {
        let clamped = min(max(frequency, Self.minimumFrequency), maximumFrequency)
        return log10(clamped / Self.minimumFrequency) / log10(maximumFrequency / Self.minimumFrequency)
    }

    func frequency(fraction: Double) -> Double {
        let clamped = min(max(fraction, 0), 1)
        return Self.minimumFrequency * pow(maximumFrequency / Self.minimumFrequency, clamped)
    }
}

struct SpectrumReference: Equatable, Sendable {
    let frequencies: [Double]
    let levelsDB: [Float]
}

struct SpectrumHoverReadout: Equatable, Sendable {
    let frequencyHz: Double
    let inputDB: Float
    let outputDB: Float
    let referenceDB: Float?
}

/// Smoothing, averaging and tilt over the analyzer's logarithmic bands.
///
/// Averaging runs on power per band (before smoothing and tilt), so changing
/// smoothing or tilt redraws from the same averaged state. Peak-hold traces
/// pass through smoothing and tilt but are never averaged.
struct SpectrumDisplayProcessor: Sendable {
    private var frequencies: [Double] = []
    private var inputPower: [Double] = []
    private var outputPower: [Double] = []
    private var inputPeak: [Float] = []
    private var outputPeak: [Float] = []
    private var averagedFrames = 0
    private var averagingMode: SpectrumAveraging = .off

    var isEmpty: Bool { frequencies.isEmpty }

    mutating func reset() {
        frequencies = []
        inputPower = []
        outputPower = []
        inputPeak = []
        outputPeak = []
        averagedFrames = 0
    }

    /// Adds one analyzer frame. `deltaSeconds` is the time since the previous
    /// frame; the first frame, a change of averaging mode or a change of band
    /// layout starts the average afresh.
    mutating func ingest(
        _ bands: [ProductionSpectrumBand],
        averaging: SpectrumAveraging,
        deltaSeconds: Double
    ) {
        guard !bands.isEmpty else {
            reset()
            return
        }
        let layout = bands.map(\.frequencyHz)
        let restart = layout != frequencies || averaging != averagingMode || averagedFrames == 0
        averagingMode = averaging
        let inputNow = bands.map { Self.power(db: $0.inputDB) }
        let outputNow = bands.map { Self.power(db: $0.outputDB) }
        inputPeak = bands.map(\.inputPeakHoldDB)
        outputPeak = bands.map(\.outputPeakHoldDB)

        if restart || averaging == .off {
            frequencies = layout
            inputPower = inputNow
            outputPower = outputNow
            averagedFrames = 1
            return
        }
        averagedFrames += 1
        let weight: Double
        if let tau = averaging.timeConstant, tau.isFinite {
            weight = 1 - exp(-max(deltaSeconds, 0) / tau)
        } else {
            weight = 1 / Double(averagedFrames)
        }
        for index in bands.indices {
            inputPower[index] += (inputNow[index] - inputPower[index]) * weight
            outputPower[index] += (outputNow[index] - outputPower[index]) * weight
        }
    }

    /// The bands to draw for the given options.
    func display(options: SpectrumDisplayOptions) -> [ProductionSpectrumBand] {
        guard !frequencies.isEmpty else { return [] }
        let kernel = Self.kernel(frequencies: frequencies, octaves: options.smoothing.octaves)
        let inputDB = shape(Self.decibels(power: inputPower), kernel: kernel, tilt: options.tilt)
        let outputDB = shape(Self.decibels(power: outputPower), kernel: kernel, tilt: options.tilt)
        let inputHold = shape(inputPeak, kernel: kernel, tilt: options.tilt)
        let outputHold = shape(outputPeak, kernel: kernel, tilt: options.tilt)
        return frequencies.indices.map { index in
            ProductionSpectrumBand(
                frequencyHz: frequencies[index],
                inputDB: inputDB[index],
                outputDB: outputDB[index],
                inputPeakHoldDB: inputHold[index],
                outputPeakHoldDB: outputHold[index]
            )
        }
    }

    // MARK: Pure helpers

    /// dB offset a tilt adds at `frequency`: tilt x log2(f / 1 kHz).
    static func tiltOffsetDB(frequency: Double, dbPerOctave: Float) -> Float {
        guard frequency > 0 else { return 0 }
        return dbPerOctave * Float(log2(frequency / 1_000))
    }

    /// Hover read-out for a plot fraction (0...1 across the log axis), nearest band.
    static func hoverReadout(
        fraction: Double,
        bands: [ProductionSpectrumBand],
        axis: SpectrumAxis,
        reference: SpectrumReference?
    ) -> SpectrumHoverReadout? {
        guard !bands.isEmpty else { return nil }
        let target = axis.frequency(fraction: fraction)
        guard let index = nearestIndex(of: target, in: bands.map(\.frequencyHz)) else { return nil }
        var referenceDB: Float?
        if let reference, let referenceIndex = nearestIndex(of: target, in: reference.frequencies),
           referenceIndex < reference.levelsDB.count {
            referenceDB = reference.levelsDB[referenceIndex]
        }
        return SpectrumHoverReadout(
            frequencyHz: bands[index].frequencyHz,
            inputDB: bands[index].inputDB,
            outputDB: bands[index].outputDB,
            referenceDB: referenceDB
        )
    }

    static func nearestIndex(of frequency: Double, in frequencies: [Double]) -> Int? {
        guard !frequencies.isEmpty, frequency > 0 else { return nil }
        let target = log(frequency)
        var best = 0
        var bestDistance = Double.infinity
        for (index, candidate) in frequencies.enumerated() where candidate > 0 {
            let distance = abs(log(candidate) - target)
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    /// Row-normalised power-averaging weights. A band contributes fully inside
    /// the window and fades linearly across one band spacing at its edge, so
    /// windows narrower than the band spacing still smooth a little.
    private struct Kernel {
        var rows: [[(index: Int, weight: Double)]]
    }

    private static func kernel(frequencies: [Double], octaves: Double?) -> Kernel? {
        guard let octaves, frequencies.count > 1 else { return nil }
        let positions = frequencies.map { log2(max($0, 1)) }
        let spacing = max((positions.last! - positions.first!) / Double(frequencies.count - 1), 1e-6)
        let half = octaves / 2
        var rows: [[(index: Int, weight: Double)]] = []
        rows.reserveCapacity(frequencies.count)
        for center in positions.indices {
            var row: [(index: Int, weight: Double)] = []
            var total = 0.0
            for other in positions.indices {
                let distance = abs(positions[other] - positions[center])
                if distance > half + spacing { continue }
                let weight = other == center
                    ? 1
                    : min(max((half - distance) / spacing + 0.5, 0), 1)
                guard weight > 0 else { continue }
                row.append((other, weight))
                total += weight
            }
            rows.append(row.map { ($0.index, $0.weight / total) })
        }
        return Kernel(rows: rows)
    }

    private func shape(_ levels: [Float], kernel: Kernel?, tilt: SpectrumTilt) -> [Float] {
        var result = levels
        if let kernel {
            let power = levels.map { Self.power(db: $0) }
            result = kernel.rows.map { row in
                var sum = 0.0
                for entry in row { sum += power[entry.index] * entry.weight }
                return Self.decibel(power: sum)
            }
        }
        if tilt != .flat {
            for index in result.indices {
                result[index] += Self.tiltOffsetDB(frequency: frequencies[index], dbPerOctave: tilt.dbPerOctave)
            }
        }
        return result
    }

    private static func power(db: Float) -> Double {
        pow(10, Double(db) / 10)
    }

    private static func decibel(power: Double) -> Float {
        guard power.isFinite, power > 0 else { return ProductionAnalysisMath.spectrumFloorDB }
        return Float(10 * log10(power))
    }

    private static func decibels(power: [Double]) -> [Float] {
        power.map(decibel(power:))
    }
}

/// Main-actor state behind the spectrum plot: options, freeze, the one
/// session reference trace and the hover position.
@MainActor
@Observable
final class SpectrumDisplayModel {
    var options: SpectrumDisplayOptions {
        didSet {
            if options != oldValue { options.store(to: defaults) }
            if options.averaging != oldValue.averaging { processor.reset(); replayLast() }
            redraw()
        }
    }
    private(set) var isFrozen = false
    private(set) var reference: SpectrumReference?
    private(set) var bands: [ProductionSpectrumBand] = []
    var hoverFraction: Double?

    @ObservationIgnored private var processor = SpectrumDisplayProcessor()
    @ObservationIgnored private var lastRaw: [ProductionSpectrumBand] = []
    @ObservationIgnored private var lastIngestTime: Double?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.options = SpectrumDisplayOptions.load(from: defaults)
    }

    var axis: SpectrumAxis {
        SpectrumAxis(maximumFrequency: max(bands.last?.frequencyHz ?? 20_000, 21))
    }

    var hoverReadout: SpectrumHoverReadout? {
        guard let hoverFraction else { return nil }
        return SpectrumDisplayProcessor.hoverReadout(
            fraction: hoverFraction, bands: bands, axis: axis, reference: reference
        )
    }

    /// Feed the latest analyzer bands. Ignored while frozen.
    func ingest(_ raw: [ProductionSpectrumBand], now: Double) {
        guard !isFrozen else { return }
        let delta = lastIngestTime.map { max(now - $0, 0) } ?? 0
        lastIngestTime = raw.isEmpty ? nil : now
        lastRaw = raw
        processor.ingest(raw, averaging: options.averaging, deltaSeconds: delta)
        redraw()
    }

    func setFrozen(_ frozen: Bool) {
        isFrozen = frozen
        if !frozen { lastIngestTime = nil }
    }

    /// Stores what is on screen (output trace, with smoothing and tilt) as the
    /// reference. It is a copy and never changes until replaced or cleared.
    func captureReference() {
        guard !bands.isEmpty else { return }
        reference = SpectrumReference(frequencies: bands.map(\.frequencyHz), levelsDB: bands.map(\.outputDB))
    }

    func clearReference() {
        reference = nil
    }

    private func replayLast() {
        guard !lastRaw.isEmpty else { return }
        processor.ingest(lastRaw, averaging: options.averaging, deltaSeconds: 0)
    }

    private func redraw() {
        bands = processor.display(options: options)
    }
}
