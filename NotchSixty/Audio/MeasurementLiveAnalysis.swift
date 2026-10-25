import Foundation

/// E11 S8: Swift faces of the core's SPL meter, RTA and monitor ring (`n60/measure.h`), the pipeline that moves
/// samples from the ring through both, and the CSV level logger. Everything here runs on a worker or control
/// thread; only `n60_monitor_ring_push` (in the IOProc) runs on the audio thread.

enum SPLWeighting: UInt32, CaseIterable, Sendable {
    case z = 0, a, c

    var label: String {
        switch self {
        case .z: "Z"
        case .a: "A"
        case .c: "C"
        }
    }
}

/// Owner of the SPSC ring shared by the IOProc (producer) and the analysis worker (consumer).
final class MonitorSampleRing: @unchecked Sendable {
    let handle: OpaquePointer

    init(capacityFrames: Int = 1 << 18) throws {
        var ring: OpaquePointer?
        guard n60_monitor_ring_create(UInt32(capacityFrames), &ring) == N60_MEASURE_OK, let ring else {
            throw MeasurementLiveError.ringUnavailable
        }
        handle = ring
    }

    deinit { n60_monitor_ring_destroy(handle) }

    /// Frames dropped because the consumer fell behind. The producer never waits.
    var overrunFrames: UInt64 { n60_monitor_ring_overrun_frames(handle) }
    var availableFrames: Int { Int(n60_monitor_ring_available(handle)) }

    func push(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { Int(n60_monitor_ring_push(handle, $0.baseAddress, 1, UInt32($0.count))) }
    }

    func pop(maximum: Int) -> [Float] {
        var out = [Float](repeating: 0, count: maximum)
        let n = out.withUnsafeMutableBufferPointer { Int(n60_monitor_ring_pop(handle, $0.baseAddress, UInt32($0.count))) }
        out.removeLast(maximum - n)
        return out
    }

    func reset() { n60_monitor_ring_reset(handle) }
}

enum MeasurementLiveError: Error, Equatable {
    case ringUnavailable
    case invalidSampleRate(Double)
    case analyzerUnavailable
}

struct SPLReading: Equatable, Sendable {
    var fastDB: Double
    var slowDB: Double
    var leqDB: Double
    var cPeakDB: Double
    var elapsedSeconds: Double
}

final class SPLMeterCore {
    private let handle: OpaquePointer
    private(set) var calibrationOffsetDB = 0.0
    let weighting: SPLWeighting

    init(sampleRate: Double, weighting: SPLWeighting) throws {
        var meter: OpaquePointer?
        guard n60_spl_create(sampleRate, weighting.rawValue, &meter) == N60_MEASURE_OK, let meter else {
            throw MeasurementLiveError.invalidSampleRate(sampleRate)
        }
        handle = meter
        self.weighting = weighting
    }

    deinit { n60_spl_destroy(handle) }

    func reset() { n60_spl_reset(handle) }

    func setCalibration(offsetDB: Double) {
        if n60_spl_set_calibration_db(handle, offsetDB) == N60_MEASURE_OK { calibrationOffsetDB = offsetDB }
    }

    /// Offset that makes the current Leq read `referenceSPL` (acoustic calibrator: 94 or 114 dB at 1 kHz). Uses
    /// the reading as it stands, so measure the calibrator tone first and call this once it is steady.
    func calibrate(toReferenceSPL referenceSPL: Double) -> Double? {
        let uncalibrated = read().leqDB - calibrationOffsetDB
        guard uncalibrated > Double(N60_SPL_FLOOR_DB) + 1 else { return nil }
        let offset = referenceSPL - uncalibrated
        setCalibration(offsetDB: offset)
        return offset
    }

    func process(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { _ = n60_spl_process(handle, $0.baseAddress, UInt64($0.count)) }
    }

    func read() -> SPLReading {
        var r = n60_spl_reading()
        _ = n60_spl_read(handle, &r)
        return SPLReading(fastDB: r.fast_db, slowDB: r.slow_db, leqDB: r.leq_db, cPeakDB: r.c_peak_db, elapsedSeconds: r.elapsed_seconds)
    }

    static func weightingResponseDB(sampleRate: Double, weighting: SPLWeighting, frequencyHz: Double) -> Double? {
        var db = 0.0
        return n60_spl_weighting_response_db(sampleRate, weighting.rawValue, frequencyHz, &db) == N60_MEASURE_OK ? db : nil
    }
}

struct RTASettings: Equatable, Sendable {
    enum Averaging: UInt32, CaseIterable, Sendable {
        case none = 0, exponential, infinite
    }

    /// 1, 3, 6, 12, 24 or 48 bands per octave.
    var bandsPerOctave = 3
    var averaging = Averaging.exponential
    var timeConstantSeconds = 1.0
}

struct RTASpectrum: Equatable, Sendable {
    var centresHz: [Double]
    var levelsDB: [Double]
    var framesAnalysed: UInt64
}

final class RTAAnalyzerCore {
    private let handle: OpaquePointer
    let settings: RTASettings
    /// Added to every band above the floor; set when the meter is calibrated so both read in the same units.
    var calibrationOffsetDB = 0.0

    init(sampleRate: Double, settings: RTASettings) throws {
        var size: UInt32 = 0
        guard n60_rta_default_fft_size(sampleRate, UInt32(settings.bandsPerOctave), &size) == N60_MEASURE_OK else {
            throw MeasurementLiveError.analyzerUnavailable
        }
        var params = n60_rta_params(
            sample_rate: sampleRate, fft_size: size, bands_per_octave: UInt32(settings.bandsPerOctave),
            averaging: settings.averaging.rawValue, time_constant_seconds: settings.timeConstantSeconds,
            min_hz: 0, max_hz: 0, calibration_db: 0)
        var rta: OpaquePointer?
        guard n60_rta_create(&params, &rta) == N60_MEASURE_OK, let rta else {
            throw MeasurementLiveError.analyzerUnavailable
        }
        handle = rta
        self.settings = settings
    }

    deinit { n60_rta_destroy(handle) }

    func reset() { n60_rta_reset(handle) }

    func process(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { _ = n60_rta_process(handle, $0.baseAddress, UInt64($0.count)) }
    }

    func read() -> RTASpectrum {
        let count = Int(n60_rta_band_count(handle))
        var centres = [Double](repeating: 0, count: count)
        var levels = [Double](repeating: 0, count: count)
        var n: UInt32 = 0
        _ = n60_rta_read(handle, &centres, &levels, UInt32(count), &n)
        let offset = calibrationOffsetDB
        levels = levels.map { $0 > Double(N60_SPL_FLOOR_DB) ? $0 + offset : $0 }
        return RTASpectrum(centresHz: centres, levelsDB: levels, framesAnalysed: n60_rta_frames_analysed(handle))
    }
}

/// Drains the ring into the meter and the analyser. `drain` is the worker's whole job; it allocates (scratch arrays)
/// and is never called from the audio thread.
/// Used from one worker queue at a time; the owner serialises access.
final class MeasurementMonitorPipeline: @unchecked Sendable {
    let ring: MonitorSampleRing
    let meter: SPLMeterCore
    let rta: RTAAnalyzerCore
    let sampleRate: Double

    init(ring: MonitorSampleRing, sampleRate: Double, weighting: SPLWeighting, rta settings: RTASettings, calibrationOffsetDB: Double) throws {
        self.ring = ring
        self.sampleRate = sampleRate
        meter = try SPLMeterCore(sampleRate: sampleRate, weighting: weighting)
        meter.setCalibration(offsetDB: calibrationOffsetDB)
        rta = try RTAAnalyzerCore(sampleRate: sampleRate, settings: settings)
        rta.calibrationOffsetDB = calibrationOffsetDB
    }

    /// Calibrates the meter from the current Leq (steady calibrator tone) and applies the same offset to the RTA.
    @discardableResult
    func calibrate(toReferenceSPL referenceSPL: Double) -> Double? {
        guard let offset = meter.calibrate(toReferenceSPL: referenceSPL) else { return nil }
        rta.calibrationOffsetDB = offset
        return offset
    }

    /// Moves everything queued in the ring through both analysers; returns the frames consumed.
    @discardableResult
    func drain(chunk: Int = 16_384) -> Int {
        var total = 0
        while true {
            let samples = ring.pop(maximum: chunk)
            if samples.isEmpty { break }
            meter.process(samples)
            rta.process(samples)
            total += samples.count
        }
        return total
    }

    func reset() {
        ring.reset()
        meter.reset()
        rta.reset()
    }
}

/// One CSV row per logging interval. Header: seconds, weighting, Fast, Slow, Leq, C-peak. A reading made with no
/// calibration is labelled "dB (relative)" in the header, never as SPL.
struct MeasurementLevelLog: Equatable, Sendable {
    let calibrated: Bool
    let weighting: SPLWeighting
    private(set) var rows: [(seconds: Double, reading: SPLReading)] = []

    static func == (lhs: MeasurementLevelLog, rhs: MeasurementLevelLog) -> Bool {
        lhs.calibrated == rhs.calibrated && lhs.weighting == rhs.weighting && lhs.rows.count == rhs.rows.count
            && zip(lhs.rows, rhs.rows).allSatisfy { $0.seconds == $1.seconds && $0.reading == $1.reading }
    }

    init(calibrated: Bool, weighting: SPLWeighting) {
        self.calibrated = calibrated
        self.weighting = weighting
    }

    mutating func append(seconds: Double, reading: SPLReading) { rows.append((seconds, reading)) }

    var csv: String {
        let unit = calibrated ? "dB SPL" : "dB (relative)"
        let w = weighting.label
        var out = "seconds,L\(w)F (\(unit)),L\(w)S (\(unit)),L\(w)eq (\(unit)),LCpeak (\(unit))\n"
        for (seconds, r) in rows {
            out += String(format: "%.3f,%.2f,%.2f,%.2f,%.2f\n", seconds, r.fastDB, r.slowDB, r.leqDB, r.cPeakDB)
        }
        return out
    }

    /// Writes into the app container's measurement folder (`Application Support/NotchSixty/Measurements/Logs`).
    func write(named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(safe).csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
