import SwiftUI

// E12 S30: the graph for each measuring step, built from what the model already holds.

extension SystemSetupFlowModel {
    private var graphSampleRate: Double { flow.choices.sampleRate ?? engine.selectedOutputDevice?.nominalSampleRate ?? 48_000 }

    var measureGraph: SystemSetupGraph? {
        SystemSetupGraphBuilder.measure(
            seats: calibration.seats, measurements: calibration.measurements, sampleRate: graphSampleRate, detail: graphDetail)
    }

    var bassGraph: SystemSetupGraph? {
        guard let bass, let grid = try? RoomCorrectionCore.gridFrequencies() else { return nil }
        return SystemSetupGraphBuilder.bass(design: bass, gridFrequenciesHz: grid, sampleRate: graphSampleRate, detail: graphDetail)
    }

    var correctionGraph: SystemSetupGraph? {
        SystemSetupGraphBuilder.correction(
            seats: calibration.seats, measurements: calibration.measurements, target: correctionTarget.curve,
            prediction: correctionPrediction, sampleRate: graphSampleRate, detail: graphDetail)
    }

    var verifyGraph: SystemSetupGraph? {
        verificationReport.flatMap { SystemSetupGraphBuilder.verify(report: $0) }
    }
}
