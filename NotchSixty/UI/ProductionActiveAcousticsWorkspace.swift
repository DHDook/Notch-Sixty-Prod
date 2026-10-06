import SwiftUI

private enum ActiveAcousticsTab: String, CaseIterable, Identifiable {
    case ambientAnalysis
    case roomTreatment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ambientAnalysis: return "Ambient Analysis"
        case .roomTreatment: return "Room Treatment"
        }
    }
}

struct ProductionActiveAcousticsWorkspace: View {
    @ObservedObject var engine: AudioIOEngine

    @State private var selection: ActiveAcousticsTab = .ambientAnalysis
    @State private var transportSnapshot: ProductionTransportMeterSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                Picker("Active Acoustics", selection: $selection) {
                    ForEach(ActiveAcousticsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .productionGlassPickerChrome()
                .frame(maxWidth: 520)

                switch selection {
                case .ambientAnalysis:
                    ambientAnalysis
                case .roomTreatment:
                    roomTreatment
                }
            }
            .padding(28)
            .frame(maxWidth: 1_080, alignment: .topLeading)
        }
        .task(id: engine.lifecycleState.rawValue) {
            await refreshTransportLoop()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Active Acoustics")
                    .font(.largeTitle.bold())
                Text("Analyze the acoustic environment and manage hardware-gated low-frequency room treatment.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("SYSTEM")
                .font(.caption.bold())
                .tracking(1.3)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private var ambientAnalysis: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusBanner(
                title: "Passive analysis foundation ready",
                detail: "Ambient Analysis can separate modeled playback from environmental sound and characterize low-frequency energy, tones, periodicity, and stationarity. Continuous room-microphone monitoring is not activated in the production path yet.",
                systemImage: "waveform.and.mic"
            )

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 14
            ) {
                metricCard(
                    title: "Ambient Level",
                    value: "—",
                    detail: "Requires a live calibrated microphone feed."
                )
                metricCard(
                    title: "Analysis Confidence",
                    value: "—",
                    detail: "Playback subtraction fails closed when a required acoustic model is missing."
                )
                metricCard(
                    title: "Low-Frequency Energy",
                    value: "20–250 Hz",
                    detail: "The passive analyzer scores stable low-frequency content for future acoustic-control workflows."
                )
                metricCard(
                    title: "Detected Character",
                    value: "Standby",
                    detail: "Broadband, tonal, periodic, mixed, and nonstationary classifications are available offline."
                )
            }

            informationCard(
                title: "What this page will show",
                items: [
                    "Residual environmental spectrum after modeled playback subtraction.",
                    "Stable tonal components such as HVAC, fan, appliance, or road-noise fundamentals.",
                    "Stationarity and periodicity confidence over time.",
                    "A descriptive low-frequency control-candidate score — never an automatic anti-noise command.",
                ]
            )

            safetyNote(
                "Ambient Analysis is observation-only. It does not generate anti-noise, alter playback, or arm the room-treatment runtime."
            )
        }
    }

    private var roomTreatment: some View {
        VStack(alignment: .leading, spacing: 16) {
            roomTreatmentStatusCard

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 14
            ) {
                metricCard(
                    title: "Treatment Band",
                    value: "20–150 Hz",
                    detail: "Conservative low-frequency scope for the current MIMO designer."
                )
                metricCard(
                    title: "Treatment Sources",
                    value: treatmentSourceValue,
                    detail: treatmentSourceDetail
                )
                metricCard(
                    title: "Added Latency",
                    value: treatmentLatencyValue,
                    detail: "All physical outputs are latency-matched whenever a treatment runtime is configured."
                )
                metricCard(
                    title: "Protection",
                    value: protectionValue,
                    detail: protectionDetail
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Acceptance Path")
                    .font(.headline)

                readinessRow(
                    title: "MIMO design",
                    detail: "Regularized, bounded spatial design and robustness simulation",
                    state: "Ready",
                    systemImage: "checkmark.circle.fill"
                )
                readinessRow(
                    title: "FIR realization",
                    detail: "Causal matrix FIR with dense post-compile safety verification",
                    state: "Ready",
                    systemImage: "checkmark.circle.fill"
                )
                readinessRow(
                    title: "Repeat measurement",
                    detail: "Treated room must measurably improve without a hidden level shift",
                    state: engine.roomTreatmentStagedForNextStart ? "Accepted" : "Required",
                    systemImage: engine.roomTreatmentStagedForNextStart
                        ? "checkmark.circle.fill"
                        : "circle.dashed"
                )
                readinessRow(
                    title: "Hardware acceptance",
                    detail: "Excursion, thermal, protection, lifecycle, and audible-artifact checks",
                    state: hardwareGateLabel,
                    systemImage: engine.roomTreatmentStagedForNextStart
                        ? "checkmark.shield.fill"
                        : "lock.shield"
                )
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

            safetyNote(
                "PR78 intentionally exposes status only. Room Treatment has no Arm, Bypass, or Stage control in the production UI until the real-hardware acceptance workflow is completed."
            )
        }
    }

    private var roomTreatmentStatusCard: some View {
        let treatment = transportSnapshot?.roomTreatment

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("MIMO Room Treatment", systemImage: "waveform.path.ecg.rectangle")
                    .font(.headline)
                Spacer()
                Text(treatmentStatus)
                    .font(.caption.bold())
                    .tracking(1.0)
                    .foregroundStyle(treatment?.faulted == true ? .red : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }

            if let treatment {
                HStack(spacing: 18) {
                    LabeledContent("Mix") {
                        Text("\(Double(treatment.treatmentMix * 100), specifier: "%.0f")%")
                            .monospacedDigit()
                    }
                    LabeledContent("Clamps") {
                        Text("\(treatment.protectionClampSamples)")
                            .monospacedDigit()
                    }
                    LabeledContent("Failures") {
                        Text("\(treatment.integrationFailures)")
                            .monospacedDigit()
                    }
                }
                .font(.subheadline)

                Text(
                    treatment.faulted
                        ? "A runtime/protection fault is latched. The transition substrate returns toward latency-matched identity rather than leaving a partial treatment topology."
                        : "The live transport is reporting the hardware-gated treatment substrate. Authorization and arming remain separate states."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if engine.roomTreatmentStagedForNextStart {
                Text("A hardware-accepted treatment is staged for the next semantic-speaker start. It remains default-bypassed until the internal control plane explicitly arms it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No treatment is staged. The normal speaker path runs without PR77's additional treatment latency.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var treatmentStatus: String {
        guard let treatment = transportSnapshot?.roomTreatment else {
            return engine.roomTreatmentStagedForNextStart ? "STAGED" : "NOT STAGED"
        }
        if treatment.faulted { return "FAULT" }
        if treatment.active { return "ACTIVE" }
        if treatment.transitioning { return "TRANSITIONING" }
        if treatment.authorized { return "BYPASSED · AUTHORIZED" }
        return "BYPASSED"
    }

    private var treatmentSourceValue: String {
        if let count = transportSnapshot?.roomTreatment?.treatmentSourceCount {
            return "\(count)"
        }
        return engine.roomTreatmentStagedForNextStart ? "Accepted set" : "—"
    }

    private var treatmentSourceDetail: String {
        if transportSnapshot?.roomTreatment != nil {
            return "Exact speaker/Sub N source identities are bound to the accepted physical route."
        }
        return "No live treatment source map is currently installed."
    }

    private var treatmentLatencyValue: String {
        guard let treatment = transportSnapshot?.roomTreatment else { return "0 frames" }
        let milliseconds = transportSnapshot.map {
            Double(treatment.latencyFrames) / max($0.sampleRate, 1) * 1_000
        } ?? 0
        return "\(treatment.latencyFrames) frames · \(milliseconds, specifier: "%.1f") ms"
    }

    private var protectionValue: String {
        guard let treatment = transportSnapshot?.roomTreatment else {
            return engine.roomTreatmentStagedForNextStart ? "Hardware-gated" : "Not engaged"
        }
        if treatment.faulted { return "FAULT · SAFE BYPASS" }
        if treatment.protectionClampSamples > 0 { return "Clamp observed" }
        return "Normal"
    }

    private var protectionDetail: String {
        guard let treatment = transportSnapshot?.roomTreatment else {
            return "Physical source safety and final protection are prerequisites for staging."
        }
        return "\(treatment.protectionClampSamples) emergency clamp samples · \(treatment.integrationFailures) integration failures."
    }

    private func statusBanner(
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func metricCard(
        title: String,
        value: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func informationCard(
        title: String,
        items: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.headline)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .padding(.top, 6)
                    Text(item)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func readinessRow(
        title: String,
        detail: String,
        state: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(state)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func safetyNote(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.16), in: .rect(cornerRadius: 14))
    }

    @MainActor
    private func refreshTransportLoop() async {
        transportSnapshot = engine.productionTransportMeterSnapshot()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { break }
            transportSnapshot = engine.productionTransportMeterSnapshot()
        }
    }
}
