import Foundation

/// E33 S1: pure layout, picker and note rules for the Equalizer page's band list and band editor, kept out of
/// the view so they can be tested without a window. Presentation only: it never touches the EQ model or the
/// engine. Read only when `e33.page-enhancements` is on; off, the page keeps its old layout.
enum EQEditorControl: String, CaseIterable, Sendable {
    // Static column.
    case filter, frequency, gain, q, slope, constantQ, linkwitzTargetFrequency, linkwitzTargetQ, firKernel
    // Dynamic column.
    case dynamicToggle, direction, threshold, ratio, maxCut, attack, release, detector, rmsWindow
    case boostThreshold, boostRatio, maxBoost
}

enum EQEditorLayout {
    enum Columns: Equatable, Sendable { case one, two }

    /// Page width at which the two editor columns (static about 330 pt, dynamic about 330 pt, gaps and padding)
    /// fit beside nothing else; below it the editor is one scrolling column. The window's narrowest Equalizer detail
    /// is about 780 pt and its default about 950 pt. E22 checks the breakpoint by eye at three window sizes.
    static let twoColumnMinimumWidth = 900.0

    static func columns(pageWidth: Double) -> Columns {
        pageWidth >= twoColumnMinimumWidth ? .two : .one
    }

    /// The band list takes about one third of the page width, never narrower than the row needs.
    static func listWidth(pageWidth: Double) -> Double {
        max(280, (pageWidth / 3).rounded())
    }

    /// Controls the static column shows for `band`, in order.
    static func staticControls(for band: EQBand) -> [EQEditorControl] {
        var controls: [EQEditorControl] = [.filter, .frequency, .gain, .q]
        if band.type.supportsSlope { controls.append(.slope) }
        if band.type == .peaking { controls.append(.constantQ) }
        if band.type == .linkwitzTransform { controls += [.linkwitzTargetFrequency, .linkwitzTargetQ] }
        if band.type == .fir { controls.append(.firKernel) }
        return controls
    }

    /// Controls the dynamic column shows for `band`, in order. Empty when the type has no dynamic mode.
    static func dynamicControls(for band: EQBand) -> [EQEditorControl] {
        guard band.type.supportsDynamicEQ else { return [] }
        var controls: [EQEditorControl] = [.dynamicToggle]
        guard band.dynamic.enabled else { return controls }
        controls += [.direction, .threshold, .ratio, .maxCut, .attack, .release, .detector]
        if band.dynamic.detectorMode == .rms { controls.append(.rmsWindow) }
        if band.dynamic.direction != .cutOnly { controls += [.boostThreshold, .boostRatio, .maxBoost] }
        return controls
    }

    struct Placement: Equatable, Sendable {
        var leading: [EQEditorControl]
        var trailing: [EQEditorControl]
        /// Controls stacked below the leading column (single-column mode only).
        var isSingleColumn: Bool { trailing.isEmpty }
    }

    /// Where each control sits: two columns put static left and dynamic right; one column stacks static then
    /// dynamic in a single scrolling column.
    static func placement(for band: EQBand, columns: Columns) -> Placement {
        let statics = staticControls(for: band)
        let dynamics = dynamicControls(for: band)
        switch columns {
        case .two: return Placement(leading: statics, trailing: dynamics)
        case .one: return Placement(leading: statics + dynamics, trailing: [])
        }
    }

    /// Height of the list panel: sized to its rows, capped so a long list scrolls instead of growing the page.
    static func listHeight(bandCount: Int) -> Double {
        let rows = Double(max(1, min(bandCount, 9)))
        return 56 + rows * 38
    }
}

/// Filter picker sections (design 8): everyday filters first, then the special ones.
enum EQFilterPickerModel {
    struct Section: Equatable, Sendable {
        var title: String
        var types: [EQFilterType]
    }

    /// E33 S18 (G34, owner 16 Nov 2026): FIR is not offered; no stored or built-in profile holds a FIR band.
    static let sections: [Section] = [
        Section(title: "Basic", types: [.peaking, .lowShelf, .highShelf, .lowPass, .highPass, .bandPass, .notch]),
        Section(title: "Special", types: [.linkwitzTransform, .tilt, .allPass])
    ]

    static func sectionTitle(of type: EQFilterType) -> String? {
        sections.first { $0.types.contains(type) }?.title
    }
}

/// The Dynamic toggle's range hint and the moved-to-fit note (design 8).
enum EQDynamicHint {
    private static func hz(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%g kHz", value / 1_000) : String(format: "%g Hz", value)
    }

    /// "Dynamic bands: 20 Hz to 20 kHz, Q 0.4 to 8".
    static var rangeText: String {
        let f = DynamicEQBandConfiguration.frequencyRange
        let q = DynamicEQBandConfiguration.qRange
        return "Dynamic bands: \(hz(f.lowerBound)) to \(hz(f.upperBound)), Q \(q.lowerBound.formatted()) to \(q.upperBound.formatted())"
    }

    /// One sentence naming each frequency, Q or gain the sanitiser moved; nil when nothing moved. Edits to
    /// other fields are not described: the field itself already shows the clamped value.
    static func movedNote(from requested: EQBand, to fitted: EQBand) -> String? {
        var parts: [String] = []
        if requested.frequencyHz != fitted.frequencyHz {
            parts.append("frequency \(hz(requested.frequencyHz)) to \(hz(fitted.frequencyHz))")
        }
        if requested.q != fitted.q {
            parts.append("Q \(String(format: "%g", requested.q)) to \(String(format: "%g", fitted.q))")
        }
        if requested.gainDB != fitted.gainDB {
            parts.append("gain \(String(format: "%+g", requested.gainDB)) dB to \(String(format: "%+g", fitted.gainDB)) dB")
        }
        guard !parts.isEmpty else { return nil }
        return "Moved to fit: " + parts.joined(separator: ", ") + "."
    }
}
