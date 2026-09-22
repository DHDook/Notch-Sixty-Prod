import AppKit
import Combine
import Foundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var engine: AudioIOEngine

    private var selectedUIDBinding: Binding<String?> {
        Binding(
            get: { engine.routeConfiguration.selectedOutputUID },
            set: { newValue in
                do {
                    try engine.selectOutput(uid: newValue)
                } catch {
                    // The engine publishes the user-facing error description.
                }
            }
        )
    }

    private var eqBypassBinding: Binding<Bool> {
        Binding(
            get: { engine.eqConfiguration.bypassed },
            set: { try? engine.setEQBypassed($0) }
        )
    }

    private var inputPreampBinding: Binding<Double> {
        Binding(
            get: { engine.gainConfiguration.inputPreampDB },
            set: { try? engine.setInputPreampDB($0) }
        )
    }

    private var headroomBinding: Binding<Double> {
        Binding(
            get: { engine.gainConfiguration.headroomAttenuationDB },
            set: { try? engine.setHeadroomAttenuationDB($0) }
        )
    }

    private var outputGainBinding: Binding<Double> {
        Binding(
            get: { engine.gainConfiguration.outputGainDB },
            set: { try? engine.setOutputGainDB($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notch Sixty")
                .font(.title.bold())

            Text("Production transport + EQ + gain/headroom validation")
                .foregroundStyle(.secondary)

            Picker("Output", selection: selectedUIDBinding) {
                Text("Choose an output…")
                    .tag(Optional<String>.none)
                ForEach(engine.outputDevices) { device in
                    Text("\(device.name) — \(formattedRate(device.nominalSampleRate))")
                        .tag(Optional(device.uid))
                }
            }
            .disabled(engine.lifecycleState != .idle)

            HStack {
                Button("Refresh Devices") {
                    _ = try? engine.refreshOutputDevices()
                }
                .disabled(engine.lifecycleState != .idle)

                if engine.lifecycleState == .idle {
                    Button("Start Processing") {
                        try? engine.start()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(engine.selectedOutputDevice == nil)
                } else {
                    Button("Stop Processing") {
                        engine.stop()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }

            gainValidationView
            eqValidationView

            Divider()

            ScrollView {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    diagnosticsView(engine.diagnosticsSnapshot())
                }
            }

            if let error = engine.lastErrorDescription {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 860)
        .onAppear {
            engine.prepareForUse()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            engine.shutdownForTermination()
        }
    }

    @ViewBuilder
    private var gainValidationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gain / headroom validation")
                .font(.headline)

            gainControlRow(
                label: "Input preamp",
                value: inputPreampBinding,
                range: DSPGainConfiguration.inputPreampRange
            )
            gainControlRow(
                label: "Headroom attenuation",
                value: headroomBinding,
                range: DSPGainConfiguration.headroomAttenuationRange
            )
            gainControlRow(
                label: "Output gain",
                value: outputGainBinding,
                range: DSPGainConfiguration.outputGainRange
            )

            Text("Headroom attenuation is a separate internal stage reserved for future automatic compensation; PR #15 does not change it automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func gainControlRow(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 155, alignment: .leading)
            Slider(value: value, in: range, step: 0.5)
                .frame(minWidth: 280)
            TextField("dB", value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Text("dB")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var eqValidationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Parametric EQ validation")
                    .font(.headline)
                Text("\(engine.eqConfiguration.enabledBandCount) active / \(engine.eqConfiguration.bands.count) configured / \(EQConfiguration.maximumBandCount) max")
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Bypass EQ", isOn: eqBypassBinding)
                    .toggleStyle(.switch)
                Button("Add Band") {
                    try? engine.addEQBand()
                }
                .disabled(engine.eqConfiguration.bands.count >= EQConfiguration.maximumBandCount)
                Button("Load 64-Band Stress") {
                    load64BandStressConfiguration()
                }
            }

            if engine.eqConfiguration.bands.isEmpty {
                Text("No EQ bands configured. Add a band to validate live graph publication.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(engine.eqConfiguration.bands.enumerated()), id: \.element.id) { index, band in
                            eqBandRow(index: index, band: band)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func eqBandRow(index: Int, band: EQBand) -> some View {
        let binding = eqBandBinding(for: band.id)
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .frame(width: 24, alignment: .trailing)
                .foregroundStyle(.secondary)

            Toggle("", isOn: binding.enabled)
                .labelsHidden()

            Picker("", selection: binding.type) {
                ForEach(EQFilterType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 115)

            TextField("Hz", value: binding.frequencyHz, format: .number.precision(.fractionLength(0...1)))
                .frame(width: 85)
            Text("Hz").foregroundStyle(.secondary)

            TextField("dB", value: binding.gainDB, format: .number.precision(.fractionLength(1)))
                .frame(width: 65)
            Text("dB").foregroundStyle(.secondary)

            TextField("Q", value: binding.q, format: .number.precision(.fractionLength(2...3)))
                .frame(width: 65)
            Text("Q").foregroundStyle(.secondary)

            Spacer()
            Button("Remove") {
                try? engine.removeEQBand(id: band.id)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func eqBandBinding(for id: UUID) -> Binding<EQBand> {
        Binding(
            get: {
                engine.eqConfiguration.bands.first(where: { $0.id == id }) ?? EQBand(id: id, enabled: false)
            },
            set: { updated in
                try? engine.updateEQBand(updated)
            }
        )
    }

    private func load64BandStressConfiguration() {
        let count = EQConfiguration.maximumBandCount
        let minimumFrequency = 30.0
        let maximumFrequency = 18_000.0
        let ratio = maximumFrequency / minimumFrequency
        let bands = (0..<count).map { index -> EQBand in
            let position = count > 1 ? Double(index) / Double(count - 1) : 0
            let frequency = minimumFrequency * pow(ratio, position)
            return EQBand(
                enabled: true,
                type: .peaking,
                frequencyHz: frequency,
                gainDB: index.isMultiple(of: 2) ? 0.25 : -0.25,
                q: 1.0
            )
        }
        try? engine.replaceEQConfiguration(EQConfiguration(bypassed: false, bands: bands))
    }

    @ViewBuilder
    private func diagnosticsView(_ snapshot: AudioDiagnosticsSnapshot) -> some View {
        let session = snapshot.sessionTransportCounters
        let lifetime = snapshot.lifetimeTransportCounters

        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            diagnosticRow("State", snapshot.lifecycleState.rawValue)
            diagnosticRow("Selected output", snapshot.selectedOutputName ?? "—")
            diagnosticRow("Tap rate", snapshot.tapSampleRate.map(formattedRate) ?? "—")
            diagnosticRow("Output rate", snapshot.outputSampleRate.map(formattedRate) ?? "—")

            if let gateOpened = snapshot.startupGateOpened,
               let targetFrames = snapshot.startupGateTargetFrames,
               let activationFrames = snapshot.startupGateActivationFrames {
                diagnosticRow(
                    "Startup gate",
                    "\(gateOpened ? "open" : "armed") / target \(targetFrames) / activate \(activationFrames)"
                )
            }

            if let render = snapshot.renderKernelDiagnostics {
                diagnosticRow("DSP graph", "generation \(render.publishedGeneration) / \(render.bypassed ? "bypassed" : "active")")
                diagnosticRow("DSP rate", formattedRate(render.sampleRate))
                diagnosticRow("DSP latency", formattedDSPTime(frames: render.latencyFrames, sampleRate: render.sampleRate))
                diagnosticRow("Input preamp", formattedGain(render.inputGainLinear))
                diagnosticRow("Headroom stage", formattedGain(render.headroomGainLinear))
                diagnosticRow("Output gain", formattedGain(render.outputGainLinear))
                diagnosticRow("EQ stage", "\(render.eqBypassed ? "bypassed" : "active") / \(render.eqBandCount) rendered bands")
                meterRow("Input meter", render.inputMeter)
                meterRow("Post-EQ meter", render.postEQMeter)
                meterRow("DSP output meter", render.outputMeter)
                diagnosticRow("DSP rendered frames", "\(render.renderedFrames)")
                diagnosticRow("DSP non-finite sanitized", "\(render.sanitizedNonFiniteSamples)")
                diagnosticRow("DSP denormals flushed", "\(render.flushedDenormalSamples)")
                diagnosticRow("DSP snapshot read misses", "\(render.snapshotReadMisses)")
            }

            diagnosticRow("Counter scope", "current processing session")
            diagnosticRow("Capture callbacks", "\(session.captureCallbacks)")
            diagnosticRow("Output callbacks", "\(session.outputCallbacks)")
            diagnosticRow("Gated output callbacks", "\(session.gatedOutputCallbacks)")
            diagnosticRow("Gated output frames", "\(session.gatedOutputFrames)")
            diagnosticRow("Captured frames", "\(session.capturedFrames)")
            diagnosticRow("Delivered frames", "\(session.deliveredFrames)")
            diagnosticRow("Underrun frames", "\(session.underrunFrames)")
            diagnosticRow("Overrun frames", "\(session.overrunFrames)")
            diagnosticRow("Buffered frames", "\(session.bufferedFrames)")
            diagnosticRow("Bridge queue", formattedBridgeQueue(frames: session.bufferedFrames, sampleRate: snapshot.outputSampleRate))
            diagnosticRow("Lifetime underruns", "\(lifetime.underrunFrames)")
            diagnosticRow("Lifetime overruns", "\(lifetime.overrunFrames)")
            diagnosticRow("Rate rebuilds", "\(snapshot.sampleRateChangesHandled)")
            diagnosticRow(
                "Recovery",
                "\(snapshot.recoverySuccesses) success / \(snapshot.recoveryFailures) retry errors / \(snapshot.recoveryAttempts) attempts"
            )
        }
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }

    @ViewBuilder
    private func meterRow(_ label: String, _ meter: StereoMeterReading) -> some View {
        diagnosticRow(
            label,
            "peak L \(formattedLevel(meter.peakLeft)) / R \(formattedLevel(meter.peakRight)) | RMS L \(formattedLevel(meter.rmsLeft)) / R \(formattedLevel(meter.rmsRight)) | over-range \(meter.overRangeSamples)"
        )
    }

    private func formattedRate(_ rate: Double) -> String {
        if rate >= 1_000 {
            return String(format: "%.1f kHz", rate / 1_000)
        }
        return String(format: "%.0f Hz", rate)
    }

    private func formattedBridgeQueue(frames: UInt32, sampleRate: Double?) -> String {
        guard let sampleRate, sampleRate > 0 else { return "\(frames) frames" }
        let milliseconds = Double(frames) / sampleRate * 1_000.0
        return String(format: "%u frames / %.2f ms", frames, milliseconds)
    }

    private func formattedDSPTime(frames: UInt32, sampleRate: Double) -> String {
        guard sampleRate > 0 else { return "\(frames) frames" }
        let milliseconds = Double(frames) / sampleRate * 1_000.0
        return String(format: "%u frames / %.3f ms", frames, milliseconds)
    }

    private func formattedGain(_ linear: Float) -> String {
        guard linear > 0 else { return "−∞ dB" }
        return String(format: "%+.2f dB", 20.0 * log10(Double(linear)))
    }

    private func formattedLevel(_ linear: Float) -> String {
        guard linear > 0 else { return "−∞ dBFS" }
        return String(format: "%.1f dBFS", 20.0 * log10(Double(linear)))
    }
}
