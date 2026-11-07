import Foundation

/// E11 (owner-requested Equalizer page band panel, 7 Nov 2026): plain-Swift text and
/// selection rules for the Bands panel and the graph handles, kept out of the view so
/// they can be tested without an audio device. Presentation only: it never touches the
/// EQ model or the engine.
enum EQBandPanelModel {
    /// "45 Hz", "2 kHz", "1.5 kHz".
    static func frequencyText(_ hertz: Double) -> String {
        hertz >= 1_000 ? String(format: "%.2g kHz", hertz / 1_000) : String(format: "%.0f Hz", hertz)
    }

    /// "+0.4 dB", "-3.0 dB"; values that round to zero show "0.0 dB" (never "-0.0").
    static func gainText(_ decibels: Double) -> String {
        let rounded = (decibels * 10).rounded() / 10
        if rounded == 0 { return "0.0 dB" }
        return String(format: "%+.1f dB", rounded)
    }

    /// "7 of 64".
    static func countText(count: Int, maximum: Int) -> String {
        "\(count) of \(maximum)"
    }

    /// "Band 3, Peak, 300 hertz, minus 0.7 decibels, enabled".
    static func accessibilityLabel(number: Int, band: EQBand) -> String {
        var parts = ["Band \(number)", band.type.displayName, spokenFrequency(band.frequencyHz), spokenGain(band.gainDB)]
        if band.dynamic.enabled { parts.append("dynamic") }
        parts.append(band.enabled ? "enabled" : "disabled")
        return parts.joined(separator: ", ")
    }

    private static func spokenFrequency(_ hertz: Double) -> String {
        hertz >= 1_000
            ? String(format: "%.2g kilohertz", hertz / 1_000)
            : String(format: "%.0f hertz", hertz)
    }

    private static func spokenGain(_ decibels: Double) -> String {
        let rounded = (decibels * 10).rounded() / 10
        if rounded == 0 { return "0 decibels" }
        let magnitude = String(format: "%.1f", abs(rounded))
        return rounded < 0 ? "minus \(magnitude) decibels" : "plus \(magnitude) decibels"
    }

    /// Keeps the current selection while it still exists, otherwise falls back to the first band.
    static func ensuredSelection(current: UUID?, bands: [EQBand]) -> UUID? {
        if let current, bands.contains(where: { $0.id == current }) { return current }
        return bands.first?.id
    }

    /// Previous or next band, wrapping at both ends. With no valid selection it counts from the first band.
    static func adjacentSelection(from current: UUID?, offset: Int, bands: [EQBand]) -> UUID? {
        guard !bands.isEmpty else { return nil }
        let index = current.flatMap { id in bands.firstIndex(where: { $0.id == id }) } ?? 0
        let next = ((index + offset) % bands.count + bands.count) % bands.count
        return bands[next].id
    }

    /// Selection after `removed` is deleted from `bandsBefore`: unchanged if another band was
    /// selected, otherwise the band that takes the removed band's place (or the new last band).
    static func selectionAfterRemoving(removed: UUID, selected: UUID?, bandsBefore: [EQBand]) -> UUID? {
        let remaining = bandsBefore.filter { $0.id != removed }
        if let selected, selected != removed, remaining.contains(where: { $0.id == selected }) { return selected }
        guard !remaining.isEmpty else { return nil }
        let removedIndex = bandsBefore.firstIndex(where: { $0.id == removed }) ?? 0
        return remaining[min(removedIndex, remaining.count - 1)].id
    }
}
