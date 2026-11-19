import SwiftUI

/// E33 S19: colours of the reference curves.
enum EQReferenceCurveStyle {
    static func color(for kind: EQReferenceCurveKind) -> Color {
        switch kind {
        case .measurement: return .teal
        case .corrected: return .green
        case .target: return .yellow
        }
    }
}

/// E33 S19: picks which reference curves sit behind the bands. Shown only when a saved measurement or target exists.
struct EQReferenceCurveMenu: View {
    let curves: [EQReferenceCurve]
    @Binding var raw: String

    var body: some View {
        Menu {
            ForEach(curves) { curve in
                Toggle(curve.label, isOn: binding(for: curve.kind))
            }
        } label: {
            Label("Reference", systemImage: "waveform.path")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show a saved measurement or the correction target behind the bands. These curves never change the EQ.")
        .accessibilityLabel("Reference curves")
    }

    private func binding(for kind: EQReferenceCurveKind) -> Binding<Bool> {
        Binding(
            get: { EQReferenceSelection.kinds(from: raw).contains(kind) },
            set: { on in
                var kinds = EQReferenceSelection.kinds(from: raw)
                if on { kinds.insert(kind) } else { kinds.remove(kind) }
                raw = EQReferenceSelection.raw(from: kinds)
            }
        )
    }
}
