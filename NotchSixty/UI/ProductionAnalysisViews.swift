import SwiftUI

struct ProductionSpectrumView: View {
    let snapshot: ProductionAnalysisSnapshot
    let isRunning: Bool
    let resetPeakHold: () -> Void

    @State private var model = SpectrumDisplayModel()

    private let frequencyMarks: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]
    private let levelMarks: [Float] = [0, -20, -40, -60, -80]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input / Output Spectrum")
                        .font(.title2.bold())
                    Text("288 logarithmic display bands · −80…0 dBFS · off-callback analysis")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset Hold", systemImage: "arrow.counterclockwise") {
                    resetPeakHold()
                }
                .disabled(!isRunning || snapshot.spectrum.isEmpty)
            }

            HStack(spacing: 18) {
                Toggle("Input", isOn: $model.options.showInput)
                Toggle("Output", isOn: $model.options.showOutput)
                Toggle("Peak Hold", isOn: $model.options.showPeakHold)
            }
            .toggleStyle(.switch)

            spectrumOptionsBar
            spectrumHoverLine

            if !isRunning {
                analysisStatusBanner(
                    "Start processing to view the spectrum. Capture, FFT, and display updates are parked while processing is stopped."
                )
            } else if snapshot.spectrum.isEmpty && model.bands.isEmpty {
                analysisStatusBanner("Spectrum capture is filling the analysis window…")
            }

            spectrumPlot
                .frame(minHeight: 360)
                .padding(14)
                .background(.quaternary.opacity(0.20), in: .rect(cornerRadius: 20))
                .onChange(of: snapshot.spectrum) { _, bands in
                    model.ingest(bands, now: ProcessInfo.processInfo.systemUptime)
                }

            HStack(spacing: 20) {
                Label("Input", systemImage: "line.diagonal")
                    .foregroundStyle(.secondary)
                Label("Output", systemImage: "waveform")
                if model.reference != nil {
                    Label("Reference", systemImage: "minus")
                }
                if model.options.showPeakHold {
                    Label("Peak hold", systemImage: "ellipsis")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                analysisCaptureStatus
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Input is the established render-input signal location. Output is the final DSP output before the bridge startup/transition fade. Analyzer work runs only while this page is visible.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var spectrumPlot: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing) {
                    ForEach(levelMarks, id: \.self) { level in
                        Text("\(Int(level))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if level != levelMarks.last {
                            Spacer()
                        }
                    }
                }
                .frame(width: 34)

                Canvas { context, size in
                    drawSpectrumGrid(context: &context, size: size)
                    if model.options.showPeakHold {
                        if model.options.showInput {
                            drawSpectrumTrace(
                                context: &context,
                                size: size,
                                value: { $0.inputPeakHoldDB },
                                opacity: 0.24,
                                lineWidth: 1,
                                dash: [4, 4]
                            )
                        }
                        if model.options.showOutput {
                            drawSpectrumTrace(
                                context: &context,
                                size: size,
                                value: { $0.outputPeakHoldDB },
                                opacity: 0.42,
                                lineWidth: 1,
                                dash: [3, 3]
                            )
                        }
                    }
                    if model.options.showInput {
                        drawSpectrumTrace(
                            context: &context,
                            size: size,
                            value: { $0.inputDB },
                            opacity: 0.55,
                            lineWidth: 1.5,
                            dash: [6, 3]
                        )
                    }
                    if model.options.showOutput {
                        drawSpectrumTrace(
                            context: &context,
                            size: size,
                            value: { $0.outputDB },
                            opacity: 1,
                            lineWidth: 2.2,
                            dash: []
                        )
                    }
                    drawReferenceTrace(context: &context, size: size)
                    drawHoverMarker(context: &context, size: size)
                }
                .accessibilityIdentifier("meters.spectrum.plot")
                .accessibilityLabel("Spectrum plot")
                .accessibilityValue(spectrumAccessibilityValue)
                .overlay {
                    GeometryReader { proxy in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    model.hoverFraction = Double(min(max(location.x / max(proxy.size.width, 1), 0), 1))
                                case .ended:
                                    model.hoverFraction = nil
                                }
                            }
                    }
                }
            }

            HStack(spacing: 0) {
                Color.clear.frame(width: 42, height: 1)
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ForEach(visibleFrequencyMarks, id: \.self) { frequency in
                            Text(frequencyLabel(frequency))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .position(
                                    x: frequencyX(frequency, width: proxy.size.width),
                                    y: 8
                                )
                        }
                    }
                }
                .frame(height: 18)
            }
        }
    }

    private var visibleFrequencyMarks: [Double] {
        guard let highest = model.bands.last?.frequencyHz else { return frequencyMarks }
        return frequencyMarks.filter { $0 <= highest * 1.08 }
    }

    private func drawSpectrumGrid(context: inout GraphicsContext, size: CGSize) {
        for level in levelMarks {
            var path = Path()
            let y = levelY(level, height: size.height)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(.secondary.opacity(0.18)), lineWidth: 0.7)
        }
        for frequency in visibleFrequencyMarks {
            var path = Path()
            let x = frequencyX(frequency, width: size.width)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 0.6)
        }
    }

    private func drawSpectrumTrace(
        context: inout GraphicsContext,
        size: CGSize,
        value: (ProductionSpectrumBand) -> Float,
        opacity: Double,
        lineWidth: CGFloat,
        dash: [CGFloat]
    ) {
        guard !model.bands.isEmpty else { return }
        var path = Path()
        for (index, band) in model.bands.enumerated() {
            let point = CGPoint(
                x: frequencyX(band.frequencyHz, width: size.width),
                y: levelY(value(band), height: size.height)
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        context.stroke(
            path,
            with: .color(.primary.opacity(opacity)),
            style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round, dash: dash)
        )
    }

    private func frequencyX(_ frequency: Double, width: CGFloat) -> CGFloat {
        width * CGFloat(model.axis.fraction(frequency: frequency))
    }

    private func levelY(_ level: Float, height: CGFloat) -> CGFloat {
        let clamped = min(max(level, ProductionAnalysisMath.spectrumFloorDB), 0)
        let fraction = CGFloat((0 - clamped) / (0 - ProductionAnalysisMath.spectrumFloorDB))
        return height * fraction
    }

    private func frequencyLabel(_ frequency: Double) -> String {
        if frequency >= 1_000 {
            return String(format: "%.0fk", frequency / 1_000)
        }
        return "\(Int(frequency))"
    }

    private var spectrumOptionsBar: some View {
        HStack(spacing: 14) {
            Picker("Smoothing", selection: $model.options.smoothing) {
                ForEach(SpectrumSmoothing.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("meters.spectrum.smoothing")
            Picker("Averaging", selection: $model.options.averaging) {
                ForEach(SpectrumAveraging.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("meters.spectrum.averaging")
            Picker("Tilt", selection: $model.options.tilt) {
                ForEach(SpectrumTilt.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("meters.spectrum.tilt")
            Toggle("Freeze", isOn: Binding(get: { model.isFrozen }, set: { model.setFrozen($0) }))
                .toggleStyle(.button)
                .accessibilityIdentifier("meters.spectrum.freeze")
            Button("Set Reference") { model.captureReference() }
                .disabled(model.bands.isEmpty)
                .accessibilityIdentifier("meters.spectrum.setReference")
            Button("Clear Reference") { model.clearReference() }
                .disabled(model.reference == nil)
                .accessibilityIdentifier("meters.spectrum.clearReference")
            Spacer()
        }
        .pickerStyle(.menu)
        .controlSize(.small)
    }

    private var spectrumHoverLine: some View {
        Group {
            if let readout = model.hoverReadout {
                Text(SpectrumReadoutText.line(readout))
            } else {
                Text("Hover over the plot to read frequency and level.")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("meters.spectrum.hover")
    }

    private var spectrumAccessibilityValue: String {
        if model.isFrozen { return "Frozen" }
        guard let peak = model.bands.max(by: { $0.outputDB < $1.outputDB }) else { return "No data" }
        return "Output peak \(SpectrumReadoutText.level(peak.outputDB)) near \(SpectrumReadoutText.frequency(peak.frequencyHz))"
    }

    private func drawReferenceTrace(context: inout GraphicsContext, size: CGSize) {
        guard let reference = model.reference, reference.frequencies.count == reference.levelsDB.count,
              !reference.frequencies.isEmpty else { return }
        var path = Path()
        for index in reference.frequencies.indices {
            let point = CGPoint(
                x: frequencyX(reference.frequencies[index], width: size.width),
                y: levelY(reference.levelsDB[index], height: size.height)
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(
            path,
            with: .color(.accentColor.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1.4, lineJoin: .round, dash: [2, 3])
        )
    }

    private func drawHoverMarker(context: inout GraphicsContext, size: CGSize) {
        guard let readout = model.hoverReadout else { return }
        let x = frequencyX(readout.frequencyHz, width: size.width)
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(path, with: .color(.primary.opacity(0.45)), lineWidth: 0.8)
    }

    private var analysisCaptureStatus: some View {
        Group {
            if snapshot.droppedFrames > 0 {
                Text("Captured \(snapshot.capturedFrames) · Dropped \(snapshot.droppedFrames)")
            } else if snapshot.capturedFrames > 0 {
                Text("Captured \(snapshot.capturedFrames) · No drops")
            } else {
                Text("Analyzer parked")
            }
        }
        .monospacedDigit()
    }

    private func analysisStatusBanner(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.18), in: .rect(cornerRadius: 12))
    }
}

struct ProductionStereoAnalysisView: View {
    let snapshot: ProductionAnalysisSnapshot
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stereo Field")
                    .font(.title2.bold())
                Text("DSP Output · normalized phase correlation + bounded 45° goniometer history")
                    .foregroundStyle(.secondary)
            }

            if !isRunning {
                analysisStatusBanner(
                    "Start processing to view stereo analysis. Output capture and stereo analysis are parked while processing is stopped."
                )
            } else if snapshot.goniometer.isEmpty {
                analysisStatusBanner("Stereo capture is filling the analysis window…")
            }

            HStack(alignment: .top, spacing: 18) {
                phaseCorrelationCard
                    .frame(minWidth: 260, maxWidth: 330)
                goniometerCard
                    .frame(maxWidth: .infinity)
            }

            HStack {
                Text("Correlation uses approximately 100 ms of recent final DSP output. Silence is reported as undefined rather than assigned an arbitrary value.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                captureStatus
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var phaseCorrelationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Phase Correlation")
                .font(.headline)
            Text(snapshot.phaseCorrelationValid
                 ? String(format: "%+.2f", Double(snapshot.phaseCorrelation))
                 : "—")
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .monospacedDigit()

            GeometryReader { proxy in
                let usableWidth = max(proxy.size.width - 2, 1)
                let fraction = snapshot.phaseCorrelationValid
                    ? CGFloat((snapshot.phaseCorrelation + 1) * 0.5)
                    : 0.5
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Rectangle()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 1)
                        .offset(x: usableWidth * 0.5)
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2)
                        .offset(x: usableWidth * min(max(fraction, 0), 1))
                        .opacity(snapshot.phaseCorrelationValid ? 1 : 0.25)
                }
            }
            .frame(height: 12)

            HStack {
                Text("−1 Anti")
                Spacer()
                Text("0")
                Spacer()
                Text("+1 In Phase")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Divider()
            Text("+1 = in phase · 0 = uncorrelated · −1 = anti-phase")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.20), in: .rect(cornerRadius: 20))
    }

    private var goniometerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Goniometer")
                    .font(.headline)
                Spacer()
                Text("Recent output history")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Canvas { context, size in
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
                let scale = min(size.width, size.height) * 0.31

                var vertical = Path()
                vertical.move(to: CGPoint(x: center.x, y: 0))
                vertical.addLine(to: CGPoint(x: center.x, y: size.height))
                context.stroke(vertical, with: .color(.secondary.opacity(0.25)), lineWidth: 0.8)

                var horizontal = Path()
                horizontal.move(to: CGPoint(x: 0, y: center.y))
                horizontal.addLine(to: CGPoint(x: size.width, y: center.y))
                context.stroke(horizontal, with: .color(.secondary.opacity(0.18)), lineWidth: 0.8)

                var positiveDiagonal = Path()
                positiveDiagonal.move(to: CGPoint(x: 0, y: size.height))
                positiveDiagonal.addLine(to: CGPoint(x: size.width, y: 0))
                context.stroke(positiveDiagonal, with: .color(.secondary.opacity(0.10)), lineWidth: 0.6)

                var negativeDiagonal = Path()
                negativeDiagonal.move(to: CGPoint(x: 0, y: 0))
                negativeDiagonal.addLine(to: CGPoint(x: size.width, y: size.height))
                context.stroke(negativeDiagonal, with: .color(.secondary.opacity(0.10)), lineWidth: 0.6)

                for point in snapshot.goniometer {
                    let displayPoint = goniometerDisplayPoint(x: point.x, y: point.y)
                    let x = center.x + displayPoint.x * scale
                    let y = center.y - displayPoint.y * scale
                    let dot = Path(ellipseIn: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4))
                    context.fill(dot, with: .color(.primary.opacity(0.36)))
                }
            }
            .frame(minHeight: 330)

            HStack {
                Text("SIDE −")
                Spacer()
                Text("MONO +")
                Spacer()
                Text("SIDE +")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.20), in: .rect(cornerRadius: 20))
    }

    private func goniometerDisplayPoint(x: Float, y: Float) -> CGPoint {
        let rawX = Double(x)
        let rawY = Double(y)
        let radius = hypot(rawX, rawY)
        guard radius > 1.0e-9 else { return .zero }

        // Display-only radial shaping: expand quiet material without changing
        // the goniometer angle/stereo orientation or the full-scale boundary.
        let maximumRadius = sqrt(2.0)
        let normalizedRadius = min(max(radius / maximumRadius, 0), 1)
        let shapedRadius = log1p(9.0 * normalizedRadius) / log(10.0)
        let mappedRadius = shapedRadius * maximumRadius
        let gain = mappedRadius / radius
        return CGPoint(x: rawX * gain, y: rawY * gain)
    }

    private var captureStatus: some View {
        Group {
            if snapshot.droppedFrames > 0 {
                Text("Captured \(snapshot.capturedFrames) · Dropped \(snapshot.droppedFrames)")
            } else if snapshot.capturedFrames > 0 {
                Text("Captured \(snapshot.capturedFrames) · No drops")
            } else {
                Text("Analyzer parked")
            }
        }
    }

    private func analysisStatusBanner(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.18), in: .rect(cornerRadius: 12))
    }
}


/// Text for the spectrum read-out; plain functions so the tests can check them.
enum SpectrumReadoutText {
    static func frequency(_ hertz: Double) -> String {
        hertz >= 1_000 ? String(format: "%.2f kHz", hertz / 1_000) : String(format: "%.0f Hz", hertz)
    }

    static func level(_ db: Float) -> String {
        String(format: "%.1f dB", db)
    }

    static func line(_ readout: SpectrumHoverReadout) -> String {
        var text = "\(frequency(readout.frequencyHz))  Input \(level(readout.inputDB))  Output \(level(readout.outputDB))"
        if let reference = readout.referenceDB {
            text += "  Reference \(level(reference)) (Output \(String(format: "%+.1f", readout.outputDB - reference)) dB)"
        }
        return text
    }
}
