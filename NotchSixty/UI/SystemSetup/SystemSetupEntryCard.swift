import SwiftUI
import UniformTypeIdentifiers

// E12 S29: split out of ProductionSystemSetupFlowView.swift with no change in behaviour.

// MARK: - Entry cards (design note 10)

/// The "Set up my system" card shown on the Dashboard and System Overview. Hidden with the flag
/// off; shows a pointer to Headphones for headphone outputs.
struct SystemSetupEntryCard: View {
    let availability: SystemSetupEntryPolicy.Availability
    let start: () -> Void
    /// E12 S10: set when `e12.setup-flow` is on; adds the quick path beside the full flow.
    var startQuick: (() -> Void)?
    let openHeadphones: () -> Void

    private func offerRow(showsExplanation: Bool) -> some View {
        HStack(spacing: DesignSpacing.m.pt) {
            Label("Set up my system", systemImage: "wand.and.stars").font(.headline).fixedSize()
            if showsExplanation {
                Text("Choose your speakers, set levels and measure your room in one guided flow.")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: DesignSpacing.m.pt)
            if let startQuick {
                Button("Quick setup", action: startQuick)
                    .help("About ten minutes: one seat, default bass and correction. The full setup is offered at the end.")
                Button("Full setup", action: start)
            } else {
                Button("Start", action: start)
            }
        }
    }

    var body: some View {
        switch availability {
        case .hidden:
            EmptyView()
        case .headphonesPointer:
            GroupBox {
                HStack {
                    Label("This output looks like headphones. Headphone correction lives in Headphones.",
                          systemImage: "headphones")
                    Spacer()
                    Button("Open Headphones", action: openHeadphones)
                }.padding(4)
            }
        case .offer:
            // One line when there is room (the explanation drops first), so the card costs about 40 pt of page height.
            ViewThatFits(in: .horizontal) {
                offerRow(showsExplanation: true)
                offerRow(showsExplanation: false)
            }
            .padding(.horizontal, DesignSpacing.m.pt)
            .padding(.vertical, DesignSpacing.s.pt)
            .frame(maxWidth: .infinity, alignment: .leading)
            .designSurface(.large)
        }
    }
}
