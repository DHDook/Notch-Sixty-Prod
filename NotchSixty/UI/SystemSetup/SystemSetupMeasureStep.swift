import SwiftUI
import UniformTypeIdentifiers

// E12 S29: split out of ProductionSystemSetupFlowView.swift with no change in behaviour.

struct SystemSetupMeasureStep: View {
    @ObservedObject var model: SystemSetupFlowModel
    @ObservedObject private var calibration: MultichannelCalibrationController
    @ObservedObject private var microphone: RoomCorrectionCalibrationController
    @State private var importingCalibrationSeat: UUID?

    init(model: SystemSetupFlowModel) {
        self.model = model
        _calibration = ObservedObject(wrappedValue: model.calibration)
        _microphone = ObservedObject(wrappedValue: model.microphone)
    }

    var body: some View {
        let progress = model.measureProgress
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Measure your listening seats").font(DesignType.sectionTitle.font)
            Text("Each speaker plays a sweep and the microphone records it at each seat. Measure the main seat first; add seats for a wider sweet spot. Playback is stopped while measuring.")
                .font(DesignType.label.font).foregroundStyle(.secondary)
            SystemSetupPlacementGuide(seatCount: max(1, calibration.seats.filter(\.included).count))
            if let note = model.correctionNote {
                ForEach(calibration.sources, id: \.self) { source in
                    Text(model.sourceLabel(source)).font(DesignType.caption.font)
                }
                Label(note, systemImage: "info.circle").font(DesignType.label.font)
            }
            if calibration.sources.isEmpty {
                Label("Choose your outputs and speakers first so the setup knows which speakers to measure.",
                      systemImage: "exclamationmark.triangle")
                    .font(DesignType.label.font)
            }
            Picker("Microphones", selection: Binding(
                get: { calibration.seatMicrophoneMode }, set: { model.setSeatMicrophoneMode($0) }
            )) {
                Text("One microphone, moved between seats").tag(SeatMicrophoneMode.movedMicrophone)
                Text("One microphone per seat").tag(SeatMicrophoneMode.perSeat)
            }
            .disabled(model.isMeasuring)
            HStack {
                Text("Repeats per sweep").font(DesignType.label.font)
                SweepRepeatPicker(repeatCount: $microphone.sweepRepeatCount, disabled: model.isMeasuring)
            }
            if let clock = calibration.seatClockMode {
                Text(clock.label).font(DesignType.caption.font).foregroundStyle(clock.isLessPrecise ? .orange : .secondary)
                if clock.isLessPrecise {
                    Text("Each device has its own clock, so timing between seats comes from a chirp the front-left speaker plays before every sweep. It is less precise than channels of one interface; keep the microphones' devices running for the whole measurement.")
                        .font(DesignType.caption.font).foregroundStyle(.secondary)
                }
            }
            MeasurementSeatsCard(
                calibration: calibration, microphone: microphone, locked: model.isMeasuring,
                onAdd: { model.addSeat() },
                onRemove: { model.removeSeat($0) },
                onSetDevice: { model.setSeatDevice($0, uid: $1) },
                onSetChannel: { model.setSeatChannel($0, channel: $1) },
                onImportCalibration: { importingCalibrationSeat = $0 },
                onClearCalibration: { model.clearSeatCalibration($0) },
                accessory: { seat in
                    HStack {
                        Image(systemName: progress.isComplete(seat) ? "checkmark.circle.fill" : "circle")
                        if let latest = calibration.measurements.last(where: { $0.seatID == seat.id }) {
                            RepeatSummaryNote(quality: latest.channel.quality)
                        }
                        if let verdict = model.choices.seatVerdicts?.first(where: { $0.seatName == seat.name })?.verdict {
                            Text("\(verdict.level.title): \(verdict.reason)")
                                .font(DesignType.caption.font).foregroundStyle(verdict.level >= .limited ? .orange : .secondary)
                        }
                        if progress.isComplete(seat) {
                            Button("Re-measure") { model.startRemeasure(seatID: seat.id) }.disabled(model.isMeasuring)
                        }
                    }
                })
            HStack {
                Spacer()
                if model.isMeasuring {
                    Button("Stop") { model.cancelMeasurement() }
                } else {
                    Button(progress.isComplete ? "Measure again" : "Measure") {
                        model.startMeasuring()
                    }
                    .disabled((progress.next == nil && !progress.isComplete) || !calibration.readiness.isReady)
                }
            }
            MeasurementReadinessNote(readiness: calibration.readiness, playbackNotice: model.measurePlaybackNotice)
            ProgressView(value: model.isMeasuring ? calibration.activeMeasurementProgress : progress.fraction)
            if let next = progress.next, model.isMeasuring {
                Text("Measuring \(next.seat.name), \(next.source.displayName)").font(DesignType.caption.font)
            }
            if !model.isMeasuring, !calibration.measurements.isEmpty {
                SystemSetupGraphPanel(model: model, graph: model.measureGraph,
                                      emptyNote: "No graph yet: the measurements carry no frequency response to draw.")
            }
        }
        .onAppear { model.prepareMeasure() }
        .fileImporter(
            isPresented: Binding(get: { importingCalibrationSeat != nil }, set: { if !$0 { importingCalibrationSeat = nil } }),
            allowedContentTypes: [.plainText, .commaSeparatedText, .data]
        ) { result in
            guard let seatID = importingCalibrationSeat else { return }
            importingCalibrationSeat = nil
            guard let url = try? result.get() else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                model.message = "Microphone calibration files must be UTF-8 text with frequency and gain columns."
                return
            }
            model.importSeatCalibration(seatID, text: text, sourceName: url.lastPathComponent)
        }
    }
}
