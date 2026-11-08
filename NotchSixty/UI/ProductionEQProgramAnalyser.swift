import SwiftUI

/// E27 S2b: the "Analyser" switch above the response graph. It drives the polling loop while the
/// page is on screen and hands the latest spectrum to the page through `spectrum`. Hidden when
/// `e27.eq-safety` is off (the controller is then inert).
struct EQProgramAnalyserSwitch: View {
    @ObservedObject var analyser: EQProgramAnalyserController
    @Binding var spectrum: EQProgramSpectrum

    var body: some View {
        if analyser.isAvailable {
            Toggle("Analyser", isOn: Binding(get: { analyser.isOn }, set: { analyser.setOn($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .help("Live program spectrum: grey is the input, blue the second curve chosen here")
                .task(id: analyser.isOn) { await analyser.run() }
                .onReceive(analyser.$spectrum) { spectrum = $0 }
            if analyser.isOn {
                Picker("Analyser source", selection: Binding(get: { analyser.mode }, set: { analyser.setMode($0) })) {
                    ForEach(EQAnalyserMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("eq.analyser.source")
                .help("EQ only: after the EQ. EQ + Dynamics: after the compressor and expander. Output: the whole chain")
            }
        }
    }
}

/// Draws the program spectrum behind the EQ curve. The vertical scale is its own (dBFS, floor at
/// the bottom of the graph), independent of the gain axis, as in other EQ analysers.
enum EQProgramSpectrumDrawing {
    static func draw(
        context: inout GraphicsContext, size: CGSize, spectrum: EQProgramSpectrum,
        xPosition: (Double) -> CGFloat, minimumFrequency: Double, maximumFrequency: Double
    ) {
        guard !spectrum.isEmpty, size.width > 0, size.height > 0 else { return }
        func path(_ values: [Double], closed: Bool) -> Path? {
            var path = Path()
            var first: CGPoint?
            var last: CGPoint?
            for (frequency, db) in zip(spectrum.frequenciesHz, values)
            where frequency >= minimumFrequency && frequency <= maximumFrequency {
                let y = size.height * (1 - CGFloat(EQProgramSpectrum.fraction(forDB: db)))
                let point = CGPoint(x: xPosition(frequency), y: y)
                if first == nil { first = point; path.move(to: point) } else { path.addLine(to: point) }
                last = point
            }
            guard let first, let last else { return nil }
            if closed {
                path.addLine(to: CGPoint(x: last.x, y: size.height))
                path.addLine(to: CGPoint(x: first.x, y: size.height))
                path.closeSubpath()
            }
            return path
        }
        if let fill = path(spectrum.inputDB, closed: true) {
            context.fill(fill, with: .color(.gray.opacity(0.22)))
        }
        if let line = path(spectrum.outputDB, closed: false) {
            context.stroke(line, with: .color(.cyan.opacity(0.75)), lineWidth: 1.25)
        }
        let legend: [(String, Color)] = [("Input", .gray), (spectrum.outputLabel, .cyan)]
        for (index, entry) in legend.enumerated() {
            context.draw(
                Text(entry.0).font(.caption2).foregroundStyle(entry.1),
                at: CGPoint(x: size.width - 8, y: 10 + CGFloat(index) * 13), anchor: .trailing)
        }
    }
}
