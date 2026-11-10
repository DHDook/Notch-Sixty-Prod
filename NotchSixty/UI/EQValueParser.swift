import Foundation

/// E27 S1: unit-aware text entry for the Equalizer page number fields. Plain Swift, no
/// UI and no engine access, so every form can be tested without an audio device.
///
/// Forms: frequency `2k`, `2kHz`, `250hz`, `1.5 kHz`, `1,5k`; gain `+3`, `-3 dB`, `3db`;
/// Q a number or a bandwidth in octaves (`1 oct`, Q = 2^(N/2) / (2^N - 1), the RBJ
/// cookbook relation between Q and bandwidth N for a band-pass or peaking filter).
/// Unparseable text is rejected (nil) and the caller keeps the old value; out-of-range
/// values clamp to the band type's range.
enum EQValueParser {
    enum Field: Equatable, Sendable {
        case frequency
        case gain
        case q
        case linkwitzTargetFrequency
        case linkwitzTargetQ
    }

    // MARK: Parsing

    static func parseFrequency(_ text: String, locale: Locale = .current) -> Double? {
        guard let (number, unit) = split(text, locale: locale), number > 0 else { return nil }
        switch unit {
        case "", "hz": return number
        case "k", "khz": return number * 1_000
        default: return nil
        }
    }

    static func parseGain(_ text: String, locale: Locale = .current) -> Double? {
        guard let (number, unit) = split(text, locale: locale) else { return nil }
        return unit == "" || unit == "db" ? number : nil
    }

    static func parseQ(_ text: String, locale: Locale = .current) -> Double? {
        guard let (number, unit) = split(text, locale: locale) else { return nil }
        switch unit {
        case "", "q":
            return number > 0 ? number : nil
        case "oct", "oct.", "octave", "octaves":
            return q(forOctaves: number)
        default:
            return nil
        }
    }

    /// Q of a filter whose bandwidth is `octaves` wide: Q = 2^(N/2) / (2^N - 1).
    static func q(forOctaves octaves: Double) -> Double? {
        guard octaves.isFinite, octaves > 0, octaves <= 16 else { return nil }
        return pow(2, octaves / 2) / (pow(2, octaves) - 1)
    }

    /// Parses `text` for `field`; nil when it is not a valid entry for that field.
    static func parse(_ text: String, field: Field, locale: Locale = .current) -> Double? {
        switch field {
        case .frequency, .linkwitzTargetFrequency: return parseFrequency(text, locale: locale)
        case .gain: return parseGain(text, locale: locale)
        case .q, .linkwitzTargetQ: return parseQ(text, locale: locale)
        }
    }

    // MARK: Ranges

    /// The range a typed or stepped value clamps to for `band`. `maximumFrequency` is the
    /// engine's 0.49 * sample rate ceiling.
    static func range(for field: Field, band: EQBand, maximumFrequency: Double) -> ClosedRange<Double> {
        let ceiling = max(maximumFrequency, EQNudge.minimumFrequency)
        switch field {
        case .frequency:
            if band.dynamic.enabled {
                let limits = DynamicEQBandConfiguration.frequencyRange
                return limits.lowerBound...min(limits.upperBound, ceiling)
            }
            return EQNudge.minimumFrequency...ceiling
        case .gain:
            return StereoEQConfiguration.bandGainRange
        case .q:
            return band.dynamic.enabled ? DynamicEQBandConfiguration.qRange : EQNudge.qRange
        case .linkwitzTargetFrequency:
            return 1...ceiling
        case .linkwitzTargetQ:
            return EQNudge.qRange
        }
    }

    /// Parses and clamps in one step; nil means "reject, keep the old value".
    static func value(
        from text: String,
        field: Field,
        band: EQBand,
        maximumFrequency: Double,
        locale: Locale = .current
    ) -> Double? {
        guard let parsed = parse(text, field: field, locale: locale), parsed.isFinite else { return nil }
        let limits = range(for: field, band: band, maximumFrequency: maximumFrequency)
        return min(max(parsed, limits.lowerBound), limits.upperBound)
    }

    // MARK: Display

    /// Text for a field at rest: frequency to 0.1 Hz, gain to 0.1 dB, Q to 3 places, in the
    /// user's decimal separator, without grouping so it parses back to the same value.
    static func displayText(_ value: Double, field: Field, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        switch field {
        case .frequency, .linkwitzTargetFrequency:
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 1
        case .gain:
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
        case .q, .linkwitzTargetQ:
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 3
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: Number scanning

    /// Splits "-3.5 dB" into (-3.5, "db"). The unit is lower-cased and trimmed.
    static func split(_ text: String, locale: Locale) -> (Double, String)? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard !rest.isEmpty else { return nil }

        var negative = false
        if let first = rest.first, first == "+" || first == "-" || first == "\u{2212}" {
            negative = first != "+"
            rest = rest.dropFirst()
        }

        var digits = ""
        while let character = rest.first, character.isASCII && character.isNumber || character == "." || character == "," {
            digits.append(character)
            rest = rest.dropFirst()
        }
        guard let magnitude = number(from: digits, locale: locale) else { return nil }
        let unit = rest.trimmingCharacters(in: .whitespaces)
        return (negative ? -magnitude : magnitude, unit)
    }

    /// One separator is a decimal point, except a lone locale grouping separator followed by
    /// exactly three digits ("1,500" in en_US). With both, the last is the decimal point.
    private static func number(from digits: String, locale: Locale) -> Double? {
        guard digits.contains(where: \.isNumber) else { return nil }
        let dots = digits.filter { $0 == "." }.count
        let commas = digits.filter { $0 == "," }.count
        var normalized = digits

        if dots > 0 && commas > 0 {
            guard let lastDot = digits.lastIndex(of: "."), let lastComma = digits.lastIndex(of: ",") else { return nil }
            let decimal: Character = lastDot > lastComma ? "." : ","
            let grouping: Character = decimal == "." ? "," : "."
            // The grouping character may repeat; the decimal point may not.
            guard digits.filter({ $0 == decimal }).count == 1 else { return nil }
            normalized = digits.replacingOccurrences(of: String(grouping), with: "")
            if decimal == "," { normalized = normalized.replacingOccurrences(of: ",", with: ".") }
        } else if dots + commas > 1 {
            return nil
        } else if dots + commas == 1 {
            let separator: Character = dots == 1 ? "." : ","
            let parts = digits.split(separator: separator, omittingEmptySubsequences: false)
            let groupingSeparator = locale.groupingSeparator.flatMap(\.first)
            if separator == groupingSeparator, parts.count == 2, parts[0].count >= 1, parts[1].count == 3 {
                normalized = digits.replacingOccurrences(of: String(separator), with: "")
            } else {
                normalized = digits.replacingOccurrences(of: String(separator), with: ".")
            }
        }

        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }
}

// MARK: - Dynamic EQ metric fields (G4)

/// E27 S4: the Band editor's dynamic-EQ metric fields (threshold, ratio, max cut, attack, release,
/// RMS window, boost threshold, boost ratio, max boost) take units, clamp to the engine's ranges and
/// step with the arrows, like the frequency, gain and Q fields. Plain Swift; the view only binds it.
enum EQDynamicMetric: CaseIterable, Equatable, Sendable {
    case threshold, ratio, maxCut, attack, release, rmsWindow, boostThreshold, boostRatio, maxBoost

    enum Unit { case decibels, ratio, milliseconds }

    var unit: Unit {
        switch self {
        case .threshold, .maxCut, .boostThreshold, .maxBoost: return .decibels
        case .ratio, .boostRatio: return .ratio
        case .attack, .release, .rmsWindow: return .milliseconds
        }
    }

    var range: ClosedRange<Double> {
        typealias C = DynamicEQBandConfiguration
        switch self {
        case .threshold: return C.thresholdRange
        case .ratio: return C.ratioRange
        case .maxCut: return C.rangeRange
        case .attack: return C.attackRange
        case .release: return C.releaseRange
        case .rmsWindow: return C.rmsWindowRange
        case .boostThreshold: return C.boostThresholdRange
        case .boostRatio: return C.boostRatioRange
        case .maxBoost: return C.maxBoostRange
        }
    }

    /// Accepts "-24", "-24 dB", "2", "2:1", "10 ms", "0.1 s". Unparseable text is nil (keep the old value).
    static func parse(_ text: String, metric: EQDynamicMetric, locale: Locale = .current) -> Double? {
        guard let (number, unit) = EQValueParser.splitForMetric(text, locale: locale) else { return nil }
        switch metric.unit {
        case .decibels:
            return unit == "" || unit == "db" ? number : nil
        case .ratio:
            return unit == "" || unit == ":1" || unit == "x" ? number : nil
        case .milliseconds:
            switch unit {
            case "", "ms": return number
            case "s": return number * 1_000
            default: return nil
            }
        }
    }

    /// Parses and clamps; nil means reject.
    static func value(from text: String, metric: EQDynamicMetric, locale: Locale = .current) -> Double? {
        guard let parsed = parse(text, metric: metric, locale: locale), parsed.isFinite else { return nil }
        return min(max(parsed, metric.range.lowerBound), metric.range.upperBound)
    }

    static func displayText(_ value: Double, metric: EQDynamicMetric, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = metric.unit == .milliseconds ? 0 : 1
        formatter.maximumFractionDigits = metric.unit == .milliseconds ? 1 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Arrow step: decibels 0.5 / 3 / 0.1 dB; ratio and times scale by the Q ratios 1.1 / 1.5 / 1.02.
    static func nudged(_ value: Double, metric: EQDynamicMetric, direction: EQNudge.Direction, step: EQNudge.Step) -> Double {
        let limits = metric.range
        let moved: Double
        switch metric.unit {
        case .decibels:
            let raw = value + Double(direction.rawValue) * EQNudge.gainStep(step)
            moved = (raw * 1_000_000).rounded() / 1_000_000
        case .ratio, .milliseconds:
            let ratio = EQNudge.qRatio(step)
            moved = direction == .up ? value * ratio : value / ratio
        }
        return min(max(moved, limits.lowerBound), limits.upperBound)
    }
}

extension EQValueParser {
    fileprivate static func splitForMetric(_ text: String, locale: Locale) -> (Double, String)? {
        // "2:1" is a ratio: the number is the part before the colon, the unit ":1".
        split(text, locale: locale)
    }
}
