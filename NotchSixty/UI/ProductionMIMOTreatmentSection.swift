import SwiftUI

/// E19 S8: the Room Treatment controls under Active Acoustics. Speaker list with include and support range, bass time target,
/// decay target, Design, predicted decay per seat, per-source headroom and live readout, gate status, Arm and Bypass. Shown
/// only behind `e19.mimo-treatment`. Arm and Bypass are enabled only with a permit; the arm itself keeps every engine gate and
/// the written authorisation path, and nothing here arms by default.
struct ProductionMIMOTreatmentSection: View {
    @ObservedObject var controller: MIMOTreatmentController

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            sourcesCard
            targetsCard
            designCard
            if !controller.seatDecays.isEmpty { decayCard }
            if !controller.readout.isEmpty { readoutCard }
            armCard
        }
        .task {
            controller.refreshSources()
            while !Task.isCancelled {
                controller.refreshReadout()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Speakers").font(DesignType.sectionTitle.font)
            if controller.rows.isEmpty {
                Text("No measured speakers yet. Measure the seats in the Speaker Measurement Lab; each speaker and subwoofer with a measurement at every included seat appears here.")
                    .font(DesignType.label.font).foregroundStyle(.secondary)
            }
            ForEach(controller.rows) { row in
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                HStack(spacing: DesignSpacing.l.pt) {
                    Toggle(row.name, isOn: Binding(get: { row.included }, set: { controller.setIncluded($0, lane: row.lane) }))
                        .accessibilityLabel("Include \(row.name) in room treatment")
                    Spacer()
                    rangeField("Low", value: row.supportLowHz, name: row.name) {
                        controller.setSupport(lowHz: $0, highHz: row.supportHighHz, lane: row.lane)
                    }
                    rangeField("High", value: row.supportHighHz, name: row.name) {
                        controller.setSupport(lowHz: row.supportLowHz, highHz: $0, lane: row.lane)
                    }
                    Text("Hz").foregroundStyle(.secondary)
                }
                if !row.inBandWays.isEmpty {
                    Text("Treated ways: \(row.inBandWays.joined(separator: ", ")). Other ways play their program only.")
                        .font(DesignType.caption.font).foregroundStyle(.secondary)
                        .accessibilityLabel("\(row.name) treated ways: \(row.inBandWays.joined(separator: ", "))")
                }
                }
            }
            ForEach(controller.matrixOnlyOutputs, id: \.self) { note in
                Text(note).font(DesignType.caption.font).foregroundStyle(.secondary)
                    .accessibilityLabel(note)
            }
            if !controller.missingWayNotes.isEmpty {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Driver measurements needed").font(DesignType.label.font.weight(.semibold))
                    ForEach(controller.missingWayNotes, id: \.self) { Text($0).font(DesignType.caption.font).foregroundStyle(.secondary) }
                    Button("Measure drivers") { Task { await controller.measureWays() } }
                        .disabled(controller.isMeasuringWays)
                        .accessibilityLabel("Measure the listed drivers at the included seats")
                }
            }
            if let status = controller.wayMeasureStatus {
                Text(status).font(DesignType.caption.font).foregroundStyle(.secondary)
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private func rangeField(_ title: String, value: Double, name: String, set: @escaping (Double) -> Void) -> some View {
        TextField(title, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(0)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            .accessibilityLabel("\(name) support range \(title.lowercased()) frequency in hertz")
    }

    private var targetsCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Targets").font(DesignType.sectionTitle.font)
            HStack {
                Text("Bass time target")
                Slider(
                    value: Binding(get: { controller.tauMilliseconds }, set: { controller.setTau(milliseconds: $0) }),
                    in: MIMOTreatmentController.tauRangeMilliseconds, step: 0.5
                )
                .accessibilityLabel("Bass time target in milliseconds")
                Text(String(format: "%.1f ms", controller.tauMilliseconds)).monospacedDigit().frame(width: 70, alignment: .trailing)
            }
            if let note = controller.shortTauNote {
                Text(note).font(DesignType.caption.font).foregroundStyle(StatusLevel.attention.color)
            }
            HStack {
                Text("Decay target")
                Picker("Decay target", selection: decayChoice) {
                    Text("Automatic (D2)").tag(-1.0)
                    ForEach([0.15, 0.2, 0.3, 0.4, 0.6], id: \.self) { Text(String(format: "%.2f s", $0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
                .accessibilityLabel("Decay target")
                if let used = controller.designedDecaySeconds {
                    Text(String(format: "Designed for %.2f s", used)).font(DesignType.caption.font).foregroundStyle(.secondary)
                }
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private var decayChoice: Binding<Double> {
        Binding(
            get: { if case .seconds(let value) = controller.decayTarget { return value } else { return -1 } },
            set: { controller.decayTarget = $0 < 0 ? .automatic : .seconds($0) })
    }

    private var designCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                Button("Design") { Task { await controller.design() } }
                    .disabled(!controller.canDesign)
                    .accessibilityLabel("Design room treatment")
                if controller.phase == .designing { ProgressView().controlSize(.small) }
                Spacer()
            }
            switch controller.phase {
            case .failed(let text):
                Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(StatusLevel.problem.color).font(DesignType.label.font)
            case .designed:
                Label("Design staged. It is off until you arm it.", systemImage: "checkmark.circle").font(DesignType.label.font)
            default: EmptyView()
            }
            ForEach(controller.designAdvice, id: \.self) { Text($0).font(DesignType.caption.font).foregroundStyle(.secondary) }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private var decayCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text("Predicted bass decay (T30, 25-160 Hz)").font(DesignType.sectionTitle.font)
            ForEach(controller.seatDecays) { seat in
                LabeledContent(seat.name) {
                    Text("\(format(seat.beforeSeconds)) before, \(format(seat.afterSeconds)) after").monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private func format(_ seconds: Double?) -> String { seconds.map { String(format: "%.2f s", $0) } ?? "n/a" }

    private var readoutCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text("Per-speaker headroom, excursion and thermal").font(DesignType.sectionTitle.font)
            ForEach(controller.readout) { item in
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text(item.name + (item.included ? "" : " (not treated)")).font(DesignType.label.font.bold())
                    Text(readoutLine(item)).font(DesignType.caption.font).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private func readoutLine(_ item: MIMOTreatmentController.SourceReadout) -> String {
        func db(_ value: Double?) -> String { value.map { String(format: "%.1f dB", $0) } ?? "n/a" }
        return "Headroom budget \(db(item.headroomBudgetDB)), designed peak \(db(item.designedPeakGainDB)), thermal \(db(item.designedThermalDB)); live delta ratio \(db(item.liveBoundRatioDB)), live peak \(db(item.livePeakDeltaDBFS))"
    }

    private var armCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                Text("Treatment").font(DesignType.sectionTitle.font)
                Text(controller.armStateLabel.uppercased()).font(DesignType.caption.font.bold())
                    .padding(.horizontal, DesignSpacing.m.pt).padding(.vertical, DesignSpacing.s.pt).glassEffect(.regular, in: .capsule)
                Spacer()
                Button("Check design") { controller.requestPermit() }
                    .disabled(!controller.isAvailable || controller.phase != .designed)
                    .accessibilityLabel("Check the design and ask for a permit")
                Button("Arm") { Task { await controller.arm() } }
                    .disabled(!controller.canArm)
                    .accessibilityLabel("Arm room treatment with a three second fade in")
                Button("Bypass") { controller.bypass() }
                    .disabled(!controller.canBypass)
                    .accessibilityLabel("Bypass room treatment")
            }
            ForEach(controller.gates) { gate in
                Label(gate.name, systemImage: gate.passed ? "checkmark.circle.fill" : "circle.dashed")
                    .font(DesignType.caption.font).foregroundStyle(gate.passed ? .primary : .secondary)
                    .accessibilityLabel("\(gate.name): \(gate.passed ? "met" : "not met")")
            }
            ForEach(controller.permitRefusals, id: \.self) { reason in
                Label(reason, systemImage: "lock.shield").font(DesignType.caption.font).foregroundStyle(StatusLevel.attention.color)
            }
            if let message = controller.armMessage {
                Label(message, systemImage: "exclamationmark.triangle").font(DesignType.caption.font).foregroundStyle(StatusLevel.problem.color)
            }
            Text("Arm needs a permit: a verified design, a treated repeat measurement and a hardware acceptance or class qualification. Arming starts a three second fade in; Bypass fades out at once.")
                .font(DesignType.caption.font).foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }
}
