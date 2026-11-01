import Foundation

// E13 S2: bring-your-own headphone responses, the extended PEQ fitter, Equalizer APO preset import and the
// one-click "Fit and apply" session. Control plane only: nothing here runs on an audio thread. The fitter uses the
// production biquad design (`HeadphoneEQResponsePreview`), so the predicted response is the response the HEADPHONE
// stage renders. References: RBJ Audio EQ Cookbook (biquad shelves and peaks, via `N60BiquadDesign`).

// MARK: - Stored response

struct HeadphoneResponseCurve: Codable, Equatable, Sendable {
    var frequenciesHz: [Double]
    var db: [Double]

    var isValid: Bool {
        guard frequenciesHz.count == db.count, frequenciesHz.count >= 2, frequenciesHz.count <= 4_096 else { return false }
        var previous = 0.0
        for (f, v) in zip(frequenciesHz, db) {
            guard f.isFinite, v.isFinite, f > previous else { return false }
            previous = f
        }
        return true
    }
}

enum HeadphoneResponseError: Error, Equatable, LocalizedError {
    case invalid(String)
    case pairingFailed
    case tooMany

    var errorDescription: String? {
        switch self {
        case .invalid(let why): "Invalid headphone response: \(why)"
        case .pairingFailed:
            "Two files need names that differ only by a trailing L or R (or left or right); choose one file for both ears."
        case .tooMany: "The headphone response library holds at most 256 responses."
        }
    }
}

/// A user's own headphone response, stored independent of sample rate. Local data only.
struct HeadphoneResponseRecord: Codable, Equatable, Sendable, Identifiable {
    static let schemaVersion = 1
    static let defaultAttribution = "User-supplied file"
    static let defaultLicence = "Local use"
    /// 1/24-octave fitting grid, 20 Hz upward, at most 240 points.
    static let gridPointsPerOctave = 24.0

    var schema = HeadphoneResponseRecord.schemaVersion
    var id: UUID
    var name: String
    var left: HeadphoneResponseCurve
    var right: HeadphoneResponseCurve
    var sourceName: String
    var attribution: String?
    var licence: String?
    var importDate: String

    init(id: UUID = UUID(), name: String, left: HeadphoneResponseCurve, right: HeadphoneResponseCurve,
         sourceName: String? = nil, attribution: String? = nil, licence: String? = nil, importDate: Date = Date()) {
        self.id = id; self.name = name; self.left = left; self.right = right
        self.sourceName = sourceName ?? name; self.attribution = attribution; self.licence = licence
        self.importDate = ISO8601DateFormatter().string(from: importDate)
    }

    func validate() throws {
        guard schema == Self.schemaVersion else { throw HeadphoneResponseError.invalid("schema \(schema) is not supported") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HeadphoneResponseError.invalid("name is empty") }
        guard left.isValid, right.isValid else { throw HeadphoneResponseError.invalid("a curve is not finite and increasing") }
    }

    /// Builds a record from one file (both ears) or two named L/R files.
    static func make(from curves: [ImportedCurve], name: String? = nil, attribution: String? = nil) throws -> Self {
        guard let pair = FrequencyResponseImporter.stereo(curves) else { throw HeadphoneResponseError.pairingFailed }
        func curve(_ c: ImportedCurve) -> HeadphoneResponseCurve {
            let r = FrequencyResponseImporter.reduced(frequenciesHz: c.frequenciesHz, db: c.db)
            return HeadphoneResponseCurve(frequenciesHz: r.frequenciesHz, db: r.db)
        }
        let base = FrequencyResponseImporter.pairKey(pair.left.sourceName).map { _ in
            (pair.left.sourceName as NSString).deletingPathExtension
        } ?? pair.left.sourceName
        let record = HeadphoneResponseRecord(
            name: name ?? (curves.count == 2 ? trimmedPairName(base) : base),
            left: curve(pair.left), right: curve(pair.right), sourceName: pair.left.sourceName, attribution: attribution)
        try record.validate()
        return record
    }

    private static func trimmedPairName(_ stem: String) -> String {
        guard let key = FrequencyResponseImporter.pairKey(stem) else { return stem }
        // `pairKey` lower-cases; trim the same trailing token from the original spelling.
        let lowerStem = stem.lowercased()
        for suffix in ["left", "right", "l", "r"] where lowerStem.hasSuffix(suffix) {
            return String(stem.dropLast(suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " _-.("))
        }
        return key.base
    }

    /// The fitting grid for a rate: 1/24 octave from 20 Hz to min(20 kHz, 0.45 fs).
    static func fittingGrid(sampleRate: Double) -> [Double] {
        let top = min(20_000.0, sampleRate * 0.45)
        var grid: [Double] = []
        var i = 0.0
        while true {
            let f = 20.0 * pow(2, i / gridPointsPerOctave)
            if f > top * (1 + 1e-9) { break }
            grid.append(f); i += 1
        }
        return grid
    }

    /// Resamples the response and a target (nil means flat) onto the fitting grid. The common level of both ears
    /// is removed (mean over 250 Hz to 2.5 kHz) so the evidence stays within the measurement limits; the
    /// left/right difference is kept.
    func measurement(target: RoomCorrectionTargetCurve?, sampleRate: Double) throws -> HeadphoneModelMeasurement {
        try validate()
        let grid = Self.fittingGrid(sampleRate: sampleRate)
        func resample(_ c: HeadphoneResponseCurve) -> [Double] {
            grid.map { FrequencyResponseImporter.interpolate(c.frequenciesHz, c.db, at: $0) }
        }
        let l = resample(left), r = resample(right)
        let ref = grid.indices.filter { grid[$0] >= 250 && grid[$0] <= 2_500 }
        let level = ref.isEmpty ? 0 : ref.reduce(0.0) { $0 + l[$1] + r[$1] } / Double(2 * ref.count)
        var t = [Double](repeating: 0, count: grid.count)
        if let target, target.points.count >= 2 {
            let tf = target.points.map(\.frequencyHz), tv = target.points.map(\.gainDB)
            t = grid.map { FrequencyResponseImporter.interpolate(tf, tv, at: $0) }
        }
        let points = grid.indices.map {
            HeadphoneModelFrequencyPoint(frequencyHz: grid[$0], leftMagnitudeDB: l[$0] - level,
                                         rightMagnitudeDB: r[$0] - level, targetMagnitudeDB: t[$0])
        }
        func nonBlank(_ s: String?, _ fallback: String) -> String {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
            return s
        }
        let measurement = HeadphoneModelMeasurement(
            schemaVersion: 1, id: id, headphoneModel: name, sourceName: sourceName,
            sourceAttribution: nonBlank(attribution, Self.defaultAttribution),
            sourceLicense: nonBlank(licence, Self.defaultLicence), acquisitionNotes: "", points: points)
        try measurement.validate(sampleRate: sampleRate)
        return measurement
    }
}

/// `Application Support/NotchSixty/HeadphoneResponses/<uuid>.json`. Off the audio thread only.
struct HeadphoneResponseStore: Sendable {
    let directory: URL
    static let maximumRecords = 256
    static let maximumBytes = 512 * 1_024

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.directory = base.appendingPathComponent("NotchSixty/HeadphoneResponses", isDirectory: true)
        }
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    func save(_ record: HeadphoneResponseRecord) throws {
        try record.validate()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(atPath: directory.path))?.filter { $0.hasSuffix(".json") } ?? []
        if existing.count >= Self.maximumRecords, !existing.contains("\(record.id.uuidString).json") {
            throw HeadphoneResponseError.tooMany
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumBytes else { throw HeadphoneResponseError.invalid("record is too large") }
        try data.write(to: url(record.id), options: .atomic)
    }

    func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: url(id)) }

    /// Valid records sorted by name; files that cannot be read are reported and skipped.
    func loadAll() -> (records: [HeadphoneResponseRecord], skipped: [String]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return ([], []) }
        var records: [HeadphoneResponseRecord] = [], skipped: [String] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let file = directory.appendingPathComponent(name)
            do {
                let data = try Data(contentsOf: file)
                guard data.count <= Self.maximumBytes else { throw HeadphoneResponseError.invalid("file is too large") }
                let record = try JSONDecoder().decode(HeadphoneResponseRecord.self, from: data)
                try record.validate()
                records.append(record)
            } catch { skipped.append(name) }
        }
        return (records.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }, skipped)
    }
}

// MARK: - Fitter

struct HeadphoneAutoFitOptions: Equatable, Sendable {
    /// 1 to 16; the default is 10 per ear.
    var maximumBandsPerEar = 10
    /// The fit uses 20 Hz up to this frequency (10 kHz default, up to 16 kHz); zero weight above.
    var fitUpperHz = 10_000.0
}

struct HeadphoneAutoFitResult: Sendable {
    var headphoneModel: String
    var proposal: HeadphoneCorrectionProposal
    var leftRMSEBeforeDB: Double
    var rightRMSEBeforeDB: Double
    var leftRMSEAfterDB: Double
    var rightRMSEAfterDB: Double
    var worstFrequencyRegressionDB: Double
    /// Conservative required headroom rounded up to 0.5 dB.
    var recommendedHeadroomDB: Double
    var warnings: [String]
}

enum HeadphoneAutoFitter {
    static let peakQs = [0.5, 1.0, 2.0]
    static let refinementQs = [0.5, 0.7, 1.0, 1.4, 2.0, 2.8, 4.0]
    static let lowShelfHz = 105.0
    static let highShelfHz = 10_000.0
    static let shelfQ = 0.7
    static let minimumGainDB = -12.0
    static let maximumBoostDB = 6.0
    static let maximumBoostAbove10kHzDB = 3.0
    static let gainStepDB = 0.25
    static let refinementSweeps = 3

    static func boostLimit(_ band: HeadphoneCorrectionEQBand) -> Double {
        (band.type == .highShelf || band.frequencyHz > 10_000) ? maximumBoostAbove10kHzDB : maximumBoostDB
    }

    static func clampedGain(_ gain: Double, for band: HeadphoneCorrectionEQBand) -> Double {
        min(boostLimit(band), max(minimumGainDB, gain))
    }

    private static func bandID(ear: Int, index: Int) -> UUID {
        UUID(uuid: (0x4E, 0x31, 0x33, 0x53, 0x32, UInt8(ear), UInt8(index >> 8), UInt8(index & 0xFF),
                    0, 0, 0, 0, 0, 0, 0, 1))
    }

    static func fit(measurement: HeadphoneModelMeasurement, sampleRate: Double,
                    options: HeadphoneAutoFitOptions = .init()) throws -> HeadphoneAutoFitResult {
        try measurement.validate(sampleRate: sampleRate)
        guard (1 ... 16).contains(options.maximumBandsPerEar), (1_000.0 ... 16_000.0).contains(options.fitUpperHz) else {
            throw OptionalAcousticResearchError.invalidEvidence
        }
        let freqs = measurement.points.map(\.frequencyHz)
        let target = measurement.points.map(\.targetMagnitudeDB)
        let left = try fitEar(ear: 0, freqs: freqs, response: measurement.points.map(\.leftMagnitudeDB),
                              target: target, sampleRate: sampleRate, options: options)
        let right = try fitEar(ear: 1, freqs: freqs, response: measurement.points.map(\.rightMagnitudeDB),
                               target: target, sampleRate: sampleRate, options: options)
        let proposal = HeadphoneCorrectionProposal(
            schemaVersion: 1, headphoneModel: measurement.headphoneModel, sourceName: measurement.sourceName,
            sourceAttribution: measurement.sourceAttribution, sourceLicense: measurement.sourceLicense,
            referenceSampleRate: sampleRate, leftBands: left.bands, rightBands: right.bands)
        try proposal.validate(sampleRate: sampleRate)
        var draft = HeadphoneDeviceProfileConfiguration()
        draft.left.eqBands = left.bands
        draft.right.eqBands = right.bands
        let headroom = roundedUpHeadroom(draft.conservativeRequiredHeadroomDB)
        let worst = max(left.worst, right.worst)
        var warnings: [String] = []
        if worst > 2 {
            warnings.append("At least one measured frequency would regress by over 2 dB; review the bands.")
        }
        if headroom > 6 {
            warnings.append("The boosts need \(headroom) dB of digital attenuation, so playback will be quieter.")
        }
        if left.after >= left.before || right.after >= right.before {
            warnings.append("At least one ear received no modelled improvement.")
        }
        warnings.append("A response fit is not an individual ear calibration. Check seal, coupling and safe listening levels.")
        return HeadphoneAutoFitResult(
            headphoneModel: measurement.headphoneModel, proposal: proposal,
            leftRMSEBeforeDB: left.before, rightRMSEBeforeDB: right.before,
            leftRMSEAfterDB: left.after, rightRMSEAfterDB: right.after,
            worstFrequencyRegressionDB: worst, recommendedHeadroomDB: headroom, warnings: warnings)
    }

    static func roundedUpHeadroom(_ requiredDB: Double) -> Double {
        max(0, (requiredDB * 2 - 1e-9).rounded(.up) / 2)
    }

    /// Magnitude of one band in dB from the RBJ cookbook coefficients in double precision, which is what the
    /// HEADPHONE stage designs and runs (`designBiquad` in the core). The Swift preview quantises to float, which
    /// is off by up to 0.2 dB at low frequencies at the highest rates.
    static func bandMagnitudeDB(_ band: HeadphoneCorrectionEQBand, frequencyHz hz: Double, sampleRate: Double) -> Double? {
        guard band.frequencyHz > 0, band.frequencyHz < sampleRate / 2, band.q > 0, band.gainDB.isFinite,
              hz > 0, hz < sampleRate / 2 else { return nil }
        let w0 = 2 * Double.pi * band.frequencyHz / sampleRate
        let cw = cos(w0), alpha = sin(w0) / (2 * band.q)
        let A = pow(10, band.gainDB / 40)
        let b: (Double, Double, Double), a: (Double, Double, Double)
        switch band.type {
        case .peaking:
            b = (1 + alpha * A, -2 * cw, 1 - alpha * A); a = (1 + alpha / A, -2 * cw, 1 - alpha / A)
        case .lowShelf:
            let beta = 2 * A.squareRoot() * alpha
            b = (A * ((A + 1) - (A - 1) * cw + beta), 2 * A * ((A - 1) - (A + 1) * cw), A * ((A + 1) - (A - 1) * cw - beta))
            a = ((A + 1) + (A - 1) * cw + beta, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - beta)
        case .highShelf:
            let beta = 2 * A.squareRoot() * alpha
            b = (A * ((A + 1) + (A - 1) * cw + beta), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - beta))
            a = ((A + 1) - (A - 1) * cw + beta, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - beta)
        }
        let w = 2 * Double.pi * hz / sampleRate
        func power(_ c: (Double, Double, Double)) -> Double {
            let re = c.0 + c.1 * cos(w) + c.2 * cos(2 * w), im = -(c.1 * sin(w) + c.2 * sin(2 * w))
            return re * re + im * im
        }
        let ratio = power(b) / power(a)
        guard ratio.isFinite, ratio > 0 else { return nil }
        return 10 * log10(ratio)
    }

    private struct EarFit {
        var bands: [HeadphoneCorrectionEQBand]
        var before: Double, after: Double, worst: Double
    }

    private static func fitEar(ear: Int, freqs: [Double], response: [Double], target: [Double],
                               sampleRate: Double, options: HeadphoneAutoFitOptions) throws -> EarFit {
        let n = freqs.count
        let weights = freqs.map { $0 <= options.fitUpperHz ? 1.0 : 0.0 }
        let weightSum = max(1.0, weights.reduce(0, +))
        // Align the target to the response by the mean difference over 250 Hz to 2.5 kHz.
        let ref = (0 ..< n).filter { freqs[$0] >= 250 && freqs[$0] <= 2_500 }
        let offset = ref.isEmpty ? 0 : ref.reduce(0.0) { $0 + response[$1] - target[$1] } / Double(ref.count)
        let desired = (0 ..< n).map { target[$0] + offset - response[$0] }
        func rmse(_ r: [Double]) -> Double {
            var s = 0.0
            for i in 0 ..< n { s += weights[i] * r[i] * r[i] }
            return (s / weightSum).squareRoot()
        }
        func bandResponse(_ band: HeadphoneCorrectionEQBand) -> [Double]? {
            var out = [Double](); out.reserveCapacity(n)
            for f in freqs {
                guard let m = bandMagnitudeDB(band, frequencyHz: f, sampleRate: sampleRate) else { return nil }
                out.append(m)
            }
            return out
        }
        let top = min(20_000.0, sampleRate * 0.45)
        var bands: [HeadphoneCorrectionEQBand] = []
        var responses: [[Double]] = []
        var residual = desired
        var current = rmse(residual)
        let original = current

        func make(_ type: HeadphoneCorrectionFilterType, _ hz: Double, _ gain: Double, _ q: Double) -> HeadphoneCorrectionEQBand {
            var band = HeadphoneCorrectionEQBand(enabled: true, type: type, frequencyHz: hz, gainDB: 0, q: q)
            band.gainDB = clampedGain(gain, for: band)
            return band
        }
        func trial(_ band: HeadphoneCorrectionEQBand, replacing index: Int?) -> (residual: [Double], rmse: Double, response: [Double])? {
            guard let response = bandResponse(band) else { return nil }
            var next = residual
            for i in 0 ..< n {
                next[i] -= response[i]
                if let index { next[i] += responses[index][i] }
            }
            return (next, rmse(next), response)
        }

        // Greedy search: peaks at the worst residual points plus the two shelf candidates.
        for _ in 0 ..< options.maximumBandsPerEar {
            var candidates: [HeadphoneCorrectionEQBand] = []
            let ranked = (0 ..< n).filter { weights[$0] > 0 }.sorted {
                let a = abs(residual[$0]), b = abs(residual[$1])
                return a != b ? a > b : $0 < $1
            }
            for i in ranked.prefix(12) {
                for q in peakQs { candidates.append(make(.peaking, freqs[i], residual[i], q)) }
            }
            let low = (0 ..< n).filter { freqs[$0] <= 150 }
            if !low.isEmpty {
                candidates.append(make(.lowShelf, lowShelfHz, low.reduce(0.0) { $0 + residual[$1] } / Double(low.count), shelfQ))
            }
            let high = (0 ..< n).filter { freqs[$0] >= 8_000 && weights[$0] > 0 }
            if !high.isEmpty, options.fitUpperHz > 8_000 {
                candidates.append(make(.highShelf, highShelfHz, high.reduce(0.0) { $0 + residual[$1] } / Double(high.count), shelfQ))
            }
            var best: (band: HeadphoneCorrectionEQBand, residual: [Double], rmse: Double, response: [Double])?
            for band in candidates where band.frequencyHz < top {
                guard let t = trial(band, replacing: nil), t.rmse + 0.02 < current,
                      t.rmse < (best?.rmse ?? .infinity) else { continue }
                best = (band, t.residual, t.rmse, t.response)
            }
            guard var chosen = best else { break }
            chosen.band.id = bandID(ear: ear, index: bands.count)
            bands.append(chosen.band); responses.append(chosen.response)
            residual = chosen.residual; current = chosen.rmse
        }

        // Deterministic refinement: coordinate search, accepted only on an RMSE drop.
        for _ in 0 ..< refinementSweeps {
            for index in bands.indices {
                var moves: [(inout HeadphoneCorrectionEQBand) -> Void] = []
                let step = pow(2.0, 1.0 / 12.0)
                moves.append { $0.frequencyHz *= step }
                moves.append { $0.frequencyHz /= step }
                moves.append { band in
                    let k = refinementQs.enumerated().min { abs($0.element - band.q) < abs($1.element - band.q) }!.offset
                    if k + 1 < refinementQs.count { band.q = refinementQs[k + 1] }
                }
                moves.append { band in
                    let k = refinementQs.enumerated().min { abs($0.element - band.q) < abs($1.element - band.q) }!.offset
                    if k > 0 { band.q = refinementQs[k - 1] }
                }
                moves.append { $0.gainDB += gainStepDB }
                moves.append { $0.gainDB -= gainStepDB }
                for (moveIndex, move) in moves.enumerated() {
                    // Gain moves repeat while they keep helping.
                    for _ in 0 ..< (moveIndex >= 4 ? 16 : 1) {
                        var proposed = bands[index]
                        move(&proposed)
                        proposed.gainDB = clampedGain(proposed.gainDB, for: proposed)
                        guard proposed != bands[index], proposed.frequencyHz >= 20, proposed.frequencyHz < top,
                              let t = trial(proposed, replacing: index), t.rmse + 1e-9 < current else { break }
                        bands[index] = proposed; responses[index] = t.response
                        residual = t.residual; current = t.rmse
                    }
                }
            }
        }
        let worst = (0 ..< n).filter { weights[$0] > 0 }.map { abs(residual[$0]) - abs(desired[$0]) }.max() ?? 0
        let sorted = bands.sorted { ($0.frequencyHz, $0.id.uuidString) < ($1.frequencyHz, $1.id.uuidString) }
        return EarFit(bands: sorted, before: original, after: current, worst: worst)
    }
}

// MARK: - Equalizer APO preset

struct EqualizerAPOPreset: Equatable, Sendable {
    var preampDB: Double?
    var bands: [HeadphoneCorrectionEQBand]
    var issues: [String]
}

enum EqualizerAPOImportError: Error, Equatable, LocalizedError {
    case tooLarge
    case noFilters
    case tooManyFilters(Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge: "The preset is larger than 64 KB."
        case .noFilters: "No usable peak or shelf filters were found."
        case .tooManyFilters(let n): "The preset has \(n) filters; the headphone profile holds \(N60_HEADPHONE_MAX_EQ_SECTIONS) per ear."
        }
    }
}

/// Reads the public Equalizer APO `ParametricEQ.txt` lines: `Preamp: -6 dB` and
/// `Filter 1: ON PK Fc 105 Hz Gain -2.5 dB Q 0.7` (PK; LS or LSC; HS or HSC). Other filter types and filters
/// marked OFF are skipped and reported.
enum EqualizerAPOPresetImporter {
    static func parse(_ data: Data) throws -> EqualizerAPOPreset {
        guard data.count <= 64 * 1_024 else { throw EqualizerAPOImportError.tooLarge }
        return try parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) throws -> EqualizerAPOPreset {
        var preamp: Double?
        var bands: [HeadphoneCorrectionEQBand] = []
        var issues: [String] = []
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        for (number, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            let tokens = lower.replacingOccurrences(of: ":", with: " ").replacingOccurrences(of: ",", with: ".")
                .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let head = tokens.first else { continue }
            if head == "preamp" {
                preamp = tokens.dropFirst().compactMap(Double.init).first
                continue
            }
            guard head == "filter" else { continue }
            if tokens.contains("off") { issues.append("line \(number + 1): filter is off, skipped"); continue }
            func value(after key: String) -> Double? {
                guard let i = tokens.firstIndex(of: key), i + 1 < tokens.count else { return nil }
                return Double(tokens[i + 1])
            }
            let type: HeadphoneCorrectionFilterType?
            if tokens.contains(where: { ["pk", "peq", "peak"].contains($0) }) { type = .peaking }
            else if tokens.contains(where: { ["ls", "lsc"].contains($0) }) { type = .lowShelf }
            else if tokens.contains(where: { ["hs", "hsc"].contains($0) }) { type = .highShelf }
            else { type = nil }
            guard let type, let fc = value(after: "fc"), let gain = value(after: "gain") else {
                issues.append("line \(number + 1): unsupported filter, skipped"); continue
            }
            guard let q = value(after: "q") ?? (type == .peaking ? nil : 0.707) else {
                issues.append("line \(number + 1): peak filter without Q, skipped"); continue
            }
            let clampedQ = min(12.0, max(0.2, q))
            if clampedQ != q { issues.append("line \(number + 1): Q \(q) limited to \(clampedQ)") }
            bands.append(HeadphoneCorrectionEQBand(enabled: true, type: type, frequencyHz: fc, gainDB: gain, q: clampedQ))
        }
        guard !bands.isEmpty else { throw EqualizerAPOImportError.noFilters }
        guard bands.count <= Int(N60_HEADPHONE_MAX_EQ_SECTIONS) else { throw EqualizerAPOImportError.tooManyFilters(bands.count) }
        return EqualizerAPOPreset(preampDB: preamp, bands: bands, issues: issues)
    }

    /// A proposal staging the same filters on both ears (fresh band IDs per ear).
    static func proposal(from preset: EqualizerAPOPreset, name: String, sampleRate: Double) throws -> HeadphoneCorrectionProposal {
        func fresh() -> [HeadphoneCorrectionEQBand] {
            preset.bands.map { var b = $0; b.id = UUID(); return b }
        }
        let proposal = HeadphoneCorrectionProposal(
            schemaVersion: 1, headphoneModel: name, sourceName: name,
            sourceAttribution: HeadphoneResponseRecord.defaultAttribution,
            sourceLicense: HeadphoneResponseRecord.defaultLicence,
            referenceSampleRate: sampleRate, leftBands: fresh(), rightBands: fresh())
        try proposal.validate(sampleRate: sampleRate)
        return proposal
    }
}

// MARK: - One click

extension HeadphoneDeviceProfileConfiguration {
    /// The profile with a fit applied: bands on both ears, headroom set to the conservative requirement rounded
    /// up to 0.5 dB, the target recorded, and the profile enabled. Throws if the result does not validate.
    func applyingFit(left leftBands: [HeadphoneCorrectionEQBand], right rightBands: [HeadphoneCorrectionEQBand],
                     targetID: UUID?, targetName: String?, sampleRate: Double) throws -> Self {
        var next = self
        next.left.eqBands = leftBands
        next.right.eqBands = rightBands
        let required = next.conservativeRequiredHeadroomDB
        guard required.isFinite, required <= 30 else {
            throw HeadphoneDeviceProfileError.insufficientHeadroom(requiredDB: required, configuredDB: headroomAttenuationDB)
        }
        next.headroomAttenuationDB = HeadphoneAutoFitter.roundedUpHeadroom(required)
        next.targetCurve = .custom
        next.fittedTargetID = targetID
        next.fittedTargetName = targetName
        next.enabled = true
        try next.validateStructure(sampleRate: sampleRate)
        return next
    }
}

/// Holds one level of Undo for "Fit and apply".
struct HeadphoneOneClickSession: Equatable, Sendable {
    private(set) var previous: HeadphoneDeviceProfileConfiguration?
    var canUndo: Bool { previous != nil }

    mutating func apply(_ result: HeadphoneAutoFitResult, to profile: HeadphoneDeviceProfileConfiguration,
                        targetID: UUID?, targetName: String?, sampleRate: Double) throws
        -> HeadphoneDeviceProfileConfiguration {
        let next = try profile.applyingFit(left: result.proposal.leftBands, right: result.proposal.rightBands,
                                           targetID: targetID, targetName: targetName, sampleRate: sampleRate)
        previous = profile
        return next
    }

    mutating func apply(preset proposal: HeadphoneCorrectionProposal, to profile: HeadphoneDeviceProfileConfiguration,
                        sampleRate: Double) throws -> HeadphoneDeviceProfileConfiguration {
        let next = try profile.applyingFit(left: proposal.leftBands, right: proposal.rightBands,
                                           targetID: nil, targetName: nil, sampleRate: sampleRate)
        previous = profile
        return next
    }

    /// The profile from before the last apply, exactly; one level only.
    mutating func undo() -> HeadphoneDeviceProfileConfiguration? {
        defer { previous = nil }
        return previous
    }
}
