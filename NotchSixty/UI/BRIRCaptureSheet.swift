import SwiftUI

/// E13 S7: the guided personal-BRIR capture, shown from the Headphones workspace behind `e13.headphones`.
struct BRIRCaptureSheet: View {
    @ObservedObject var flow: BRIRCaptureFlow
    @ObservedObject var microphone: RoomCorrectionCalibrationController
    let onSaved: (BinauralProfileReference) -> Void
    let onClose: () -> Void

    @State private var reviewIndex = 0

    private var channelOptions: [MeasurementSeat] {
        microphone.inputDevices.flatMap { device in
            (0..<max(device.inputChannelCount ?? 2, 1)).map { MeasurementSeat(device: device, channelIndex: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Capture your own BRIR").font(.title3.bold())
                Spacer()
                Text(flow.step.title).foregroundStyle(.secondary)
            }
            content
            if let problem = flow.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            footer
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 420)
        .onAppear { microphone.prepareForUse() }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .microphones: microphonesStep
        case .speakers: speakersStep
        case .positions: positionsStep
        case .compensation: compensationStep
        case .capture: captureStep
        case .review: reviewStep
        case .saved:
            Label("Saved \(flow.savedReference?.displayName ?? "profile") and selected it for this profile. Apply to use it.",
                  systemImage: "checkmark.circle.fill")
        }
    }

    private var microphonesStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Put a small in-ear microphone in each ear, both connected to one audio interface.")
                .foregroundStyle(.secondary)
            if microphone.permissionStatus != .authorized {
                Button("Allow microphone access") {
                    Task { await microphone.requestMicrophonePermission(); microphone.prepareForUse() }
                }
            } else if channelOptions.isEmpty {
                Text("No input devices found.").foregroundStyle(.secondary)
            } else {
                earPicker("Left ear", selection: $flow.leftEar)
                earPicker("Right ear", selection: $flow.rightEar)
            }
        }
    }

    private func earPicker(_ title: String, selection: Binding<MeasurementSeat?>) -> some View {
        Picker(title, selection: Binding<String?>(
            get: { selection.wrappedValue?.id },
            set: { id in selection.wrappedValue = channelOptions.first { $0.id == id } }
        )) {
            Text("Choose…").tag(String?.none)
            ForEach(channelOptions) { seat in Text(seat.name).tag(String?.some(seat.id)) }
        }
    }

    private var speakersStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which speakers should be captured? Each becomes a virtual speaker.").foregroundStyle(.secondary)
            ForEach(OutputProgramRole.allCases.filter { $0 != .lowFrequencyEffects }) { role in
                if flow.availableSpeakerRoles.contains(role) {
                    Toggle(role.displayName, isOn: Binding(
                        get: { flow.speakers.contains(role) },
                        set: { on in
                            if on { flow.speakers.append(role) } else { flow.speakers.removeAll { $0 == role } }
                        }))
                }
            }
            if flow.availableSpeakerRoles.isEmpty {
                Text("Describe your speakers in Speakers first.").foregroundStyle(.secondary)
            }
        }
    }

    private var positionsStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Head positions are captured by turning your head, so head tracking can pick the right response.")
                .foregroundStyle(.secondary)
            Picker("Head positions", selection: $flow.headPositions) {
                Text("1 (straight ahead)").tag(BRIRHeadPositions.one)
                Text("3 (recommended)").tag(BRIRHeadPositions.three)
                Text("5 (most complete)").tag(BRIRHeadPositions.five)
            }
            .pickerStyle(.segmented)
            Text("\(flow.speakers.count * flow.headPositions.rawValue) captures, about 10 seconds each.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var compensationStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Add headphone compensation", isOn: $flow.includeCompensation)
            Text("Measures your headphones with the microphones in your ears over \(BRIRCapturePlan.compensationReseatCount) reseats, so their own response is removed from the result. It plays quietly through the headphones. Do the speaker captures first, then select your headphones as the output.")
                .font(.callout).foregroundStyle(.secondary)
            if flow.includeCompensation {
                Toggle("My headphones are selected as the output and are on", isOn: $flow.headphonesConfirmed)
            }
        }
    }

    private var captureStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: flow.progress)
            Text(flow.prompt)
            if let quality = flow.lastQuality {
                Text("Last pass: \(quality.snrDB.isFinite ? "\(Int(quality.snrDB.rounded())) dB" : "clean") signal-to-noise, \(quality.clippedSamples) clipped samples")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if flow.isCapturing { ProgressView("Capturing…") }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $flow.displayName)
            if !flow.results.isEmpty {
                Picker("Show", selection: $reviewIndex) {
                    ForEach(flow.results.indices, id: \.self) { index in
                        let result = flow.results[index]
                        Text("\(result.role.displayName) at \(Int(result.headYawDegrees))°").tag(index)
                    }
                }
                BRIRPlot(result: flow.results[min(reviewIndex, flow.results.count - 1)])
                    .frame(height: 140)
            }
            Text("\(flow.results.count) responses\(flow.includeCompensation ? " with headphone compensation" : ""), \(flow.tapCount) taps at \(flow.sampleRate / 1000, specifier: "%.1f") kHz.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { flow.cancel(); onClose() }
            Spacer()
            switch flow.step {
            case .saved:
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            case .capture:
                Button("Back") { flow.back() }.disabled(flow.isCapturing)
                Button(flow.problem == nil ? "Capture" : "Capture again") { flow.startCapture() }
                    .disabled(flow.isCapturing).keyboardShortcut(.defaultAction)
            case .review:
                Button("Save and use") {
                    if let reference = flow.save() { onSaved(reference) }
                }
                .disabled(flow.blocker != nil).keyboardShortcut(.defaultAction)
            default:
                Button("Back") { flow.back() }.disabled(flow.step == .microphones)
                Button("Next") { flow.advance() }.disabled(flow.blocker != nil).keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The captured left (orange) and right (cyan) ear responses of one pass, in dB against time.
private struct BRIRPlot: View {
    let result: BRIRCaptureResult

    var body: some View {
        Canvas { context, size in
            for (ir, color) in [(result.leftIR, Color.orange), (result.rightIR, Color.cyan)] {
                guard ir.count > 1 else { continue }
                let peak = max(ir.reduce(0) { max($0, abs($1)) }, 1e-9)
                let columns = max(Int(size.width), 1)
                var path = Path()
                for column in 0..<columns {
                    let lo = column * ir.count / columns
                    let hi = max(lo + 1, (column + 1) * ir.count / columns)
                    let level = ir[lo..<min(hi, ir.count)].reduce(0) { max($0, abs($1)) } / peak
                    let db = max(20 * log10(Double(max(level, 1e-6))), -60)
                    let point = CGPoint(x: CGFloat(column), y: CGFloat(-db / 60) * size.height)
                    if column == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(color), lineWidth: 1.5)
            }
        }
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Left and right ear impulse response, level against time")
    }
}
