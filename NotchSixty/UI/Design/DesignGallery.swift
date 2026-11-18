#if DEBUG
import SwiftUI

/// E34 S1: debug-only gallery of every shared component in every state, at both styles side by side. Open it from
/// Window > Design Gallery in a debug build.
struct DesignGalleryView: View {
    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                column(.current, heading: "Current values")
                column(.redesigned, heading: "Redesigned values (flag on)")
            }
            .padding(24)
        }
        .frame(minWidth: 900, minHeight: 700)
    }

    private func column(_ style: DesignStyle, heading: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.value(style)) {
            Text(heading).font(DesignType.sectionTitle.font(style))
            DesignPageHeader(title: "Page title", subtitle: "A line of reading text.", status: .good,
                             statusText: "Running", style: style) {
                DesignButton(title: "Main action", systemImage: "play.fill", role: .primary) {}
            }
            DesignCard(style: style) {
                VStack(alignment: .leading, spacing: DesignSpacing.s.value(style)) {
                    Text("Card").font(DesignType.sectionTitle.font(style))
                    Text("Body text meant to be read.").font(DesignType.body.font(style))
                    Text("Caption: secondary note only.").font(DesignType.caption.font(style))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                ForEach(StatusLevel.allCases, id: \.self) { DesignStatusBadge(level: $0, style: style) }
            }
            HStack {
                DesignButton(title: "Primary", systemImage: nil, role: .primary) {}
                DesignButton(title: "Secondary", systemImage: nil, role: .secondary) {}
                DesignButton(title: "Delete", systemImage: nil, role: .destructive) {}
            }
            ForEach(DesignStateKind.allCases, id: \.self) { kind in
                DesignCard(style: style) {
                    DesignStateView(kind: kind, title: "\(kind)".capitalized, detail: "What happens next.",
                                    style: style)
                }
            }
            DesignCard(style: style) {
                VStack(alignment: .leading) {
                    Text(DesignFormat.db(-6.04)); Text(DesignFormat.db(3.5, signed: true))
                    Text(DesignFormat.hz(63)); Text(DesignFormat.hz(1250)); Text(DesignFormat.ms(12.5))
                    Text(DesignFormat.percent(0.5))
                }
                .font(DesignType.body.font(style))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
#endif
