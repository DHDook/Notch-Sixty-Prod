import Foundation

/// E11 S6: import and export of REW text, FRD, ZMA and WAV (design note 11). Tolerant parsing
/// (tabs, commas, semicolons, spaces; dot decimal; `*`, `#` and `;` comments), 1 MB text limit.
/// Off the audio thread only.

enum MeasurementTextFormat: String, CaseIterable, Sendable {
    case rew, frd, zma

    var fileExtension: String { self == .rew ? "txt" : rawValue }
    /// Second column is impedance in ohms for ZMA, SPL in dB otherwise.
    var isImpedance: Bool { self == .zma }
}

struct MeasurementParseIssue: Equatable, Sendable {
    var line: Int
    var message: String
    var description: String { "Line \(line): \(message)" }
}

struct MeasurementCurve: Equatable, Sendable {
    var frequenciesHz: [Double]
    /// dB SPL (REW, FRD) or ohms (ZMA).
    var values: [Double]
    var phaseDegrees: [Double]?
    var comments: [String] = []
    var issues: [MeasurementParseIssue] = []

    /// Magnitude and phase as a library response. ZMA impedance is converted to dB re 1 ohm.
    func response(format: MeasurementTextFormat) -> RoomCorrectionFrequencyResponse {
        RoomCorrectionFrequencyResponse(
            frequenciesHz: frequenciesHz,
            magnitudeDB: format.isImpedance ? values.map { 20 * log10(max($0, 1e-12)) } : values,
            phaseRadians: phaseDegrees?.map { $0 * .pi / 180 })
    }
}

enum MeasurementFormatError: Error, Equatable, LocalizedError {
    case tooLarge(bytes: Int)
    case notText
    case noData([MeasurementParseIssue])
    case unsupportedWAV(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes): "File is \(bytes) bytes; the limit is \(MeasurementFormats.textLimitBytes)."
        case .notText: "File is not UTF-8 text."
        case .noData(let issues): "No data lines found." + (issues.first.map { " First problem: \($0.description)" } ?? "")
        case .unsupportedWAV(let why): "Unsupported WAV file: \(why)."
        }
    }
}

enum MeasurementFormats {
    static let textLimitBytes = 1_048_576

    // MARK: Text

    static func parse(_ data: Data, format: MeasurementTextFormat) throws -> MeasurementCurve {
        guard data.count <= textLimitBytes else { throw MeasurementFormatError.tooLarge(bytes: data.count) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw MeasurementFormatError.notText
        }
        return try parse(text, format: format)
    }

    static func parse(_ text: String, format: MeasurementTextFormat) throws -> MeasurementCurve {
        guard text.utf8.count <= textLimitBytes else { throw MeasurementFormatError.tooLarge(bytes: text.utf8.count) }
        var curve = MeasurementCurve(frequenciesHz: [], values: [], phaseDegrees: nil)
        var phases: [Double] = []
        var phaseCount = 0
        let separators = CharacterSet(charactersIn: " \t,;")
        var lineNumber = 0
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let first = line.first, first == "*" || first == "#" || first == ";" {
                curve.comments.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            let fields = line.components(separatedBy: separators).filter { !$0.isEmpty }
            guard fields.count >= 2 else {
                curve.issues.append(.init(line: lineNumber, message: "expected at least two numeric columns"))
                continue
            }
            guard let f = Double(fields[0]), let v = Double(fields[1]), f.isFinite, v.isFinite else {
                curve.issues.append(.init(line: lineNumber, message: "could not read \"\(fields[0])\" and \"\(fields[1])\" as numbers"))
                continue
            }
            guard f > 0 else {
                curve.issues.append(.init(line: lineNumber, message: "frequency must be positive"))
                continue
            }
            if let last = curve.frequenciesHz.last, f <= last {
                curve.issues.append(.init(line: lineNumber, message: "frequency does not increase"))
                continue
            }
            var phase = 0.0
            if fields.count >= 3 {
                if let p = Double(fields[2]), p.isFinite { phase = p; phaseCount += 1 }
                else { curve.issues.append(.init(line: lineNumber, message: "could not read phase \"\(fields[2])\"")) }
            }
            curve.frequenciesHz.append(f)
            curve.values.append(v)
            phases.append(phase)
        }
        guard !curve.frequenciesHz.isEmpty else { throw MeasurementFormatError.noData(curve.issues) }
        if phaseCount > 0 { curve.phaseDegrees = phases }
        return curve
    }

    static func write(_ curve: MeasurementCurve, format: MeasurementTextFormat, title: String = "Notch Sixty measurement") -> String {
        var out = ""
        switch format {
        case .rew:
            out += "* \(title)\n* Measurement data saved by Notch Sixty\n* Freq(Hz)\tSPL(dB)\tPhase(degrees)\n"
        case .frd:
            out += "* \(title)\n* Freq(Hz)\tSPL(dB)\tPhase(degrees)\n"
        case .zma:
            out += "* \(title)\n* Freq(Hz)\tImpedance(ohm)\tPhase(degrees)\n"
        }
        for i in curve.frequenciesHz.indices {
            let phase = curve.phaseDegrees?[i] ?? 0
            out += String(format: "%.9g\t%.6f\t%.5f\n", curve.frequenciesHz[i], curve.values[i], phase)
        }
        return out
    }

    /// A library response as a text curve (phase omitted as zero when absent).
    static func curve(from response: RoomCorrectionFrequencyResponse, format: MeasurementTextFormat) -> MeasurementCurve {
        MeasurementCurve(
            frequenciesHz: response.frequenciesHz,
            values: format.isImpedance ? response.magnitudeDB.map { pow(10, $0 / 20) } : response.magnitudeDB,
            phaseDegrees: response.phaseRadians?.map { $0 * 180 / .pi })
    }

    // MARK: WAV

    /// Reads PCM 16/24/32-bit or float32/64 WAV (first channel) as Float samples.
    static func decodeWAV(_ data: Data, name: String) throws -> (samples: [Float], sampleRate: Double) {
        let b = [UInt8](data)
        func u32(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
        guard b.count >= 12, b[0..<4].elementsEqual("RIFF".utf8), b[8..<12].elementsEqual("WAVE".utf8) else {
            throw MeasurementLibraryError.corruptWAV(name)
        }
        var cursor = 12
        var tag = 0, channels = 0, bits = 0, rate = 0
        while cursor + 8 <= b.count {
            let id = String(decoding: b[cursor..<cursor + 4], as: UTF8.self)
            let size = u32(cursor + 4)
            let body = cursor + 8
            guard body + size <= b.count else { throw MeasurementLibraryError.corruptWAV(name) }
            if id == "fmt " {
                guard size >= 16 else { throw MeasurementLibraryError.corruptWAV(name) }
                tag = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
                if tag == 0xFFFE, size >= 26 { tag = u16(body + 24) }
            } else if id == "data" {
                guard channels >= 1, rate > 0 else { throw MeasurementLibraryError.corruptWAV(name) }
                let bytesPer = bits / 8
                guard (tag == 1 && [16, 24, 32].contains(bits)) || (tag == 3 && [32, 64].contains(bits)) else {
                    throw MeasurementFormatError.unsupportedWAV("format \(tag), \(bits) bits")
                }
                let stride = bytesPer * channels
                let frames = size / stride
                var out = [Float](repeating: 0, count: frames)
                for n in 0..<frames {
                    let p = body + n * stride
                    switch (tag, bits) {
                    case (1, 16): out[n] = Float(Int16(truncatingIfNeeded: u16(p))) / 32768
                    case (1, 24):
                        let v = Int32(truncatingIfNeeded: (Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16) << 8) >> 8
                        out[n] = Float(v) / 8_388_608
                    case (1, 32): out[n] = Float(Int32(truncatingIfNeeded: u32(p))) / 2_147_483_648
                    case (3, 32): out[n] = Float(bitPattern: UInt32(truncatingIfNeeded: u32(p)))
                    default:
                        var bits64: UInt64 = 0
                        for k in 0..<8 { bits64 |= UInt64(b[p + k]) << UInt64(8 * k) }
                        out[n] = Float(Double(bitPattern: bits64))
                    }
                }
                return (out, Double(rate))
            }
            cursor = body + size + (size & 1)
        }
        throw MeasurementLibraryError.corruptWAV(name)
    }

    static func encodeWAV(_ samples: [Float], sampleRate: Double) -> Data {
        MeasurementFloatWAV.encode(samples, sampleRate: sampleRate)
    }

    /// The sweep exactly as played, so E22 can feed the same signal and capture to REW.
    static func sweepWAV(
        sampleRate: Double, startFrequencyHz: Double, endFrequencyHz: Double, durationSeconds: Double,
        levelDBFS: Double, fadeSeconds: Double, synchronised: Bool
    ) throws -> Data {
        let sweep = try MeasurementCore.makeSweep(
            sampleRate: sampleRate, startFrequencyHz: startFrequencyHz, endFrequencyHz: endFrequencyHz,
            durationSeconds: durationSeconds, levelDBFS: levelDBFS, fadeSeconds: fadeSeconds, synchronised: synchronised)
        return encodeWAV(sweep.samples, sampleRate: sampleRate)
    }
}

extension MeasurementLibrary {
    /// Imports a text curve as a curve-only record (overlays and A/B only).
    func importCurve(
        _ data: Data, format: MeasurementTextFormat, name: String, sampleRate: Double = 48_000
    ) throws -> (record: MeasurementRecord, issues: [MeasurementParseIssue]) {
        let curve = try MeasurementFormats.parse(data, format: format)
        let record = MeasurementRecord(
            name: name, group: "Imported", createdAt: Date(), sampleRate: sampleRate,
            response: curve.response(format: format), hasImpulseResponse: false)
        let stored = record
        return (try save(stored, impulseResponse: nil), curve.issues)
    }

    /// Imports a WAV impulse response; the stored response is left for the caller to analyse.
    func importImpulseWAV(_ data: Data, name: String) throws -> MeasurementRecord {
        let wav = try MeasurementFormats.decodeWAV(data, name: name)
        let record = MeasurementRecord(name: name, group: "Imported", createdAt: Date(), sampleRate: wav.sampleRate)
        return try save(record, impulseResponse: wav.samples)
    }

    func exportCurve(id: UUID, format: MeasurementTextFormat) throws -> Data {
        let record = try loadRecord(id: id)
        guard let response = record.response else {
            throw MeasurementLibraryError.incompatible("\(record.name) has no frequency response to export.")
        }
        let curve = MeasurementFormats.curve(from: response, format: format)
        return Data(MeasurementFormats.write(curve, format: format, title: record.name).utf8)
    }

    func exportImpulseWAV(id: UUID) throws -> Data {
        let record = try loadRecord(id: id)
        return MeasurementFormats.encodeWAV(try loadImpulseResponse(id: id), sampleRate: record.sampleRate)
    }

    func exportRawWAV(id: UUID) throws -> Data {
        let record = try loadRecord(id: id)
        return MeasurementFormats.encodeWAV(try loadRawCapture(id: id), sampleRate: record.sampleRate)
    }
}
