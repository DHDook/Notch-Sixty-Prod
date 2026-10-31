import Foundation

/// E13 S1: one importer for bring-your-own frequency responses and target curves.
/// Implemented from the public descriptions of the AutoEq CSV, REW text, squig.link text and FRD
/// formats; no third-party code or data. Off the audio thread only.

enum ImportedCurveFormat: String, Equatable, Sendable {
    case autoEqCSV, text
}

struct ImportedCurve: Equatable, Sendable {
    var frequenciesHz: [Double]
    var db: [Double]
    var phaseDegrees: [Double]?
    var format: ImportedCurveFormat
    var sourceName: String
    var issues: [String]
    /// An AutoEq results CSV that also has a `target` column offers it here (same grid).
    var offeredTarget: [Double]?
}

enum FrequencyResponseImportError: Error, Equatable, LocalizedError {
    case tooLarge(Int)
    case notText
    case noData(String)
    case noResponseColumn

    var errorDescription: String? {
        switch self {
        case .tooLarge(let n): "File is \(n) bytes; the limit is \(MeasurementFormats.textLimitBytes)."
        case .notText: "File is not text."
        case .noData(let why): "No data lines found. \(why)"
        case .noResponseColumn: "No numeric response column found."
        }
    }
}

enum FrequencyResponseImporter {
    /// Curves with more points than this are reduced to the 1/48-octave grid.
    static let reductionThreshold = 512
    static let gridLowHz = 20.0
    static let gridHighHz = 20_000.0
    static let gridPointsPerOctave = 48.0
    static let normalisationHz = 1_000.0

    // MARK: Parsing

    static func parse(_ data: Data, sourceName: String) throws -> ImportedCurve {
        guard data.count <= MeasurementFormats.textLimitBytes else { throw FrequencyResponseImportError.tooLarge(data.count) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw FrequencyResponseImportError.notText
        }
        return try parse(text, sourceName: sourceName)
    }

    static func parse(_ text: String, sourceName: String) throws -> ImportedCurve {
        let lines = text.split(omittingEmptySubsequences: false,
                               whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let headerIndex = lines.firstIndex(where: { !$0.isEmpty }),
           isAutoEqHeader(lines[headerIndex]) {
            return try parseAutoEq(lines, headerIndex: headerIndex, sourceName: sourceName)
        }
        return try parseText(lines, sourceName: sourceName)
    }

    private static func isAutoEqHeader(_ line: String) -> Bool {
        guard let first = line.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" }).first else { return false }
        return first.trimmingCharacters(in: .whitespaces).lowercased() == "frequency"
    }

    /// Splits a data line. A line holding `;` or a tab uses commas as decimal points.
    private static func fields(_ line: String) -> [String] {
        if line.contains(";") || line.contains("\t") {
            let parts = line.split(whereSeparator: { $0 == ";" || $0 == "\t" })
            return parts.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".") }
        }
        return line.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }

    private static func parseAutoEq(_ lines: [String], headerIndex: Int, sourceName: String) throws -> ImportedCurve {
        let header = fields(lines[headerIndex]).map { $0.lowercased() }
        let rawColumn = header.firstIndex(of: "raw")
        let targetColumn = header.firstIndex(of: "target")
        var freqs: [Double] = [], values: [Double] = [], targets: [Double] = []
        var issues: [String] = []
        var responseColumn = rawColumn
        for (i, line) in lines.enumerated() where i > headerIndex && !line.isEmpty {
            let f = fields(line)
            if responseColumn == nil {
                // First numeric column after frequency.
                responseColumn = (1 ..< f.count).first { Double(f[$0]) != nil }
            }
            guard let rc = responseColumn, f.count > rc, let hz = Double(f[0]), let v = Double(f[rc]),
                  hz.isFinite, v.isFinite, hz > 0 else {
                issues.append("line \(i + 1): could not read frequency and response"); continue
            }
            if let last = freqs.last, hz <= last { issues.append("line \(i + 1): frequency does not increase"); continue }
            if let tc = targetColumn {
                guard f.count > tc, let t = Double(f[tc]), t.isFinite else {
                    issues.append("line \(i + 1): could not read target"); continue
                }
                targets.append(t)
            }
            freqs.append(hz); values.append(v)
        }
        guard responseColumn != nil else { throw FrequencyResponseImportError.noResponseColumn }
        guard freqs.count >= 2 else { throw FrequencyResponseImportError.noData(issues.first ?? "") }
        return ImportedCurve(frequenciesHz: freqs, db: values, phaseDegrees: nil, format: .autoEqCSV,
                             sourceName: sourceName, issues: issues,
                             offeredTarget: targetColumn != nil ? targets : nil)
    }

    private static func parseText(_ lines: [String], sourceName: String) throws -> ImportedCurve {
        var freqs: [Double] = [], values: [Double] = [], phases: [Double] = []
        var phaseCount = 0
        var issues: [String] = []
        for (i, line) in lines.enumerated() where !line.isEmpty {
            if let c = line.first, c == "*" || c == "#" || c == ";" { continue }
            let f = fields(line)
            guard f.count >= 2, let hz = Double(f[0]), let v = Double(f[1]), hz.isFinite, v.isFinite else {
                // Non-numeric header lines are common (squig.link, REW); a first line is not an issue.
                if !freqs.isEmpty { issues.append("line \(i + 1): could not read two numbers") }
                continue
            }
            guard hz > 0 else { issues.append("line \(i + 1): frequency must be positive"); continue }
            if let last = freqs.last, hz <= last { issues.append("line \(i + 1): frequency does not increase"); continue }
            var phase = 0.0
            if f.count >= 3, let p = Double(f[2]), p.isFinite { phase = p; phaseCount += 1 }
            freqs.append(hz); values.append(v); phases.append(phase)
        }
        guard freqs.count >= 2 else { throw FrequencyResponseImportError.noData(issues.first ?? "") }
        return ImportedCurve(frequenciesHz: freqs, db: values, phaseDegrees: phaseCount > 0 ? phases : nil,
                             format: .text, sourceName: sourceName, issues: issues, offeredTarget: nil)
    }

    // MARK: Grid and level

    /// The 1/48-octave log grid, 20 Hz to 20 kHz.
    static let referenceGrid: [Double] = {
        let count = Int((log2(gridHighHz / gridLowHz) * gridPointsPerOctave).rounded()) + 1
        return (0 ..< count).map { gridLowHz * pow(2, Double($0) / gridPointsPerOctave) }
    }()

    /// Reduces a dense curve by a log-frequency box average on the reference grid. Each grid point
    /// averages the source points within half a grid step either side; an empty box takes the
    /// log-linear interpolation. Deterministic.
    static func reduced(frequenciesHz: [Double], db: [Double]) -> (frequenciesHz: [Double], db: [Double]) {
        guard frequenciesHz.count > reductionThreshold else { return (frequenciesHz, db) }
        let half = pow(2, 0.5 / gridPointsPerOctave)
        var outF: [Double] = [], outV: [Double] = []
        var lo = 0
        for g in referenceGrid {
            let low = g / half, high = g * half
            if g < frequenciesHz[0] / half || g > frequenciesHz[frequenciesHz.count - 1] * half { continue }
            while lo < frequenciesHz.count, frequenciesHz[lo] < low { lo += 1 }
            var j = lo, sum = 0.0, n = 0
            while j < frequenciesHz.count, frequenciesHz[j] <= high { sum += db[j]; n += 1; j += 1 }
            outF.append(g)
            outV.append(n > 0 ? sum / Double(n) : interpolate(frequenciesHz, db, at: g))
        }
        return outF.count >= 2 ? (outF, outV) : (frequenciesHz, db)
    }

    /// Log-frequency linear interpolation, clamped at the ends.
    static func interpolate(_ f: [Double], _ v: [Double], at hz: Double) -> Double {
        if hz <= f[0] { return v[0] }
        if hz >= f[f.count - 1] { return v[v.count - 1] }
        var lo = 0, hi = f.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if f[mid] <= hz { lo = mid } else { hi = mid } }
        let t = log(hz / f[lo]) / log(f[hi] / f[lo])
        return v[lo] + t * (v[hi] - v[lo])
    }

    /// Target curves are normalised to 0 dB at 1 kHz.
    static func normalisedToZeroAt1kHz(frequenciesHz: [Double], db: [Double]) -> [Double] {
        let offset = interpolate(frequenciesHz, db, at: normalisationHz)
        return db.map { $0 - offset }
    }

    // MARK: Targets

    /// Builds a validated target record from an imported curve (or its offered target column).
    static func targetRecord(from curve: ImportedCurve, useOfferedTarget: Bool = false,
                             category: TargetCategory, name: String? = nil,
                             attribution: String? = nil, importDate: Date = Date()) throws -> TargetRecord {
        let source = useOfferedTarget ? (curve.offeredTarget ?? curve.db) : curve.db
        let r = reduced(frequenciesHz: curve.frequenciesHz, db: source)
        let level = normalisedToZeroAt1kHz(frequenciesHz: r.frequenciesHz, db: r.db)
        var record = TargetRecord(name: name ?? curve.sourceName,
                                  points: zip(r.frequenciesHz, level).map { RoomCorrectionTargetPoint(frequencyHz: $0, gainDB: $1) })
        record.category = category
        record.provenance = TargetProvenance(
            fileName: curve.sourceName, format: curve.format.rawValue,
            importDate: ISO8601DateFormatter().string(from: importDate), attribution: attribution)
        try TargetLibrary.validate(record)
        return record
    }

    // MARK: Left/right pairing

    /// Two file names that differ only by a trailing `L`/`R` or `left`/`right` token are a pair.
    /// Returns the common base name and which one is left, or nil.
    static func pairKey(_ name: String) -> (base: String, isLeft: Bool)? {
        let stem = (name as NSString).deletingPathExtension
        let lower = stem.lowercased()
        for (suffix, left) in [("left", true), ("right", false), ("l", true), ("r", false)] where lower.hasSuffix(suffix) {
            let base = String(stem.dropLast(suffix.count))
            guard let last = base.last, last == " " || last == "_" || last == "-" || last == "." || last == "(" else { continue }
            return (base.trimmingCharacters(in: CharacterSet(charactersIn: " _-.(")).lowercased(), left)
        }
        return nil
    }

    /// Pairs two curves into (left, right) by name; one curve is used for both ears.
    static func stereo(_ curves: [ImportedCurve]) -> (left: ImportedCurve, right: ImportedCurve)? {
        if curves.count == 1 { return (curves[0], curves[0]) }
        guard curves.count == 2, let a = pairKey(curves[0].sourceName), let b = pairKey(curves[1].sourceName),
              a.base == b.base, a.isLeft != b.isLeft else { return nil }
        return a.isLeft ? (curves[0], curves[1]) : (curves[1], curves[0])
    }
}
