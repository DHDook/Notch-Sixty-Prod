import SwiftUI

struct ProductionSpectrumView: View {
    let snapshot: ProductionAnalysisSnapshot
    let isRunning: Bool
    let resetPeakHold: () -> Void

    @State private var showInput = true
    @State private var showOutput = true
    @State private var showPeakHold = true

    private let frequencyMarks: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]
    private let levelMarks: [Float] = [0, -20, -40, -60, -80]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input / Output Spectrum")
                        .font(.title2.bold())
                    Text("96 logarithmic display bands · −80…0 dBFS · off-callback analysis")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset Hold", systemImage: "arrow.counterclockwise") {
                    resetPeakHold()
                }
                .disabled(!isRunning || snapshot.spectrum.isEmpty)
            }

            HStack(spacing: 18) {
                Toggle("Input", isOn: $showInput)
                Toggle("Output", isOn: $showOutput)
                Toggle("Peak Hold", isOn: $showPeakHold)
            }
            .toggleStyle(.switch)

            if !isRunning {
                analysisStatusBanner(
                    "Start processing to view the spectrum. Capture, FFT, and display updates are parked while processing is stopped."
                )
            } else if snapshot.spectrum.isEmpty {
                analysisStatusBanner("Spectrum capture is filling the analysis window…")
            }

            spectrumPlot
                .frame(minHeight: 360)
                .padding(14)
                .background(.quaternary.opacity(0.20), in: .rect(cornerRadius: 20))

            HStack(spacing: 20) {
                Label("Input", systemImage: "line.diagonal")
                    .foregroundStyle(.secondary)
                Label("Output", systemImage: "waveform")
                if showPeakHold {
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
                    if showPeakHold {
                        if showInput {
                            drawSpectrumTrace(
                                context: &context,
                                size: size,
                                value: { $0.inputPeakHoldDB },
                                opacity: 0.24,
                                lineWidth: 1,
                                dash: [4, 4]
                            )
                        }
                        if showOutput {
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
                    if showInput {
                        drawSpectrumTrace(
                            context: &context,
                            size: size,
                            value: { $0.inputDB },
                            opacity: 0.55,
                            lineWidth: 1.5,
                            dash: [6, 3]
                        )
                    }
                    if showOutput {
                        drawSpectrumTrace(
                            context: &context,
                            size: size,
                            value: { $0.outputDB },
                            opacity: 1,
                            lineWidth: 2.2,
                            dash: []
                        )
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
        guard let highest = snapshot.spectrum.last?.frequencyHz else { return frequencyMarks }
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
        guard !snapshot.spectrum.isEmpty else { return }
        var path = Path()
        for (index, band) in snapshot.spectrum.enumerated() {
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
        let maximumFrequency = max(snapshot.spectrum.last?.frequencyHz ?? 20_000, 21)
        let clamped = min(max(frequency, 20), maximumFrequency)
        let fraction = log10(clamped / 20) / log10(maximumFrequency / 20)
        return width * CGFloat(fraction)
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
                    let x = center.x + CGFloat(point.x) * scale
                    let y = center.y - CGFloat(point.y) * scale
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
