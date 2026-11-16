import Foundation

/// E33 S2 (design 4): the one Equalizer APO / AutoEQ / REW filter-text codec for `EQBand`. The page's
/// Import and Export, the toolbar's text import and export, and the clipboard's text form all go through
/// it; E17 S2 and S8 reuse it. Pure value code, no UI, no engine.
///
/// Grammar (public Equalizer APO "Filter:" documentation; REW and AutoEQ write the same lines):
/// `Preamp: -6.4 dB`, then `Filter 1: ON PK Fc 105 Hz Gain -2.5 dB Q 0.7`. Types: PK/PEQ (peaking),
/// LS/LSC/HS/HSC (shelves; `LS 12 dB` slope form, `LSC` with Q), LP/LPQ/HP/HPQ, BP, NO/NOTCH, AP.
/// A slope written between the type and `Fc` (`LSC 18 dB Fc ...`) sets the band slope. `OFF` bands import
/// disabled. `Filter 3: ON None` empty slots, comments and blank lines are ignored; every other line is
/// reported in `issues` and skipped.
enum EqualizerAPOCodec {
    struct Parsed: Equatable {
        var bands: [EQBand] = []
        var preampDB: Double?
        /// Lines that were skipped or changed, with their line numbers.
        var issues: [String] = []
    }

    struct Written: Equatable {
        var text: String
        /// Bands that cannot be written (Linkwitz Transform, Tilt, FIR).
        var issues: [String]
    }

    static let defaultQ = EQBandRules.defaultQ

    // MARK: Read

    static func parse(_ text: String) -> Parsed {
        var result = Parsed()
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (offset, raw) in lines.enumerated() {
            let number = offset + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            let tokens = tokenize(line)
            guard let head = tokens.first else { continue }
            if head == "preamp" {
                if let value = tokens.dropFirst().lazy.compactMap(Double.init).first, value.isFinite {
                    result.preampDB = value
                } else {
                    result.issues.append("line \(number): Preamp has no value, skipped")
                }
                continue
            }
            guard head == "filter" else {
                result.issues.append("line \(number): \"\(head)\" is not supported, skipped")
                continue
            }
            parseFilter(tokens: Array(tokens.dropFirst()), number: number, into: &result)
        }
        return result
    }

    private static func tokenize(_ line: String) -> [String] {
        line.lowercased()
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: ":", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
    }

    private struct TypeInfo {
        var type: EQFilterType
        var usesQ: Bool
    }

    private static func typeInfo(_ token: String) -> TypeInfo? {
        switch token {
        case "pk", "peq", "pa", "peak", "peaking", "parametric": return TypeInfo(type: .peaking, usesQ: true)
        case "ls", "lowshelf": return TypeInfo(type: .lowShelf, usesQ: false)
        case "lsc": return TypeInfo(type: .lowShelf, usesQ: true)
        case "hs", "highshelf": return TypeInfo(type: .highShelf, usesQ: false)
        case "hsc": return TypeInfo(type: .highShelf, usesQ: true)
        case "lp", "lowpass": return TypeInfo(type: .lowPass, usesQ: false)
        case "lpq": return TypeInfo(type: .lowPass, usesQ: true)
        case "hp", "highpass": return TypeInfo(type: .highPass, usesQ: false)
        case "hpq": return TypeInfo(type: .highPass, usesQ: true)
        case "bp", "bandpass": return TypeInfo(type: .bandPass, usesQ: true)
        case "no", "notch": return TypeInfo(type: .notch, usesQ: true)
        case "ap", "allpass": return TypeInfo(type: .allPass, usesQ: true)
        default: return nil
        }
    }

    private static func parseFilter(tokens: [String], number: Int, into result: inout Parsed) {
        // Skip an optional index ("1"), then the state.
        var rest = tokens[...]
        if let first = rest.first, Int(first) != nil { rest = rest.dropFirst() }
        var enabled = true
        if let state = rest.first, state == "on" || state == "off" {
            enabled = state == "on"
            rest = rest.dropFirst()
        }
        guard let typeToken = rest.first else {
            result.issues.append("line \(number): filter has no type, skipped")
            return
        }
        if typeToken == "none" { return }
        guard let info = typeInfo(typeToken) else {
            result.issues.append("line \(number): filter type \"\(typeToken.uppercased())\" is not supported, skipped")
            return
        }
        rest = rest.dropFirst()
        func value(after key: String) -> Double? {
            guard let index = rest.firstIndex(of: key), index + 1 < rest.endIndex,
                  let number = Double(rest[index + 1]), number.isFinite else { return nil }
            return number
        }
        guard let frequency = value(after: "fc") else {
            result.issues.append("line \(number): filter has no Fc, skipped")
            return
        }
        // A slope between the type and Fc: "12 dB" or "12dB".
        var slope = EQFilterSlope.db12
        if info.type.supportsSlope, let fcIndex = rest.firstIndex(of: "fc") {
            let before = rest[rest.startIndex..<fcIndex]
            if let raw = before.compactMap({ Int($0.replacingOccurrences(of: "db", with: "")) }).first {
                if let known = EQFilterSlope(rawValue: raw) {
                    slope = known
                } else {
                    result.issues.append("line \(number): slope \(raw) dB is not supported, 12 dB used")
                }
            }
        }
        let hasGain = info.type == .peaking || info.type == .lowShelf || info.type == .highShelf
        var gain = 0.0
        if hasGain {
            guard let g = value(after: "gain") else {
                result.issues.append("line \(number): filter has no Gain, skipped")
                return
            }
            gain = g
        }
        var q = defaultQ
        if let explicit = value(after: "q") {
            q = explicit
        } else if let bandwidth = value(after: "bw") ?? value(after: "oct") {
            q = qFromBandwidthOctaves(bandwidth)
        } else if info.type == .peaking {
            result.issues.append("line \(number): peak filter without Q, \(defaultQ) used")
        }
        result.bands.append(EQBand(enabled: enabled, type: info.type, frequencyHz: frequency, gainDB: gain, q: q, slope: slope))
    }

    /// Q of a band `bandwidth` octaves wide (RBJ cookbook relation).
    static func qFromBandwidthOctaves(_ bandwidth: Double) -> Double {
        guard bandwidth.isFinite, bandwidth > 0 else { return defaultQ }
        let power = pow(2.0, bandwidth)
        let denominator = power - 1.0
        guard denominator > 0 else { return defaultQ }
        return sqrt(power) / denominator
    }

    // MARK: Write

    static func write(bands: [EQBand], preampDB: Double? = nil, header: [String] = []) -> Written {
        var lines = header.map { "# \($0)" }
        var issues: [String] = []
        if let preampDB { lines.append(String(format: "Preamp: %.4f dB", preampDB)) }
        var index = 1
        for band in bands {
            guard let token = token(for: band.type) else {
                issues.append("\(band.type.displayName) band at \(Int(band.frequencyHz.rounded())) Hz cannot be written as Equalizer APO text and was omitted.")
                continue
            }
            let state = band.enabled ? "ON" : "OFF"
            var line = "Filter \(index): \(state) \(token)"
            if band.type.supportsSlope && band.slope != .db12 { line += " \(band.slope.rawValue) dB" }
            line += String(format: " Fc %.4f Hz", band.frequencyHz)
            switch band.type {
            case .peaking, .lowShelf, .highShelf:
                line += String(format: " Gain %.4f dB", band.gainDB)
            default: break
            }
            line += String(format: " Q %.5f", band.q)
            lines.append(line)
            index += 1
        }
        return Written(text: lines.joined(separator: "\n") + "\n", issues: issues)
    }

    static func canWrite(_ type: EQFilterType) -> Bool { token(for: type) != nil }

    private static func token(for type: EQFilterType) -> String? {
        switch type {
        case .peaking: "PK"
        case .lowShelf: "LSC"
        case .highShelf: "HSC"
        case .lowPass: "LPQ"
        case .highPass: "HPQ"
        case .bandPass: "BP"
        case .notch: "NO"
        case .allPass: "AP"
        case .linkwitzTransform, .tilt, .fir: nil
        }
    }
}
