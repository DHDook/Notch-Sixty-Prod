import AppKit
import Combine
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Notch Sixty")
                .font(.title.bold())

            Text("Production transport validation")
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

            Divider()

            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                diagnosticsView(engine.diagnosticsSnapshot())
            }

            if let error = engine.lastErrorDescription {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 560)
        .onAppear {
            engine.prepareForUse()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            engine.shutdownForTermination()
        }
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
               let activationFrames = snapshot.startupGateActivationFrames,
               let waitMicroseconds = snapshot.startupGateWaitMicroseconds {
                diagnosticRow(
                    "Startup gate",
                    "\(gateOpened ? "open" : "timeout") / target \(targetFrames) / activate \(activationFrames) / \(formattedMicroseconds(waitMicroseconds))"
                )
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
                "\(snapshot.recoverySuccesses) success / \(snapshot.recoveryFailures) failed / \(snapshot.recoveryAttempts) attempts"
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

    private func formattedRate(_ rate: Double) -> String {
        if rate >= 1_000 {
            return String(format: "%.1f kHz", rate / 1_000)
        }
        return String(format: "%.0f Hz", rate)
    }

    private func formattedMicroseconds(_ microseconds: UInt32) -> String {
        if microseconds >= 1_000 {
            return String(format: "%.2f ms", Double(microseconds) / 1_000.0)
        }
        return "\(microseconds) µs"
    }

    private func formattedBridgeQueue(frames: UInt32, sampleRate: Double?) -> String {
        guard let sampleRate, sampleRate > 0 else { return "\(frames) frames" }
        let milliseconds = Double(frames) / sampleRate * 1_000.0
        return String(format: "%u frames / %.2f ms", frames, milliseconds)
    }
}
