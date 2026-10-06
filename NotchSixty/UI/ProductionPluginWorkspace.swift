import SwiftUI

struct ProductionPluginWorkspace: View {
    private let slotCount = 4

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                signalChainCard
                rackCard
                safetyCard
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Plug-ins")
                    .font(.largeTitle.bold())
                Text("A bounded playback effects rack for Audio Unit processing.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("EXTENSIONS")
                .font(.caption.bold())
                .tracking(1.3)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private var signalChainCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Signal-chain position")
                .font(.headline)

            HStack(spacing: 10) {
                chainNode("Playback DSP", active: true)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                chainNode("Plug-in Rack", active: false)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                chainNode("System Correction", active: true)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                chainNode("Protection", active: true)
            }

            Text("Third-party plug-ins will remain upstream of speaker/headphone correction, bass management, routing, and final protection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var rackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playback Plug-in Rack")
                        .font(.headline)
                    Text("AU host foundation is the next implementation slice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("NOT ACTIVE")
                    .font(.caption.bold())
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
            }

            ForEach(0..<slotCount, id: \.self) { index in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 22)

                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(.tertiary)

                    Text("Empty Slot")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Text("Bypassed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(.quaternary.opacity(0.14), in: .rect(cornerRadius: 12))
            }

            Button {
                // PR78 intentionally provides information architecture only.
            } label: {
                Label("Add Plug-in", systemImage: "plus")
            }
            .buttonStyle(.glass)
            .disabled(true)
            .help("Audio Unit hosting is not active yet.")
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var safetyCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("System safety remains outside the rack")
                    .font(.subheadline.weight(.semibold))
                Text("Plug-ins will never be allowed to move behind physical crossover, speaker/headphone protection, or the final limiter. Unsupported channel layouts will fail closed rather than silently downmixing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "lock.shield")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.16), in: .rect(cornerRadius: 14))
    }

    private func chainNode(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(active ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color.primary.opacity(active ? 0.10 : 0.05),
                in: .capsule
            )
    }
}
