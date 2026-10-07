import SwiftUI

struct ProductionPluginWorkspace: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var host: AudioUnitHostController

    private var processingFormat: AudioUnitRackProcessingFormat {
        let channelCount: Int
        if let profile = engine.outputDeviceProfileConfiguration,
           profile.enabled {
            channelCount = profile.programLayout.roles.count
        } else if let profile = engine.headphoneDeviceProfileConfiguration,
                  profile.enabled {
            channelCount = profile.programLayout.roles.count
        } else {
            channelCount = 2
        }
        return AudioUnitRackProcessingFormat(
            sampleRate: engine.selectedOutputDevice?.nominalSampleRate ?? 48_000,
            channelCount: max(1, min(
                AudioUnitRackProcessingFormat.maximumChannelCount,
                channelCount
            )),
            maximumFramesPerSlice: 4_096
        )
    }

    private var compatibleCount: Int {
        host.discoveredComponents.lazy.filter {
            host.compatibility(of: $0, for: processingFormat).compatible
        }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                signalChainCard
                scanCard
                rackCard
                catalogCard
                safetyCard
            }
            .padding(28)
            .frame(maxWidth: 1_020, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Plug-ins")
                    .font(.largeTitle.bold())
                Text("Audio Unit discovery, offline validation, live hosting, and rack state.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("LIVE HOST READY")
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
                chainNode("Plug-in Rack", active: true)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                chainNode("System Correction", active: true)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                chainNode("Protection", active: true)
            }

            Text("The rack is Playback/content state. Third-party effects remain upstream of speaker/headphone correction, bass management, routing, and final protection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Installed Audio Units")
                        .font(.headline)
                    Text(
                        "\(processingFormat.channelCount)-channel symmetric rack · \(processingFormat.sampleRate / 1_000, specifier: "%.1f") kHz"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    host.scan(format: processingFormat)
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
            }

            HStack(spacing: 24) {
                scanMetric("Discovered", "\(host.discoveredComponents.count)")
                scanMetric("Compatible", "\(compatibleCount)")
                scanMetric("Prepared", "\(host.preparedComponentCount)")
                scanMetric("Quarantined", "\(host.quarantinedComponentCount)")
            }

            if let date = host.lastScanDate {
                Text("Last scan: \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let error = host.lastErrorDescription {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
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
                    Text("Rack state follows the selected Content Preset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("LIVE ENGINE READY")
                    .font(.caption.bold())
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(host.rackConfiguration.slots.enumerated()), id: \.element.id) { index, slot in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 22)

                    Image(systemName: slot.isEmpty
                        ? "puzzlepiece.extension"
                        : "waveform.badge.plus")
                        .foregroundStyle(.tertiary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot.displayName ?? "Empty Slot")
                            .font(.subheadline.weight(.semibold))
                        if let manufacturer = slot.manufacturerName {
                            Text(manufacturer)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if slot.isEmpty {
                        Text("Empty")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(slot.bypassed ? "Bypassed" : "Prepared")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(.quaternary.opacity(0.14), in: .rect(cornerRadius: 12))
            }

            HStack {
                Button {
                    // Rack editing UI is intentionally deferred beyond PR81.
                } label: {
                    Label("Add Plug-in", systemImage: "plus")
                }
                .buttonStyle(.glass)
                .disabled(true)
                .help("PR81 activates already-saved, validated rack state at processing start. Add/reorder/vendor UI remains deferred.")

                Spacer()

                Text("Maximum \(AudioUnitRackConfiguration.maximumSlotCount) slots")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private var catalogCard: some View {
        if host.lastScanDate == nil {
            ContentUnavailableView(
                "Audio Unit catalog not scanned",
                systemImage: "puzzlepiece.extension",
                description: Text(
                    "Scan to inspect installed Audio Unit effects without opening or instantiating them."
                )
            )
            .frame(maxWidth: .infinity, minHeight: 220)
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Compatibility Catalog")
                    .font(.headline)

                if host.discoveredComponents.isEmpty {
                    Text("No registered Audio Unit effects or music effects were found.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(host.discoveredComponents) { component in
                        componentRow(component)
                    }
                }
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    private func componentRow(
        _ component: AudioUnitComponentDescriptor
    ) -> some View {
        let compatibility = host.compatibility(
            of: component,
            for: processingFormat
        )
        let lifecycle = host.lifecycleByComponent[component.identity]

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: compatibility.compatible
                ? "checkmark.circle.fill"
                : "xmark.circle")
                .foregroundStyle(
                    compatibility.compatible
                        ? Color.primary.opacity(0.62)
                        : Color.orange
                )
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(component.name)
                        .font(.subheadline.weight(.semibold))
                    Text(component.versionString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text("\(component.manufacturerName) · \(component.typeName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(component.identity.fourCCSummary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)

                if !compatibility.compatible {
                    Text(compatibility.reasons.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(lifecycleLabel(lifecycle))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if component.hasCustomView {
                    Label("Custom UI", systemImage: "macwindow")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 7)
    }

    private var safetyCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 5) {
                Text("Live host with an off-realtime preparation boundary")
                    .font(.subheadline.weight(.semibold))
                Text("PR81 revalidates active saved slots before startup, constructs immutable Audio Unit instances and buffers off realtime, then renders them at the Playback/System boundary. Runtime plug-in faults fall back immediately to latency-matched dry audio and are quarantined on the control plane. Discovery, instantiation, state restore, allocation, logging, and UI work never occur in the production callback.")
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

    private func scanMetric(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func lifecycleLabel(
        _ state: AudioUnitComponentLifecycleState?
    ) -> String {
        switch state {
        case .discovered: return "DISCOVERED"
        case .probing: return "PROBING"
        case .prepared: return "PREPARED"
        case .quarantined: return "QUARANTINED"
        case nil: return "UNSCANNED"
        }
    }

    private func chainNode(
        _ title: String,
        active: Bool
    ) -> some View {
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
