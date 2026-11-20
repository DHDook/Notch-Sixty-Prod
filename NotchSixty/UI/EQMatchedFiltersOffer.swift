import SwiftUI

/// E33 S26 (G51, owner decision 32): which design a band gets. New bands are matched; APO and AutoEQ imports and EQ-fit
/// bands stay cookbook; a saved EQ keeps its cookbook bands until the user chooses "Use matched filters" on the page.
enum EQMatchedFiltersPolicy {
    /// A band the page adds (Add Band, double-click on the graph): matched when the enhanced page is on.
    static func newBand(_ band: EQBand, enhanced: Bool) -> EQBand {
        guard enhanced else { return band }
        var result = band
        result.filterMethod = .matched
        return result
    }

    /// The bands the "Use matched filters" offer would change: cookbook bands the matched design applies to.
    static func eligible(_ bands: [EQBand]) -> [EQBand] {
        bands.filter { $0.filterMethod != .matched && $0.matchedFilterApplies }
    }

    /// True when a dynamic band of a matched-capable shape exists, which keeps the standard design (G51 decision).
    static func hasDynamicBandNote(_ bands: [EQBand]) -> Bool {
        bands.contains { $0.dynamic.enabled && $0.type == .peaking }
    }
}

/// The offer row under the bands header: one button (a single undo step through the page's `recorded`) and the dynamic note.
struct EQMatchedFiltersOffer: View {
    let bands: [EQBand]
    let onUse: () -> Void

    var body: some View {
        let count = EQMatchedFiltersPolicy.eligible(bands).count
        if count > 0 || EQMatchedFiltersPolicy.hasDynamicBandNote(bands) {
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                if count > 0 {
                    HStack(spacing: DesignSpacing.s.pt) {
                        Text("Matched filters keep their shape near the top of the band.")
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Use matched filters", action: onUse)
                            .controlSize(.small)
                            .help("Switch \(count) band\(count == 1 ? "" : "s") to the matched design. Undo reverses it.")
                            .accessibilityIdentifier("eq.bands.useMatched")
                    }
                }
                if EQMatchedFiltersPolicy.hasDynamicBandNote(bands) {
                    Text("Dynamic bands use the standard filter design.")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("eq.bands.dynamicNote")
                }
            }
            .padding(.horizontal, DesignSpacing.s.pt)
        }
    }
}
