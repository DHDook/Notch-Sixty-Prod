#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]

# -----------------------------------------------------------------------------
# Active Crossover: expose the already-landed Playback-System-owned per-driver
# processing model. All mutations terminate in ProductProfileController's
# transactional replace path and are disabled while processing is active.
# -----------------------------------------------------------------------------
ui_path = root / "NotchSixty" / "UI" / "ProductionRootView.swift"
ui = ui_path.read_text(encoding="utf-8")
body_anchor = "                physicalRoutingCard\n                verificationCard\n"
if "driverProcessingCard\n                verificationCard" not in ui:
    if body_anchor not in ui:
        raise SystemExit("Active Crossover card insertion anchor not found")
    ui = ui.replace(
        body_anchor,
        "                physicalRoutingCard\n                driverProcessingCard\n                verificationCard\n",
        1,
    )

card_marker = "    private var driverProcessingCard: some View {"
if card_marker not in ui:
    insert_anchor = "    private var verificationCard: some View {"
    if insert_anchor not in ui:
        raise SystemExit("Active Crossover verification card anchor not found")
    card = r'''    private var driverProcessingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Per-Driver Processing").font(.headline)
                    Text("Playback-System-owned EQ, trim, polarity, fractional delay, and protection. Mandatory crossover filtering always runs first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if physicalRoutingLocked {
                    Label("Stop processing to edit", systemImage: "stop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            let buses = routedDriverBuses
            if buses.isEmpty {
                Text("Enable and map physical speaker routes to expose per-driver controls.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(buses, id: \.self) { bus in
                    driverBusEditor(bus)
                }
            }

            Text("These controls are downstream of the mandatory Mains+Sub / Bi-Amp / Tri-Amp splitter. Global Bypass, audition modes, and driver-processing bypass cannot restore full-range signal to a protected split-driver bus.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var routedDriverBuses: [SpeakerOutputBus] {
        let routed = Set(routing.routes.filter(\.enabled).map(\.bus))
        return SpeakerOutputBus.allCases.filter { routed.contains($0) }
    }

    @ViewBuilder
    private func driverBusEditor(_ bus: SpeakerOutputBus) -> some View {
        let configuration = engine.speakerDriverProcessingConfiguration.configuration(for: bus)
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    Toggle("Processing", isOn: Binding(
                        get: { driverConfiguration(for: bus).enabled },
                        set: { value in updateDriverBus(bus) { $0.enabled = value } }
                    ))
                    .toggleStyle(.switch)

                    Toggle("Invert Polarity", isOn: Binding(
                        get: { driverConfiguration(for: bus).polarityInverted },
                        set: { value in updateDriverBus(bus) { $0.polarityInverted = value } }
                    ))
                    .toggleStyle(.switch)

                    Toggle("Limiter", isOn: Binding(
                        get: { driverConfiguration(for: bus).limiterEnabled },
                        set: { value in updateDriverBus(bus) { $0.limiterEnabled = value } }
                    ))
                    .toggleStyle(.switch)
                }

                LabeledContent("Trim") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { driverConfiguration(for: bus).trimDB },
                                set: { value in updateDriverBus(bus) { $0.trimDB = value } }
                            ),
                            in: SpeakerDriverBusProcessingConfiguration.trimRange,
                            step: 0.1
                        )
                        Text("\(configuration.trimDB, specifier: "%.1f") dB")
                            .monospacedDigit()
                            .frame(width: 66, alignment: .trailing)
                    }
                }

                LabeledContent("Delay") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { driverConfiguration(for: bus).delayMilliseconds },
                                set: { value in updateDriverBus(bus) { $0.delayMilliseconds = value } }
                            ),
                            in: SpeakerDriverBusProcessingConfiguration.delayRangeMilliseconds,
                            step: 0.01
                        )
                        Text("\(configuration.delayMilliseconds, specifier: "%.2f") ms")
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                }

                if configuration.limiterEnabled {
                    LabeledContent("Limiter Threshold") {
                        HStack(spacing: 10) {
                            Slider(
                                value: Binding(
                                    get: { driverConfiguration(for: bus).limiterThresholdDBFS },
                                    set: { value in updateDriverBus(bus) { $0.limiterThresholdDBFS = value } }
                                ),
                                in: SpeakerDriverBusProcessingConfiguration.limiterThresholdRange,
                                step: 0.5
                            )
                            Text("\(configuration.limiterThresholdDBFS, specifier: "%.1f") dBFS")
                                .monospacedDigit()
                                .frame(width: 78, alignment: .trailing)
                        }
                    }
                }

                Divider()
                HStack {
                    Text("Driver EQ").font(.subheadline.weight(.semibold))
                    Text("\(configuration.eqBands.count)/\(SpeakerDriverBusProcessingConfiguration.maximumEQBandCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addDriverEQBand(to: bus)
                    } label: {
                        Label("Add Band", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    .disabled(configuration.eqBands.count >= SpeakerDriverBusProcessingConfiguration.maximumEQBandCount)
                }

                ForEach(Array(configuration.eqBands.enumerated()), id: \.element.id) { index, band in
                    driverEQBandEditor(bus: bus, index: index, band: band)
                }
            }
            .padding(.top, 10)
            .disabled(physicalRoutingLocked)
        } label: {
            HStack {
                Label(bus.displayName, systemImage: "hifispeaker.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                let active = configuration.enabled && !configuration.isNeutral
                Text(active ? "Configured" : "Neutral")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func driverEQBandEditor(bus: SpeakerOutputBus, index: Int, band: EQBand) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Band \(index + 1)", isOn: Binding(
                    get: { driverBand(bus: bus, index: index)?.enabled ?? false },
                    set: { value in updateDriverBand(bus: bus, index: index) { $0.enabled = value } }
                ))
                .toggleStyle(.switch)

                Picker("Type", selection: Binding(
                    get: { driverBand(bus: bus, index: index)?.type ?? .peaking },
                    set: { value in updateDriverBand(bus: bus, index: index) { band in
                        band.type = value
                        band.slope = .db12
                        band.constantQ = false
                        band.firKernel = nil
                    } }
                )) {
                    Text(EQFilterType.peaking.displayName).tag(EQFilterType.peaking)
                    Text(EQFilterType.lowShelf.displayName).tag(EQFilterType.lowShelf)
                    Text(EQFilterType.highShelf.displayName).tag(EQFilterType.highShelf)
                    Text(EQFilterType.notch.displayName).tag(EQFilterType.notch)
                    Text(EQFilterType.allPass.displayName).tag(EQFilterType.allPass)
                }
                .labelsHidden()
                .frame(width: 150)

                Spacer()
                Button(role: .destructive) {
                    removeDriverEQBand(from: bus, index: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Remove driver EQ band")
            }

            LabeledContent("Frequency") {
                HStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { driverBand(bus: bus, index: index)?.frequencyHz ?? 1_000 },
                            set: { value in updateDriverBand(bus: bus, index: index) { $0.frequencyHz = value } }
                        ),
                        in: 20 ... 20_000
                    )
                    Text("\(band.frequencyHz, specifier: "%.0f") Hz")
                        .monospacedDigit()
                        .frame(width: 76, alignment: .trailing)
                }
            }

            if band.type != .notch && band.type != .allPass {
                LabeledContent("Gain") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { driverBand(bus: bus, index: index)?.gainDB ?? 0 },
                                set: { value in updateDriverBand(bus: bus, index: index) { $0.gainDB = value } }
                            ),
                            in: -12 ... 12,
                            step: 0.1
                        )
                        Text("\(band.gainDB, specifier: "%.1f") dB")
                            .monospacedDigit()
                            .frame(width: 66, alignment: .trailing)
                    }
                }
            }

            LabeledContent("Q") {
                HStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { driverBand(bus: bus, index: index)?.q ?? 0.707 },
                            set: { value in updateDriverBand(bus: bus, index: index) { $0.q = value } }
                        ),
                        in: 0.35 ... 10,
                        step: 0.01
                    )
                    Text("\(band.q, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 54, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
    }

    private func driverConfiguration(for bus: SpeakerOutputBus) -> SpeakerDriverBusProcessingConfiguration {
        engine.speakerDriverProcessingConfiguration.configuration(for: bus)
    }

    private func driverBand(bus: SpeakerOutputBus, index: Int) -> EQBand? {
        let bands = driverConfiguration(for: bus).eqBands
        guard bands.indices.contains(index) else { return nil }
        return bands[index]
    }

    private func updateDriverBus(
        _ bus: SpeakerOutputBus,
        mutate: (inout SpeakerDriverBusProcessingConfiguration) -> Void
    ) {
        guard !physicalRoutingLocked else { return }
        var all = engine.speakerDriverProcessingConfiguration
        var busConfiguration = all.configuration(for: bus)
        mutate(&busConfiguration)
        all.replace(busConfiguration)
        do {
            try profiles.replaceSelectedSystemSpeakerDriverProcessing(all)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func addDriverEQBand(to bus: SpeakerOutputBus) {
        updateDriverBus(bus) { configuration in
            guard configuration.eqBands.count < SpeakerDriverBusProcessingConfiguration.maximumEQBandCount else { return }
            let initialFrequency: Double
            switch bus {
            case .subLeft, .subRight: initialFrequency = 60
            case .lowLeft, .lowRight: initialFrequency = 120
            case .midLeft, .midRight: initialFrequency = 1_000
            case .highLeft, .highRight: initialFrequency = 5_000
            case .fullRangeLeft, .fullRangeRight: initialFrequency = 1_000
            }
            configuration.eqBands.append(
                EQBand(type: .peaking, frequencyHz: initialFrequency, gainDB: 0, q: 0.707)
            )
        }
    }

    private func removeDriverEQBand(from bus: SpeakerOutputBus, index: Int) {
        updateDriverBus(bus) { configuration in
            guard configuration.eqBands.indices.contains(index) else { return }
            configuration.eqBands.remove(at: index)
        }
    }

    private func updateDriverBand(
        bus: SpeakerOutputBus,
        index: Int,
        mutate: (inout EQBand) -> Void
    ) {
        updateDriverBus(bus) { configuration in
            guard configuration.eqBands.indices.contains(index) else { return }
            mutate(&configuration.eqBands[index])
        }
    }

'''
    ui = ui.replace(insert_anchor, card + insert_anchor, 1)
ui_path.write_text(ui, encoding="utf-8")

# -----------------------------------------------------------------------------
# PR43 closure ledger. Measurement-dependent automation remains explicitly
# deferred until calibration can capture isolated logical buses / processed path.
# -----------------------------------------------------------------------------
closure_path = root / "docs" / "PR43_CLOSURE.md"
closure_path.write_text(r'''# PR43 — Advanced Acoustic & Speaker Optimization Closure

Status: **SOFTWARE IMPLEMENTATION CLOSURE — REAL-MAC ACOUSTIC ACCEPTANCE PENDING**

PR43 remains stacked on PR42 and preserves the 1.0 speaker-focused product boundary. Headphone-specific workflows and semantic surround/multichannel expansion remain deliberately deferred until after 1.0.

## Shipped in PR43

### Advanced measurement diagnostics

- Impulse Response, aligned to measured direct arrival.
- Step Response.
- Energy Time Curve (ETC).
- reverse-integrated Energy Decay Curve (EDC).
- Group Delay derived from the measured unwrapped transfer-function phase.
- analysis is offline/demand-gated and adds no realtime callback work.

### Per-driver speaker processing

Playback-System-owned processing on the PR41 logical speaker buses:

- bounded per-driver PEQ/shelf/notch/all-pass EQ;
- trim/gain;
- polarity inversion;
- broadband + fractional delay;
- optional per-driver limiter/protection;
- production Active Crossover editor with progressive disclosure;
- version-safe persistence in Playback System Profiles;
- immutable control-plane compilation and fixed-size realtime runtime.

The mandatory crossover/speaker-bus splitter always executes before optional driver processing, so Global Bypass or driver-processing bypass cannot restore unsafe full-range signal to a protected split-driver bus.

### Existing Room Correction foundation retained

The PR40 bounded minimum-phase FIR designer remains the authoritative automatic correction path in this PR43 close. PR43's advanced diagnostics make the retained raw measurement assets substantially more inspectable without changing daily DSP unexpectedly.

## Explicitly removed from PR43 before closure

The kickoff scope intentionally listed several measurement-assisted optimizers as candidates. They are **not shipped or claimed** in PR43 because the current calibration transport does not yet collect the evidence needed to support them safely and honestly.

The current measurement session captures sequential whole-system Left and Right sweeps while ordinary DSP playback is idle. It does **not** currently provide:

- isolated Low/Mid/High/Sub logical-bus acoustic captures;
- repeatability/coherence statistics across controlled repeated sweeps;
- a measurement path through a candidate/deployed per-driver processing graph;
- processed-vs-baseline verification under identical routing conditions.

Therefore the following are deferred to a dedicated post-1.0 measurement/optimization milestone rather than implemented with guessed or geometry-only evidence:

- automatic driver arrival-time/acoustic-center alignment;
- automatic polarity/phase diagnosis;
- measured individual-driver vs combined-system summation;
- automatic crossover-frequency optimization;
- automatic per-driver EQ optimization;
- baffle-step and diaphragm-resonance recommendation assistants;
- automatic processed-path repeat-measurement verification;
- automatic measurement-derived excess-phase inversion.

A future optimizer must first add a driver-safe isolated-bus/processed-path calibration transport and a confidence model based on repeatability, SNR, timing stability, and appropriate coherence/consistency evidence. Recommendations must remain advisory, complete-state, reversible, and explicitly applied.

## Also deferred

- per-driver realtime meter UI: the PR43 driver runtime is deliberately bounded and safe, but adding independent bus telemetry requires a separately demand-gated bridge/transport design so it does not impose unconditional realtime work;
- richer portable CamillaDSP physical speaker-matrix export: PR42's deterministic Content-EQ/FIR export remains available. A speaker-system exporter should follow only when its logical-bus/crossover semantics can be represented faithfully without implying that private Core Audio Aggregate Device identities are portable;
- fixed-bit-depth export/dither: still depends on a future app-owned file/export boundary.

## Product boundary

PR43 does not add headphone switching, AutoEQ/headphone target workflows, headphone crossfeed/HRTF/spatialization, surround/home-theater semantic channel layouts, Atmos/object audio, or arbitrary multichannel mixing. PR41's 2–8 physical outputs remain speaker-integration buses for Mains+Sub, Bi-Amp, and Tri-Amp systems.

## Acceptance before merge

Software closure still requires exact-head validators, Debug/Release builds, XCTest, realtime benchmarks, sandbox validation, and DMG packaging. Keep PR43 draft until a real Mac safely verifies:

- ordinary stereo and Mains+Sub playback;
- any available Bi-Amp/Tri-Amp topology only with safely connected hardware;
- per-driver EQ/trim/polarity/delay/limiter edits while idle and persistence after relaunch;
- mandatory crossover safety under Global Bypass and driver-processing neutral/bypass state;
- no channel swaps, clicks, level jumps, unexpected latency, or instability;
- advanced acoustic diagnostic presentation against a real microphone measurement.

The expected stacked merge order remains PR40 -> PR41 -> PR42 -> PR43 after the combined acceptance pass.
''', encoding="utf-8")

# -----------------------------------------------------------------------------
# Permanent structural guard for the production-facing closure.
# -----------------------------------------------------------------------------
guard_path = root / "ci" / "validate_pr43_closure.py"
guard_path.write_text(r'''#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
root_view = (root / "NotchSixty/UI/ProductionRootView.swift").read_text(encoding="utf-8")
route = (root / "NotchSixty/Audio/Routing/AudioRouteConfiguration.swift").read_text(encoding="utf-8")
bridge = (root / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c").read_text(encoding="utf-8")
diagnostics = (root / "NotchSixty/Audio/RoomCorrectionMeasurementAnalyzer.swift").read_text(encoding="utf-8")
workspace = (root / "NotchSixty/UI/ProductionRoomCorrectionWorkspace.swift").read_text(encoding="utf-8")
closure = (root / "docs/PR43_CLOSURE.md").read_text(encoding="utf-8")

def require(value, message):
    if not value:
        raise SystemExit(message)

for token in [
    "Per-Driver Processing",
    "driverBusEditor",
    "replaceSelectedSystemSpeakerDriverProcessing",
    "Limiter Threshold",
    "Driver EQ",
]:
    require(token in root_view, f"missing production per-driver UI contract: {token}")

for token in [
    "SpeakerDriverBusProcessingConfiguration",
    "maximumEQBandCount = 8",
    "delayRangeMilliseconds = 0.0 ... 50.0",
    "supportedEQTypes",
]:
    require(token in route, f"missing bounded driver model contract: {token}")

require(
    bridge.find("process_speaker_bus_splitter") < bridge.find("N60SpeakerDriverProcessingRuntimeProcessValues"),
    "driver processing must remain downstream of mandatory speaker-bus splitting",
)

for token in [
    "RoomCorrectionAcousticDiagnosticsAnalyzer",
    "energyDecayDB",
    "groupDelayMilliseconds",
]:
    require(token in diagnostics, f"missing advanced acoustic diagnostics: {token}")
require("RoomCorrectionAcousticDiagnosticsPanel" in workspace, "advanced diagnostics must be reachable in production UI")

for token in [
    "isolated Low/Mid/High/Sub logical-bus acoustic captures",
    "automatic crossover-frequency optimization",
    "automatic measurement-derived excess-phase inversion",
    "Headphone-specific workflows",
    "REAL-MAC ACOUSTIC ACCEPTANCE PENDING",
]:
    require(token in closure, f"PR43 closure must document measurement/product boundary: {token}")

require("does **not** currently provide" in closure, "measurement limitation must be explicit")
print("PR43 closure surface validation passed")
''', encoding="utf-8")

print("PR43 production surface/closure patch applied")
