import Foundation

/// E28 S4: unit-aware text entry, stepping and slider scaling for parameter fields, generalised
/// from E27 S1's `EQValueParser` and `EQNudge`. Plain Swift, no UI and no engine access, so every
/// rule can be tested without an audio device. E28 S5 (G17): the EQ types are thin wrappers that keep their
/// field enums and share the number scanner and the step tables defined here.

/// The unit a parameter is shown and typed in.
enum ParameterUnit: Equatable, Sendable {
    case hertz, decibels, dbfs, lufs, milliseconds, seconds, ratio, phon, multiplier, plain

    /// The text shown after the field.
    var suffix: String {
        switch self {
        case .hertz: return "Hz"
        case .decibels: return "dB"
        case .dbfs: return "dBFS"
        case .lufs: return "LUFS"
        case .milliseconds: return "ms"
        case .seconds: return "s"
        case .ratio: return ":1"
        case .phon: return "phon"
        case .multiplier: return "×"
        case .plain: return ""
        }
    }

    /// Spoken form for accessibility values.
    var spoken: String {
        switch self {
        case .hertz: return "hertz"
        case .decibels: return "decibels"
        case .dbfs: return "decibels full scale"
        case .lufs: return "LUFS"
        case .milliseconds: return "milliseconds"
        case .seconds: return "seconds"
        case .ratio: return "to one"
        case .phon: return "phons"
        case .multiplier: return "times"
        case .plain: return ""
        }
    }
}

/// How a slider maps a value to a position in 0...1.
struct ParameterScale: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case linear
        /// Logarithmic. When the range starts at 0 the first `offStop` of travel is the "off" value (0)
        /// and the log run starts at `floor`.
        case logarithmic(floor: Double)
    }

    let kind: Kind

    static let linear = ParameterScale(kind: .linear)
    static func logarithmic(floor: Double) -> ParameterScale { ParameterScale(kind: .logarithmic(floor: floor)) }

    /// Share of the slider travel at the left stop that means "off" (0) on a log scale from 0.
    static let offStop = 0.02

    func position(of value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, value.isFinite else { return 0 }
        switch kind {
        case .linear:
            return Self.unit((value - range.lowerBound) / span)
        case .logarithmic(let floor):
            if range.lowerBound > 0 {
                return Self.unit(log(value / range.lowerBound) / log(range.upperBound / range.lowerBound))
            }
            guard value > 0, floor > 0, range.upperBound > floor else { return 0 }
            if value <= floor { return Self.offStop }
            let run = log(value / floor) / log(range.upperBound / floor)
            return Self.unit(Self.offStop + (1 - Self.offStop) * run)
        }
    }

    func value(at position: Double, in range: ClosedRange<Double>) -> Double {
        let p = Self.unit(position)
        switch kind {
        case .linear:
            return range.lowerBound + p * (range.upperBound - range.lowerBound)
        case .logarithmic(let floor):
            if range.lowerBound > 0 {
                return range.lowerBound * pow(range.upperBound / range.lowerBound, p)
            }
            if p < Self.offStop { return range.lowerBound }
            let run = (p - Self.offStop) / (1 - Self.offStop)
            return floor * pow(range.upperBound / floor, run)
        }
    }

    private static func unit(_ x: Double) -> Double {
        x.isNaN ? 0 : min(max(x, 0), 1)
    }
}

/// How a field steps with the arrow keys and VoiceOver adjustments.
enum ParameterStepKind: Equatable, Sendable {
    /// Times and frequencies: ratio 2^(1/12), Shift 2^(1/3), Option 2^(1/96).
    case multiplicativeTime
    /// dB: 0.5 / 3 / 0.1.
    case decibels
    /// Ratios: x1.1 / x1.5 / x1.02.
    case ratio
    /// A fixed increment; Shift is 5x, Option 0.1x.
    case linear(step: Double)
}

enum ValueParser {
    /// Parses `text` in `unit`; nil when it is not a valid entry (the caller keeps the old value).
    static func parse(_ text: String, unit: ParameterUnit, locale: Locale = .current) -> Double? {
        guard let (number, suffix) = split(text, locale: locale), number.isFinite else { return nil }
        switch unit {
        case .hertz:
            switch suffix {
            case "", "hz": return number
            case "k", "khz": return number * 1_000
            default: return nil
            }
        case .decibels:
            return suffix == "" || suffix == "db" ? number : nil
        case .dbfs:
            return suffix == "" || suffix == "db" || suffix == "dbfs" ? number : nil
        case .lufs:
            return suffix == "" || suffix == "lufs" || suffix == "lu" || suffix == "db" ? number : nil
        case .milliseconds:
            switch suffix {
            case "", "ms": return number
            case "s": return number * 1_000
            default: return nil
            }
        case .seconds:
            switch suffix {
            case "", "s": return number
            case "ms": return number / 1_000
            default: return nil
            }
        case .ratio:
            return suffix == "" || suffix == ":1" || suffix == "x" || suffix == "\u{00D7}" ? number : nil
        case .phon:
            return suffix == "" || suffix == "phon" || suffix == "phons" ? number : nil
        case .multiplier:
            return suffix == "" || suffix == "x" || suffix == "\u{00D7}" ? number : nil
        case .plain:
            return suffix == "" ? number : nil
        }
    }

    /// Parses and clamps to the engine's accepted range; nil means reject.
    static func value(from text: String, unit: ParameterUnit, range: ClosedRange<Double>, locale: Locale = .current) -> Double? {
        guard let parsed = parse(text, unit: unit, locale: locale), parsed.isFinite else { return nil }
        return min(max(parsed, range.lowerBound), range.upperBound)
    }

    /// Text for a field at rest, in the user's decimal separator, without grouping so it parses back.
    static func displayText(_ value: Double, digits: Int, minimumDigits: Int? = nil, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = minimumDigits ?? digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "12.5 milliseconds" for the accessibility value.
    static func spokenText(_ value: Double, unit: ParameterUnit, digits: Int, locale: Locale = .current) -> String {
        let text = displayText(value, digits: digits, locale: locale)
        return unit.spoken.isEmpty ? text : "\(text) \(unit.spoken)"
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

enum ValueNudge {
    enum Step: Equatable, Sendable {
        case normal
        /// Shift.
        case coarse
        /// Option.
        case fine

        init(shift: Bool, option: Bool) {
            self = option ? .fine : (shift ? .coarse : .normal)
        }
    }

    /// +1 or -1.
    enum Direction: Int, Sendable {
        case down = -1
        case up = 1
    }

    /// Time and frequency ratio per step: 2^(1/12), 2^(1/3) (Shift), 2^(1/96) (Option).
    static func timeRatio(_ step: Step) -> Double {
        switch step {
        case .normal: return pow(2, 1.0 / 12.0)
        case .coarse: return pow(2, 1.0 / 3.0)
        case .fine: return pow(2, 1.0 / 96.0)
        }
    }

    /// dB per step: 0.5, 3, 0.1.
    static func decibelStep(_ step: Step) -> Double {
        switch step {
        case .normal: return 0.5
        case .coarse: return 3
        case .fine: return 0.1
        }
    }

    /// Ratio (and Q) per step: 1.1, 1.5, 1.02.
    static func ratioStep(_ step: Step) -> Double {
        switch step {
        case .normal: return 1.1
        case .coarse: return 1.5
        case .fine: return 1.02
        }
    }

    /// The value one step from `value`, clamped to `range`. On a multiplicative kind a value of 0 steps up
    /// to `floor` and a value that would fall below `floor` goes to the range's lower bound when that is 0.
    static func nudged(
        _ value: Double,
        kind: ParameterStepKind,
        direction: Direction,
        step: Step,
        range: ClosedRange<Double>,
        floor: Double
    ) -> Double {
        let moved: Double
        switch kind {
        case .decibels:
            moved = rounded(value + Double(direction.rawValue) * decibelStep(step))
        case .linear(let increment):
            let scale: Double
            switch step {
            case .normal: scale = 1
            case .coarse: scale = 5
            case .fine: scale = 0.1
            }
            moved = rounded(value + Double(direction.rawValue) * increment * scale)
        case .multiplicativeTime, .ratio:
            let ratio = kind == .ratio ? ratioStep(step) : timeRatio(step)
            if value <= 0 {
                moved = direction == .up ? floor : value
            } else {
                let next = direction == .up ? value * ratio : value / ratio
                moved = range.lowerBound <= 0 && next < floor ? 0 : next
            }
        }
        return min(max(moved, range.lowerBound), range.upperBound)
    }

    /// Rounded to 1e-6 so repeated small steps do not drift.
    private static func rounded(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }
}
