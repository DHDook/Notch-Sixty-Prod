#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]

analyzer_path = root / "NotchSixty" / "Audio" / "RoomCorrectionMeasurementAnalyzer.swift"
analyzer = analyzer_path.read_text(encoding="utf-8")
marker = "struct RoomCorrectionAcousticDiagnosticsAnalyzer: Sendable"
if marker not in analyzer:
    analyzer += r'''

// MARK: - PR43 advanced acoustic diagnostics

struct RoomCorrectionDiagnosticSeries: Equatable, Sendable {
    var x: [Double]
    var y: [Double]

    init(x: [Double], y: [Double]) {
        self.x = x
        self.y = y
    }
}

struct RoomCorrectionAcousticDiagnostics: Equatable, Sendable {
    var impulse: RoomCorrectionDiagnosticSeries
    var step: RoomCorrectionDiagnosticSeries
    var energyTimeCurveDB: RoomCorrectionDiagnosticSeries
    var energyDecayDB: RoomCorrectionDiagnosticSeries
    var groupDelayMilliseconds: RoomCorrectionDiagnosticSeries?
}

struct RoomCorrectionAcousticDiagnosticsPair: Equatable, Sendable {
    var left: RoomCorrectionAcousticDiagnostics
    var right: RoomCorrectionAcousticDiagnostics
}

enum RoomCorrectionAcousticDiagnosticsError: Error, Equatable, LocalizedError {
    case invalidSampleRate(Double)
    case emptyImpulse
    case nonFiniteImpulse
    case unusableImpulse
    case invalidTransferFunction

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let sampleRate):
            return "Acoustic diagnostics sample rate \(sampleRate) Hz is invalid."
        case .emptyImpulse:
            return "Acoustic diagnostics require a non-empty impulse response."
        case .nonFiniteImpulse:
            return "Acoustic diagnostics cannot analyze non-finite impulse samples."
        case .unusableImpulse:
            return "Acoustic diagnostics could not find usable impulse-response energy."
        case .invalidTransferFunction:
            return "Acoustic diagnostics require a finite, strictly increasing frequency grid with matching unwrapped phase data."
        }
    }
}

/// Offline-only derivation of advanced acoustic diagnostics from the PR40
/// measurement products. This analyzer never runs on the realtime audio path.
struct RoomCorrectionAcousticDiagnosticsAnalyzer: Sendable {
    static let displayFloorDB = -120.0
    static let energyTimeSmoothingSeconds = 0.001

    func analyze(
        _ analysis: RoomCorrectionMeasurementAnalysis
    ) throws -> RoomCorrectionAcousticDiagnosticsPair {
        RoomCorrectionAcousticDiagnosticsPair(
            left: try analyze(
                impulseResponse: analysis.left.impulseResponse,
                transferFunction: analysis.left.transferFunction,
                sampleRate: analysis.sampleRate,
                referenceArrivalSeconds: analysis.left.quality.directArrivalSeconds
            ),
            right: try analyze(
                impulseResponse: analysis.right.impulseResponse,
                transferFunction: analysis.right.transferFunction,
                sampleRate: analysis.sampleRate,
                referenceArrivalSeconds: analysis.right.quality.directArrivalSeconds
            )
        )
    }

    func analyze(
        impulseResponse: [Float],
        transferFunction: RoomCorrectionFrequencyResponse?,
        sampleRate: Double,
        referenceArrivalSeconds: Double? = nil
    ) throws -> RoomCorrectionAcousticDiagnostics {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw RoomCorrectionAcousticDiagnosticsError.invalidSampleRate(sampleRate)
        }
        guard !impulseResponse.isEmpty else {
            throw RoomCorrectionAcousticDiagnosticsError.emptyImpulse
        }
        guard impulseResponse.allSatisfy(\.isFinite) else {
            throw RoomCorrectionAcousticDiagnosticsError.nonFiniteImpulse
        }

        let impulse = impulseResponse.map(Double.init)
        let peak = impulse.reduce(0.0) { max($0, abs($1)) }
        let energy = impulse.map { $0 * $0 }
        let totalEnergy = energy.reduce(0, +)
        guard peak.isFinite, peak > 1.0e-12,
              totalEnergy.isFinite, totalEnergy > 1.0e-24 else {
            throw RoomCorrectionAcousticDiagnosticsError.unusableImpulse
        }

        let arrival = (referenceArrivalSeconds?.isFinite == true)
            ? max(referenceArrivalSeconds ?? 0, 0)
            : 0
        let timeMilliseconds = impulse.indices.map {
            (Double($0) / sampleRate - arrival) * 1_000.0
        }
        let normalizedImpulse = impulse.map { $0 / peak }

        var runningStep = 0.0
        var stepValues = [Double]()
        stepValues.reserveCapacity(impulse.count)
        for sample in impulse {
            runningStep += sample
            stepValues.append(runningStep)
        }
        let stepPeak = stepValues.reduce(0.0) { max($0, abs($1)) }
        if stepPeak > 1.0e-12 {
            for index in stepValues.indices {
                stepValues[index] /= stepPeak
            }
        }

        let smoothingFrames = max(
            1,
            Int((sampleRate * Self.energyTimeSmoothingSeconds).rounded())
        )
        var smoothedEnergy = [Double](repeating: 0, count: energy.count)
        var movingEnergy = 0.0
        for index in energy.indices {
            movingEnergy += energy[index]
            if index >= smoothingFrames {
                movingEnergy -= energy[index - smoothingFrames]
            }
            let activeFrames = min(index + 1, smoothingFrames)
            smoothedEnergy[index] = movingEnergy / Double(activeFrames)
        }
        let maximumSmoothedEnergy = smoothedEnergy.max() ?? 0
        guard maximumSmoothedEnergy.isFinite, maximumSmoothedEnergy > 1.0e-24 else {
            throw RoomCorrectionAcousticDiagnosticsError.unusableImpulse
        }
        let etc = smoothedEnergy.map {
            Self.decibels(powerRatio: $0 / maximumSmoothedEnergy)
        }

        var reverseEnergy = [Double](repeating: 0, count: energy.count)
        var accumulated = 0.0
        for index in energy.indices.reversed() {
            accumulated += energy[index]
            reverseEnergy[index] = accumulated
        }
        let edc = reverseEnergy.map {
            Self.decibels(powerRatio: $0 / totalEnergy)
        }

        return RoomCorrectionAcousticDiagnostics(
            impulse: RoomCorrectionDiagnosticSeries(
                x: timeMilliseconds,
                y: normalizedImpulse
            ),
            step: RoomCorrectionDiagnosticSeries(
                x: timeMilliseconds,
                y: stepValues
            ),
            energyTimeCurveDB: RoomCorrectionDiagnosticSeries(
                x: timeMilliseconds,
                y: etc
            ),
            energyDecayDB: RoomCorrectionDiagnosticSeries(
                x: timeMilliseconds,
                y: edc
            ),
            groupDelayMilliseconds: try makeGroupDelay(transferFunction)
        )
    }

    private func makeGroupDelay(
        _ response: RoomCorrectionFrequencyResponse?
    ) throws -> RoomCorrectionDiagnosticSeries? {
        guard let response else { return nil }
        guard let phase = response.phaseRadians else { return nil }
        let frequencies = response.frequenciesHz
        guard frequencies.count >= 2,
              phase.count == frequencies.count,
              frequencies.allSatisfy({ $0.isFinite && $0 > 0 }),
              phase.allSatisfy(\.isFinite) else {
            throw RoomCorrectionAcousticDiagnosticsError.invalidTransferFunction
        }
        for index in frequencies.indices.dropFirst() {
            guard frequencies[index] > frequencies[index - 1] else {
                throw RoomCorrectionAcousticDiagnosticsError.invalidTransferFunction
            }
        }

        var delay = [Double](repeating: 0, count: frequencies.count)
        for index in frequencies.indices {
            let lower = index == frequencies.startIndex ? index : index - 1
            let upper = index == frequencies.index(before: frequencies.endIndex) ? index : index + 1
            let deltaFrequency = frequencies[upper] - frequencies[lower]
            guard deltaFrequency.isFinite, deltaFrequency > 0 else {
                throw RoomCorrectionAcousticDiagnosticsError.invalidTransferFunction
            }
            let deltaPhase = phase[upper] - phase[lower]
            delay[index] = -deltaPhase / (2.0 * Double.pi * deltaFrequency) * 1_000.0
        }
        return RoomCorrectionDiagnosticSeries(x: frequencies, y: delay)
    }

    private static func decibels(powerRatio: Double) -> Double {
        guard powerRatio.isFinite, powerRatio > 0 else { return displayFloorDB }
        return max(displayFloorDB, 10.0 * log10(powerRatio))
    }
}
'''
    analyzer_path.write_text(analyzer, encoding="utf-8")

tests_path = root / "NotchSixtyTests" / "RoomCorrectionMeasurementAnalyzerTests.swift"
tests = tests_path.read_text(encoding="utf-8")
test_marker = "testPR43AcousticDiagnosticsDeriveStepDecayAndGroupDelay"
if test_marker not in tests:
    insertion = r'''

    func testPR43AcousticDiagnosticsDeriveStepDecayAndGroupDelay() throws {
        let sampleRate = 1_000.0
        let impulse: [Float] = [0, 1, 0.5, 0.25, 0, 0]
        let delaySeconds = 0.005
        let frequencies = [100.0, 200.0, 400.0, 800.0]
        let response = RoomCorrectionFrequencyResponse(
            frequenciesHz: frequencies,
            magnitudeDB: [0, 0, 0, 0],
            phaseRadians: frequencies.map { -2.0 * Double.pi * $0 * delaySeconds }
        )

        let diagnostics = try RoomCorrectionAcousticDiagnosticsAnalyzer().analyze(
            impulseResponse: impulse,
            transferFunction: response,
            sampleRate: sampleRate,
            referenceArrivalSeconds: 0.001
        )

        XCTAssertEqual(diagnostics.impulse.x[1], 0, accuracy: 1.0e-9)
        XCTAssertEqual(diagnostics.impulse.y[1], 1, accuracy: 1.0e-9)
        XCTAssertEqual(diagnostics.step.y.count, impulse.count)
        XCTAssertEqual(diagnostics.energyTimeCurveDB.y.max() ?? -999, 0, accuracy: 1.0e-9)
        XCTAssertEqual(diagnostics.energyDecayDB.y.first ?? -999, 0, accuracy: 1.0e-9)

        for index in diagnostics.energyDecayDB.y.indices.dropFirst() {
            XCTAssertLessThanOrEqual(
                diagnostics.energyDecayDB.y[index],
                diagnostics.energyDecayDB.y[index - 1] + 1.0e-12
            )
        }

        let groupDelay = try XCTUnwrap(diagnostics.groupDelayMilliseconds)
        XCTAssertEqual(groupDelay.x, frequencies)
        for value in groupDelay.y {
            XCTAssertEqual(value, 5.0, accuracy: 1.0e-9)
        }
    }

    func testPR43AcousticDiagnosticsFailClosedOnInvalidInputs() throws {
        let analyzer = RoomCorrectionAcousticDiagnosticsAnalyzer()
        XCTAssertThrowsError(
            try analyzer.analyze(
                impulseResponse: [1],
                transferFunction: nil,
                sampleRate: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionAcousticDiagnosticsError,
                .invalidSampleRate(0)
            )
        }

        let invalidResponse = RoomCorrectionFrequencyResponse(
            frequenciesHz: [100, 100],
            magnitudeDB: [0, 0],
            phaseRadians: [0, 0]
        )
        XCTAssertThrowsError(
            try analyzer.analyze(
                impulseResponse: [1, 0],
                transferFunction: invalidResponse,
                sampleRate: 48_000
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionAcousticDiagnosticsError,
                .invalidTransferFunction
            )
        }
    }
'''
    head, sep, _tail = tests.rpartition("\n}")
    if not sep:
        raise SystemExit("Unable to locate analyzer test class closing brace")
    tests_path.write_text(head + insertion + "\n}\n", encoding="utf-8")

workspace_path = root / "NotchSixty" / "UI" / "ProductionRoomCorrectionWorkspace.swift"
workspace = workspace_path.read_text(encoding="utf-8")
panel_call = "            RoomCorrectionAcousticDiagnosticsPanel(analysis: analysis)\n"
if panel_call not in workspace:
    anchor = '            channelReview("Right", measurement: analysis.right)\n'
    if anchor not in workspace:
        raise SystemExit("Unable to locate Room Correction review insertion point")
    workspace = workspace.replace(anchor, anchor + "\n" + panel_call, 1)

ui_marker = "private struct RoomCorrectionAcousticDiagnosticsPanel: View"
if ui_marker not in workspace:
    workspace += r'''

// MARK: - PR43 advanced acoustic diagnostics UI

private struct RoomCorrectionAcousticDiagnosticsPanel: View {
    private enum Channel: String, CaseIterable, Identifiable {
        case left = "Left"
        case right = "Right"
        var id: String { rawValue }
    }

    private enum Metric: String, CaseIterable, Identifiable {
        case impulse = "Impulse"
        case step = "Step"
        case energyTime = "ETC"
        case energyDecay = "EDC"
        case groupDelay = "Group Delay"

        var id: String { rawValue }

        var description: String {
            switch self {
            case .impulse:
                return "Time-domain impulse response aligned so the measured direct arrival is 0 ms."
            case .step:
                return "Normalized integral of the impulse response, useful for observing settling and polarity behavior."
            case .energyTime:
                return "1 ms smoothed Energy Time Curve, normalized to the strongest measured energy."
            case .energyDecay:
                return "Schroeder reverse-integrated Energy Decay Curve, normalized to 0 dB at total captured energy."
            case .groupDelay:
                return "Group delay derived from the unwrapped measured transfer-function phase."
            }
        }
    }

    let analysis: RoomCorrectionMeasurementAnalysis

    @State private var expanded = false
    @State private var selectedChannel: Channel = .left
    @State private var selectedMetric: Metric = .impulse
    @State private var diagnostics: RoomCorrectionAcousticDiagnosticsPair?
    @State private var analysisError: String?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Picker("Channel", selection: $selectedChannel) {
                            ForEach(Channel.allCases) { channel in
                                Text(channel.rawValue).tag(channel)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)

                        Picker("Diagnostic", selection: $selectedMetric) {
                            ForEach(Metric.allCases) { metric in
                                Text(metric.rawValue).tag(metric)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minWidth: 180)
                    }

                    Text(selectedMetric.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let diagnostics {
                        diagnosticChart(diagnostics)
                    } else if let analysisError {
                        Label(analysisError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        ProgressView("Deriving acoustic diagnostics…")
                    }
                }
                .padding(.top, 10)
                .task(id: analysis.left.capturedAt) {
                    guard diagnostics == nil, analysisError == nil else { return }
                    let snapshot = analysis
                    let result: (RoomCorrectionAcousticDiagnosticsPair?, String?) = await Task.detached(priority: .utility) {
                        do {
                            let value = try RoomCorrectionAcousticDiagnosticsAnalyzer().analyze(snapshot)
                            return (Optional(value), nil)
                        } catch {
                            return (nil, error.localizedDescription)
                        }
                    }.value
                    diagnostics = result.0
                    analysisError = result.1
                }
            }
        } label: {
            Label("Advanced Acoustic Diagnostics", systemImage: "waveform.path.ecg.rectangle")
                .font(.callout.weight(.semibold))
        }
    }

    @ViewBuilder
    private func diagnosticChart(
        _ pair: RoomCorrectionAcousticDiagnosticsPair
    ) -> some View {
        let channel = selectedChannel == .left ? pair.left : pair.right
        switch selectedMetric {
        case .impulse:
            RoomCorrectionDiagnosticLineChart(
                series: channel.impulse,
                xAxis: .time,
                yRange: -1.05 ... 1.05,
                timeWindowMilliseconds: -20 ... 300,
                yLabel: "Normalized amplitude"
            )
        case .step:
            RoomCorrectionDiagnosticLineChart(
                series: channel.step,
                xAxis: .time,
                yRange: -1.05 ... 1.05,
                timeWindowMilliseconds: -20 ... 300,
                yLabel: "Normalized step"
            )
        case .energyTime:
            RoomCorrectionDiagnosticLineChart(
                series: channel.energyTimeCurveDB,
                xAxis: .time,
                yRange: -80 ... 2,
                timeWindowMilliseconds: -20 ... 500,
                yLabel: "Energy · dB"
            )
        case .energyDecay:
            RoomCorrectionDiagnosticLineChart(
                series: channel.energyDecayDB,
                xAxis: .time,
                yRange: -80 ... 2,
                timeWindowMilliseconds: -20 ... 500,
                yLabel: "Decay · dB"
            )
        case .groupDelay:
            if let groupDelay = channel.groupDelayMilliseconds {
                RoomCorrectionDiagnosticLineChart(
                    series: groupDelay,
                    xAxis: .logFrequency,
                    yRange: nil,
                    timeWindowMilliseconds: nil,
                    yLabel: "Delay · ms"
                )
            } else {
                Text("Group delay is unavailable because this measurement does not contain phase data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RoomCorrectionDiagnosticLineChart: View {
    enum XAxis: Equatable {
        case time
        case logFrequency
    }

    let series: RoomCorrectionDiagnosticSeries
    let xAxis: XAxis
    let yRange: ClosedRange<Double>?
    let timeWindowMilliseconds: ClosedRange<Double>?
    let yLabel: String

    private var displayPoints: [(x: Double, y: Double)] {
        zip(series.x, series.y).compactMap { x, y in
            guard x.isFinite, y.isFinite else { return nil }
            if let timeWindowMilliseconds,
               !timeWindowMilliseconds.contains(x) {
                return nil
            }
            if xAxis == .logFrequency, x <= 0 { return nil }
            return (x, y)
        }
    }

    var body: some View {
        let points = displayPoints
        let resolvedY = resolvedYRange(points)
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                guard points.count >= 2 else { return }
                let xValues = points.map { transformedX($0.x) }
                guard let xMin = xValues.min(), let xMax = xValues.max(), xMax > xMin else { return }
                let yMin = resolvedY.lowerBound
                let yMax = resolvedY.upperBound
                guard yMax > yMin else { return }

                var path = Path()
                for index in points.indices {
                    let px = (xValues[index] - xMin) / (xMax - xMin) * size.width
                    let py = size.height - (points[index].y - yMin) / (yMax - yMin) * size.height
                    let point = CGPoint(x: px, y: py)
                    if index == points.startIndex {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
            }
            .frame(height: 230)
            .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Text(xAxis == .time ? "Time · ms" : "Frequency · Hz (log)")
                Spacer()
                Text(yLabel)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func transformedX(_ value: Double) -> Double {
        switch xAxis {
        case .time: return value
        case .logFrequency: return log10(value)
        }
    }

    private func resolvedYRange(_ points: [(x: Double, y: Double)]) -> ClosedRange<Double> {
        if let yRange { return yRange }
        let values = points.map(\.y).sorted()
        guard let minimum = values.first, let maximum = values.last else { return -1 ... 1 }
        if abs(maximum - minimum) < 1.0e-9 {
            return (minimum - 1) ... (maximum + 1)
        }
        // Robust plotting prevents isolated phase-derivative spikes from making
        // the useful group-delay structure unreadable while preserving the data.
        let lowIndex = min(values.count - 1, Int(Double(values.count - 1) * 0.02))
        let highIndex = min(values.count - 1, Int(Double(values.count - 1) * 0.98))
        let low = values[lowIndex]
        let high = values[max(lowIndex, highIndex)]
        let span = max(high - low, 1.0e-6)
        return (low - span * 0.08) ... (high + span * 0.08)
    }
}
'''
workspace_path.write_text(workspace, encoding="utf-8")

validator_path = root / "ci" / "validate_pr43_acoustic_diagnostics.py"
validator_path.write_text(r'''#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
ANALYZER = ROOT / "NotchSixty" / "Audio" / "RoomCorrectionMeasurementAnalyzer.swift"
UI = ROOT / "NotchSixty" / "UI" / "ProductionRoomCorrectionWorkspace.swift"
TESTS = ROOT / "NotchSixtyTests" / "RoomCorrectionMeasurementAnalyzerTests.swift"
REALTIME = ROOT / "NotchSixty" / "Audio" / "Realtime"


def fail(message: str) -> None:
    print(f"PR43 acoustic diagnostics validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)

analyzer = ANALYZER.read_text(encoding="utf-8")
ui = UI.read_text(encoding="utf-8")
tests = TESTS.read_text(encoding="utf-8")

for token in [
    "RoomCorrectionAcousticDiagnosticsAnalyzer",
    "energyTimeCurveDB",
    "energyDecayDB",
    "groupDelayMilliseconds",
    "Schroeder",
    "Offline-only derivation",
]:
    if token not in analyzer:
        fail(f"missing analyzer contract token: {token}")

for token in [
    "Advanced Acoustic Diagnostics",
    "RoomCorrectionDiagnosticLineChart",
    "Task.detached(priority: .utility)",
    "case impulse",
    "case step",
    "case energyTime",
    "case energyDecay",
    "case groupDelay",
]:
    if token not in ui:
        fail(f"missing UI contract token: {token}")

for token in [
    "testPR43AcousticDiagnosticsDeriveStepDecayAndGroupDelay",
    "testPR43AcousticDiagnosticsFailClosedOnInvalidInputs",
]:
    if token not in tests:
        fail(f"missing deterministic test: {token}")

for path in REALTIME.glob("*"):
    if path.suffix in {".c", ".h"} and "RoomCorrectionAcousticDiagnostics" in path.read_text(encoding="utf-8"):
        fail(f"offline diagnostics leaked into realtime source: {path.name}")

print("PR43 advanced acoustic diagnostics guard: PASS")
''', encoding="utf-8")
validator_path.chmod(0o755)

print("PR43 acoustic diagnostics staging patch applied")
