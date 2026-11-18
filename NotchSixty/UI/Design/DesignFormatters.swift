import Foundation

/// E34 S1: one way to write dB, Hz, ms and percent. Deterministic and locale-independent (v1 is English only), so
/// the same value reads the same on every page.
///
/// Rules: a space between number and unit; a true minus sign (U+2212); negative zero never shows; `signed` adds "+"
/// for positive values and is for gains and offsets, not for levels that are never positive.
enum DesignFormat {
    static let minus = "\u{2212}"

    private static func number(_ value: Double, decimals: Int, signed: Bool) -> String {
        guard value.isFinite else { return "\u{2013}" }
        var text = String(format: "%.\(decimals)f", abs(value))
        let isZero = Double(text) == 0
        if isZero { text = String(format: "%.\(decimals)f", 0.0) }
        if value < 0, !isZero { return minus + text }
        if signed, value > 0, !isZero { return "+" + text }
        return text
    }

    /// Decibels, one decimal: "-6.0 dB", "+3.5 dB".
    static func db(_ value: Double, signed: Bool = false) -> String {
        number(value, decimals: 1, signed: signed) + " dB"
    }

    /// Frequency: below 1 kHz whole hertz ("63 Hz"), from 1 kHz kilohertz with up to two decimals ("1.25 kHz", "20 kHz").
    static func hz(_ value: Double) -> String {
        guard value.isFinite else { return "\u{2013}" }
        if abs(value) < 1000 { return number(value, decimals: 0, signed: false) + " Hz" }
        var text = number(value / 1000, decimals: 2, signed: false)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + " kHz"
    }

    /// Milliseconds, one decimal: "12.5 ms".
    static func ms(_ value: Double, signed: Bool = false) -> String {
        number(value, decimals: 1, signed: signed) + " ms"
    }

    /// Percent from a fraction (0.5 is "50 %"), whole numbers.
    static func percent(_ fraction: Double, signed: Bool = false) -> String {
        number(fraction * 100, decimals: 0, signed: signed) + " %"
    }
}
