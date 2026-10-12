import SwiftUI

struct ProductionMultichannelCalibrationWorkspace: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var calibration: MultichannelCalibrationController
    @ObservedObject var microphone: RoomCorrectionCalibrationController
    @ObservedObject var profiles: ProductProfileController
    @StateObject private var optimizer: SpeakerOptimizerMeasurementController
    @StateObject private var characterization: SpeakerOptimizerCharacterizationController

    @State private var actionError: String?
    @State private var resetConfirmation = false
    @State private var intelligentTargetPreference:
        IntelligentTargetPreference = .neutral

    init(
        engine: AudioIOEngine,
        calibration: MultichannelCalibrationController,
        microphone: RoomCorrectionCalibrationController,
        profiles: ProductProfileController
    ) {
        _engine = ObservedObject(wrappedValue: engine)
        _calibration = ObservedObject(wrappedValue: calibration)
        _microphone = ObservedObject(wrappedValue: microphone)
        _profiles = ObservedObject(wrappedValue: profiles)
        _optimizer = StateObject(
            wrappedValue: SpeakerOptimizerMeasurementController(
                engine: engine,
                profiles: profiles,
                microphone: microphone
            )
        )
        _characterization = StateObject(
            wrappedValue: try! SpeakerOptimizerCharacterizationController(
                engine: engine,
                profiles: profiles,
                microphone: microphone
            )
        )
    }

    private var selectedInputBinding: Binding<String?> {
        Binding(
            get: { microphone.selectedInputUID },
            set: { microphone.selectInput(uid: $0) }
        )
    }

    private var inputChannelBinding: Binding<Int> {
        Binding(
            get: { microphone.selectedInputChannelIndex + 1 },
            set: { value in try? microphone.selectInputChannel(index: max(0, value - 1)) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                systemCard
                microphoneCard
                seatsCard
                campaignCard
                speakerOptimizerCard
                speakerCharacterizationCard
                designCard

                if let error = actionError
                    ?? characterization.lastErrorDescription
                    ?? optimizer.lastErrorDescription
                    ?? calibration.lastErrorDescription
                    ?? microphone.lastErrorDescription {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(28)
            .frame(maxWidth: 1_020, alignment: .topLeading)
        }
        .task {
            microphone.prepareForUse()
            calibration.prepareForUse()
        }
        .task(id: profiles.selectedSystemProfileID) {
            calibration.cancelMeasurement()
            calibration.prepareForUse()
        }
        .task(id: engine.selectedOutputDevice?.uid) {
            calibration.cancelMeasurement()
            calibration.prepareForUse()
        }
        .task(id: calibration.state) {
            guard calibration.state == .measuring else { return }
            while !Task.isCancelled && calibration.state == .measuring {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                do {
                    if try await calibration.finishMeasurementIfComplete() { break }
                } catch {
                    actionError = error.localizedDescription
                    break
                }
            }
        }
        .task(id: optimizer.state) {
            guard optimizer.state == .measuring else { return }
            while !Task.isCancelled && optimizer.state == .measuring {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                do {
                    if try await optimizer.finishMeasurementIfComplete() { break }
                } catch {
                    actionError = error.localizedDescription
                    break
                }
            }
        }
        .task(id: characterization.state) {
            guard characterization.state == .measuring else { return }
            while !Task.isCancelled && characterization.state == .measuring {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                do {
                    if try await characterization.finishMeasurementIfComplete() {
                        break
                    }
                } catch {
                    actionError = error.localizedDescription
                    break
                }
            }
        }
        .confirmationDialog(
            "Reset all speaker-calibration measurements for this Playback System?",
            isPresented: $resetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Measurements", role: .destructive) {
                perform { try calibration.resetMeasurements() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speaker Calibration")
                .font(.largeTitle.bold())
            Text("Measure every physical speaker and subwoofer at each listening seat, then generate level, polarity, timing and bounded attenuation-only EQ for the selected Playback System.")
                .foregroundStyle(.secondary)
        }
    }

    private var systemCard: some View {
        GroupBox("Playback System") {
            VStack(alignment: .leading, spacing: 12) {
                if let profile = calibration.profile {
                    HStack(spacing: 24) {
                        status("System", profiles.selectedSystemProfileName)
                        status("Physical Layout", profile.systemDisplayName)
                        status("Program Layout", profile.programLayout.displayName)
                        status("Sources", "\(calibration.sources.count)")
                    }
                    HStack(spacing: 24) {
                        status("Output", engine.selectedOutputDevice?.name ?? "Not selected")
                        status(
                            "Native Rate",
                            engine.selectedOutputDevice.map {
                                String(format: "%.1f kHz", $0.nominalSampleRate / 1_000)
                            } ?? "—"
                        )
                        status("DSP", engine.lifecycleState.rawValue.capitalized)
                    }
                    Text("Native LFE is program content, not a physical calibration source. Speaker Calibration measures each non-LFE semantic speaker and each explicit Sub N output independently.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "Enable and fully map an Output Device Profile for this Playback System before calibrating speakers.",
                        systemImage: "speaker.slash"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var microphoneCard: some View {
        GroupBox("Measurement Microphone") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Permission") {
                    HStack(spacing: 10) {
                        Text(permissionLabel)
                            .foregroundStyle(microphone.permissionStatus == .authorized ? .primary : .secondary)
                        if microphone.permissionStatus != .authorized {
                            Button("Request Access") {
                                actionError = nil
                                Task { await microphone.requestMicrophonePermission() }
                            }
                        }
                    }
                }

                if microphone.permissionStatus == .authorized {
                    LabeledContent("Input") {
                        HStack(spacing: 10) {
                            Picker("Measurement Input", selection: selectedInputBinding) {
                                Text("Choose a microphone…").tag(Optional<String>.none)
                                ForEach(microphone.inputDevices) { device in
                                    Text("\(device.name) · \(device.nominalSampleRate / 1_000, specifier: "%.1f") kHz")
                                        .tag(Optional(device.uid))
                                }
                            }
                            .productionGlassPickerChrome()
                            .labelsHidden()
                            .frame(minWidth: 330)
                            .disabled(calibration.state == .measuring || calibration.state == .analyzing)

                            Button("Refresh") {
                                perform { _ = try microphone.refreshInputDevices() }
                            }
                            .disabled(calibration.state == .measuring || calibration.state == .analyzing)
                        }
                    }

                    LabeledContent("Input Channel") {
                        Stepper(
                            "Channel \(microphone.selectedInputChannelIndex + 1)",
                            value: inputChannelBinding,
                            in: 1...64
                        )
                        .disabled(calibration.state == .measuring || calibration.state == .analyzing)
                    }

                    if let calibrationFile = microphone.microphoneCalibration {
                        LabeledContent("Mic Calibration") {
                            Text(calibrationFile.sourceName ?? "Loaded calibration curve")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text("Normal DSP playback must be stopped during acoustic measurement. The measurement transport owns the output hardware temporarily and zeros every non-target output lane before each sweep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private var seatsCard: some View {
        GroupBox("Listening Seats") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(calibration.seats) { seat in
                    HStack(spacing: 12) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { seat.included },
                                set: { value in
                                    perform {
                                        try calibration.updateSeat(
                                            seat.id,
                                            name: seat.name,
                                            included: value,
                                            weight: seat.weight
                                        )
                                    }
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()

                        TextField(
                            "Seat name",
                            text: Binding(
                                get: { seat.name },
                                set: { value in
                                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                    perform {
                                        try calibration.updateSeat(
                                            seat.id,
                                            name: value,
                                            included: seat.included,
                                            weight: seat.weight
                                        )
                                    }
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)

                        Stepper(
                            value: Binding(
                                get: { seat.weight },
                                set: { value in
                                    perform {
                                        try calibration.updateSeat(
                                            seat.id,
                                            name: seat.name,
                                            included: seat.included,
                                            weight: value
                                        )
                                    }
                                }
                            ),
                            in: 0...5,
                            step: 0.25
                        ) {
                            Text("Weight \(seat.weight, specifier: "%.2g")")
                                .monospacedDigit()
                                .frame(width: 100, alignment: .leading)
                        }

                        Spacer()
                        if calibration.seats.count > 1 {
                            Button(role: .destructive) {
                                perform { try calibration.removeSeat(seat.id) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Remove this seat and its measurements")
                        }
                    }
                    .disabled(calibration.state == .measuring || calibration.state == .analyzing)
                }

                HStack {
                    Button("Add Seat") {
                        perform { try calibration.addSeat() }
                    }
                    .disabled(
                        calibration.seats.count >= Int(N60_CALIBRATION_MAX_SEATS)
                            || calibration.state == .measuring
                            || calibration.state == .analyzing
                    )
                    Spacer()
                    Text("Up to \(Int(N60_CALIBRATION_MAX_SEATS)) weighted seats")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var campaignCard: some View {
        GroupBox("Measurement Campaign") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(calibration.completedMeasurementCount) of \(calibration.totalMeasurementCount) measurements")
                            .font(.headline)
                        if let target = calibration.currentTarget {
                            Text(
                                calibration.state == .measuring
                                    ? "Measuring \(target.displayName)"
                                    : "Next: \(target.displayName)"
                            )
                            .foregroundStyle(.secondary)
                        } else if calibration.campaignComplete {
                            Text("All included seats and physical sources measured")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    stateBadge
                }

                ProgressView(value: campaignProgress)

                if calibration.state == .measuring {
                    ProgressView(value: calibration.activeMeasurementProgress) {
                        Text("Current sweep")
                    }
                }

                HStack(spacing: 10) {
                    Button(calibration.campaignComplete ? "Campaign Complete" : "Measure Next") {
                        perform { try calibration.beginNextMeasurement() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!calibration.canMeasure)

                    if calibration.state == .measuring || calibration.state == .analyzing {
                        Button("Cancel") { calibration.cancelMeasurement() }
                    }

                    Spacer()
                    Button("Reset…", role: .destructive) {
                        resetConfirmation = true
                    }
                    .disabled(calibration.measurements.isEmpty)
                }

                if !calibration.sources.isEmpty && !calibration.seats.isEmpty {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                        GridRow {
                            Text("Seat").font(.caption.bold())
                            Text("Source").font(.caption.bold())
                            Text("Status").font(.caption.bold())
                        }
                        ForEach(calibration.seats.filter(\.included)) { seat in
                            ForEach(Array(calibration.sources.enumerated()), id: \.offset) { _, source in
                                GridRow {
                                    Text(seat.name)
                                    Text(source.displayName)
                                    if hasMeasurement(seat: seat, source: source) {
                                        Label("Measured", systemImage: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    } else {
                                        Text("Pending").foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private var speakerOptimizerCard: some View {
        GroupBox("Speaker Optimizer Measurements") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Repeated acoustic evidence")
                            .font(.headline)
                        Text(
                            "Build a baseline from repeated isolated speaker/sub sweeps. This stage measures only; it does not generate or deploy optimizer filters."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(optimizer.state.rawValue.capitalized)
                        .font(.caption.bold())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }

                HStack(spacing: 10) {
                    Button(
                        optimizer.measurementSet == nil
                            ? "Start Baseline Session"
                            : "Refresh / Resume Baseline"
                    ) {
                        actionError = nil
                        do {
                            try optimizer.startOrResumeBaselineSession(
                                positions: calibration.seats
                            )
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.bordered)

                    if optimizer.measurementSet != nil {
                        Button("Reset Baseline…", role: .destructive) {
                            actionError = nil
                            do {
                                try optimizer.resetBaselineSession(
                                    positions: calibration.seats
                                )
                            } catch {
                                actionError = error.localizedDescription
                            }
                        }
                        .disabled(
                            optimizer.state == .measuring
                                || optimizer.state == .analyzing
                        )
                    }
                }

                if let set = optimizer.measurementSet,
                   let progress = optimizer.progress {
                    Divider()

                    HStack(spacing: 24) {
                        status("Role", set.role.rawValue.capitalized)
                        status(
                            "Repeats",
                            "\(progress.completedSweepCount) / \(progress.requiredSweepCount)"
                        )
                        status(
                            "Groups",
                            "\(progress.completedPositionSourceGroups) / \(progress.requiredPositionSourceGroups)"
                        )
                        status(
                            "Confidence",
                            optimizer.evidenceReport.map {
                                "\(Int(($0.confidence * 100).rounded()))%"
                            } ?? "—"
                        )
                    }

                    ProgressView(value: progress.fractionComplete)

                    if let step = optimizer.activeOrNextStep {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                optimizer.state == .measuring
                                    ? "Measuring \(step.displayName)"
                                    : "Next: \(step.displayName)"
                            )
                            .font(.callout.bold())
                            Text(
                                "Move the selected microphone to \(step.position.name) and keep its position fixed for all repeats at that position."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } else if progress.complete {
                        Label(
                            "All planned repeated sweeps are captured.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    }

                    if optimizer.state == .measuring {
                        ProgressView(
                            value: optimizer.activeMeasurementProgress
                        ) {
                            Text("Current optimizer sweep")
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Measure Next Repeat") {
                            actionError = nil
                            do {
                                try optimizer.beginNextMeasurement()
                            } catch {
                                actionError = error.localizedDescription
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!optimizer.canBeginMeasurement)

                        if optimizer.state == .measuring
                            || optimizer.state == .analyzing {
                            Button("Cancel") {
                                optimizer.cancelMeasurement()
                            }
                        }
                    }

                    if let report = optimizer.evidenceReport {
                        Divider()
                        HStack(spacing: 10) {
                            Label(
                                report.optimizerReady
                                    ? "Optimizer-ready evidence"
                                    : "Evidence not optimizer-ready",
                                systemImage: report.optimizerReady
                                    ? "checkmark.shield.fill"
                                    : "exclamationmark.shield.fill"
                            )
                            .font(.callout.bold())
                            .foregroundStyle(
                                report.optimizerReady ? .green : .secondary
                            )
                            Spacer()
                            Text(
                                "Confidence \(Int((report.confidence * 100).rounded()))%"
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }

                        Grid(
                            alignment: .leading,
                            horizontalSpacing: 14,
                            verticalSpacing: 6
                        ) {
                            GridRow {
                                Text("Position").font(.caption.bold())
                                Text("Source").font(.caption.bold())
                                Text("Repeats").font(.caption.bold())
                                Text("SNR").font(.caption.bold())
                                Text("Repeatability").font(.caption.bold())
                                Text("Timing").font(.caption.bold())
                                Text("Phase").font(.caption.bold())
                                Text("Status").font(.caption.bold())
                            }
                            ForEach(
                                Array(report.groupReports.enumerated()),
                                id: \.offset
                            ) { _, group in
                                GridRow {
                                    Text(
                                        set.positions.first(
                                            where: {
                                                $0.id == group.positionID
                                            }
                                        )?.name ?? "Unknown"
                                    )
                                    Text(group.source.displayName)
                                    Text("\(group.repeatCount)")
                                    Text(
                                        group.minimumSNRDB.map {
                                            String(format: "%.1f dB", $0)
                                        } ?? "—"
                                    )
                                    Text(
                                        group.magnitudeRepeatabilityRMSDB.map {
                                            String(format: "%.2f dB", $0)
                                        } ?? "—"
                                    )
                                    Text(
                                        group.arrivalSpreadMilliseconds.map {
                                            String(format: "%.2f ms", $0)
                                        } ?? "—"
                                    )
                                    Text(
                                        group.phaseConsistency.map {
                                            String(format: "%.0f%%", $0 * 100)
                                        } ?? "—"
                                    )
                                    Text(
                                        group.optimizerReady
                                            ? "Ready"
                                            : "Blocked"
                                    )
                                    .foregroundStyle(
                                        group.optimizerReady
                                            ? .green
                                            : .secondary
                                    )
                                }
                                .font(.caption)
                            }
                        }

                        if !report.blockingReasons.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(
                                    Array(
                                        report.blockingReasons
                                            .prefix(8)
                                            .enumerated()
                                    ),
                                    id: \.offset
                                ) { _, reason in
                                    Label(
                                        reason,
                                        systemImage:
                                            "exclamationmark.triangle"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let blocked = optimizer.activeTransportPlan?.blockReason {
                    Label(
                        blocked.message,
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Text(
                    "Protected Low/Mid/High driver-bus measurements remain fail-closed in PR103. They will not be excited through a raw physical-output bypass; a crossover-preserving protected measurement path is required first."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }


    private var speakerCharacterizationCard: some View {
        GroupBox("Speaker Optimizer · Speaker Characterization") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Step 2 · Characterize each whole speaker")
                            .font(.headline)
                        Text(
                            "After the listening-position baseline qualifies, move the same microphone to the guided ~1 m position for each whole speaker. Three stationary repeats are taken before moving to the next speaker."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(characterization.state.rawValue.capitalized)
                        .font(.caption.bold())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }

                if optimizer.evidenceReport?.optimizerReady != true {
                    Label(
                        "Complete an optimizer-ready listening-position baseline above before starting characterization.",
                        systemImage: "1.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button(
                        characterization.measurementSet == nil
                            ? "Start Speaker Characterization"
                            : "Refresh / Resume Characterization"
                    ) {
                        actionError = nil
                        do {
                            guard let baseline = optimizer.measurementSet else {
                                throw SpeakerOptimizerCharacterizationControllerError
                                    .listeningBaselineRequired
                            }
                            try characterization.startOrResumeSession(
                                listeningBaseline: baseline
                            )
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(optimizer.evidenceReport?.optimizerReady != true)

                    if characterization.measurementSet != nil,
                       let baseline = optimizer.measurementSet {
                        Button("Reset Characterization", role: .destructive) {
                            actionError = nil
                            do {
                                try characterization.resetSession(
                                    listeningBaseline: baseline
                                )
                            } catch {
                                actionError = error.localizedDescription
                            }
                        }
                        .disabled(
                            characterization.state == .measuring
                                || characterization.state == .analyzing
                        )
                    }
                }

                if let set = characterization.measurementSet,
                   let progress = characterization.progress {
                    Divider()

                    HStack(spacing: 24) {
                        status(
                            "Speakers",
                            "\(progress.completedTargetCount) / \(progress.requiredTargetCount)"
                        )
                        status(
                            "Repeats",
                            "\(progress.completedSweepCount) / \(progress.requiredSweepCount)"
                        )
                        status(
                            "Confidence",
                            characterization.evidenceReport.map {
                                "\(Int(($0.confidence * 100).rounded()))%"
                            } ?? "—"
                        )
                        status(
                            "Early Window",
                            characterization.earlyWindowEvidenceComplete
                                ? "Complete" : "Pending"
                        )
                    }

                    ProgressView(value: progress.fractionComplete)

                    if let step = characterization.activeOrNextStep {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(
                                characterization.state == .measuring
                                    ? "Measuring \(step.target.source.displayName)"
                                    : "Next: \(step.target.source.displayName)"
                            )
                            .font(.callout.bold())
                            Text(step.instruction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(
                                "Do not move the loudspeaker. This installed-room measurement is source-weighted evidence, not an anechoic claim."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } else if progress.complete {
                        Label(
                            "All whole-speaker characterization repeats are captured.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    }

                    if characterization.state == .measuring {
                        ProgressView(
                            value: characterization.activeMeasurementProgress
                        ) {
                            Text("Current characterization sweep")
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Measure Next Characterization Repeat") {
                            actionError = nil
                            do {
                                try characterization.beginNextMeasurement()
                            } catch {
                                actionError = error.localizedDescription
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!characterization.canBeginMeasurement)

                        if characterization.state == .measuring
                            || characterization.state == .analyzing {
                            Button("Cancel") {
                                characterization.cancelMeasurement()
                            }
                        }
                    }

                    if let evidence = characterization.evidenceReport {
                        HStack(spacing: 10) {
                            Label(
                                characterization.characterizationReady
                                    ? "Characterization evidence ready"
                                    : "Characterization not ready",
                                systemImage: characterization.characterizationReady
                                    ? "checkmark.shield.fill"
                                    : "exclamationmark.shield.fill"
                            )
                            .font(.callout.bold())
                            .foregroundStyle(
                                characterization.characterizationReady
                                    ? .green : .secondary
                            )
                            Spacer()
                            Text(
                                "Confidence \(Int((evidence.confidence * 100).rounded()))%"
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }

                    if let report = crossDomainClassificationReport {
                        Divider()
                        let summary =
                            SpeakerOptimizerCrossDomainSummary(report: report)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Step 3 · Compare speaker vs room evidence")
                                .font(.headline)
                            HStack(spacing: 22) {
                                status(
                                    "Speaker-persistent",
                                    "\(summary.speakerPersistentPointCount)"
                                )
                                status(
                                    "Room / seat",
                                    "\(summary.roomSeatDependentPointCount)"
                                )
                                status(
                                    "Ambiguous",
                                    "\(summary.ambiguousPointCount)"
                                )
                                status(
                                    "No material deviation",
                                    "\(summary.noMaterialDeviationPointCount)"
                                )
                            }

                            Grid(
                                alignment: .leading,
                                horizontalSpacing: 16,
                                verticalSpacing: 6
                            ) {
                                GridRow {
                                    Text("Source").font(.caption.bold())
                                    Text("Speaker-persistent")
                                        .font(.caption.bold())
                                    Text("Room / seat")
                                        .font(.caption.bold())
                                    Text("Ambiguous").font(.caption.bold())
                                }
                                ForEach(
                                    Array(report.sources.enumerated()),
                                    id: \.offset
                                ) { _, sourceReport in
                                    GridRow {
                                        Text(sourceReport.source.displayName)
                                        Text(
                                            "\(Int((sourceReport.speakerPersistentFraction * 100).rounded()))%"
                                        )
                                        Text(
                                            "\(Int((sourceReport.roomSeatDependentFraction * 100).rounded()))%"
                                        )
                                        Text(
                                            "\(sourceReport.points.filter { $0.classification == .ambiguous }.count)"
                                        )
                                    }
                                    .font(.caption)
                                }
                            }

                            Text(
                                "Only speaker-persistent regions may drive the guided PEQ/FIR speaker-correction path. Room/seat-dependent, ambiguous, flat, below-window and unclassified regions remain protected."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Text(
                    "Subwoofers remain in the listening-position integration campaign. Protected Low/Mid/High driver buses still require a crossover-preserving measurement path and are not directly swept."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private var crossDomainClassificationReport:
        SpeakerOptimizerCrossDomainReport? {
        guard characterization.characterizationReady,
              optimizer.evidenceReport?.optimizerReady == true,
              let characterizationSet = characterization.measurementSet,
              let baseline = optimizer.measurementSet else {
            return nil
        }
        return try? SpeakerOptimizerCrossDomainClassifier().classify(
            characterization: characterizationSet,
            listeningBaseline: baseline
        )
    }

    private var designCard: some View {
        GroupBox("Calibration Design") {
            VStack(alignment: .leading, spacing: 14) {
                Text("The product deployment is intentionally headroom-safe: speaker trims, speaker EQ, sub gain and sub EQ are attenuation-only. Timing and polarity remain fully available, and multi-sub relative relationships are preserved without positive digital gain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GroupBox("Adaptive Target") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Picker(
                                "Voicing",
                                selection: $intelligentTargetPreference
                            ) {
                                ForEach(
                                    IntelligentTargetPreference.allCases
                                ) { preference in
                                    Text(preference.displayName)
                                        .tag(preference)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 340)

                            Button {
                                actionError = nil
                                do {
                                    _ = try calibration
                                        .generateIntelligentTarget(
                                            preference:
                                                intelligentTargetPreference
                                        )
                                } catch {
                                    actionError = error.localizedDescription
                                }
                            } label: {
                                Label(
                                    "Generate from Campaign",
                                    systemImage:
                                        "waveform.badge.magnifyingglass"
                                )
                            }
                            .buttonStyle(.bordered)
                            .disabled(!calibration.campaignComplete)

                            if calibration.intelligentTargetReport != nil {
                                Button("Use Flat") {
                                    calibration.clearIntelligentTarget()
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        Text(
                            "Uses the completed full-range speaker measurements across all included seats. Subwoofer measurements do not shape the broadband target. The resulting curve is still independently checked by PR86 when the calibration design is generated."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if let report =
                            calibration.intelligentTargetReport {
                            HStack(spacing: 22) {
                                status(
                                    "Target",
                                    report.target.name
                                )
                                status(
                                    "Confidence",
                                    "\(Int((report.confidence * 100).rounded()))%"
                                )
                                status(
                                    "Bass Shelf",
                                    String(
                                        format: "%+.2f dB",
                                        report.generatedBassShelfDB
                                    )
                                )
                                status(
                                    "20 kHz Tilt",
                                    String(
                                        format: "%+.2f dB",
                                        report.generatedTrebleAt20KDB
                                    )
                                )
                            }
                            HStack(spacing: 22) {
                                status(
                                    "Bass Extension",
                                    String(
                                        format: "%.0f Hz",
                                        report.estimatedBassExtensionHz
                                    )
                                )
                                status(
                                    "Target Band",
                                    String(
                                        format: "%.0f–%.0f Hz",
                                        report.effectiveLowHz,
                                        report.effectiveHighHz
                                    )
                                )
                                status(
                                    "Spatial Variation",
                                    String(
                                        format: "%.2f dB",
                                        report.meanSpatialDeviationDB
                                    )
                                )
                            }
                            if report.fallbackUsed {
                                Label(
                                    "Conservative fallback shaping is active because measurement confidence is limited.",
                                    systemImage:
                                        "shield.lefthalf.filled"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            ForEach(
                                Array(report.warnings.enumerated()),
                                id: \.offset
                            ) { _, warning in
                                Label(
                                    warning,
                                    systemImage:
                                        "exclamationmark.triangle"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(4)
                }

                if let design = calibration.latestDesign {
                    HStack(spacing: 24) {
                        status("Speakers", "\(design.summary.speakerCount)")
                        status("Subs", "\(design.summary.subwooferCount)")
                        status("Seats", "\(design.summary.seatCount)")
                        status("Target", design.summary.targetName)
                    }
                    HStack(spacing: 24) {
                        status(
                            "Designer Worst RMS Before",
                            design.summary.maximumSpeakerErrorBeforeDB.map { String(format: "%.2f dB", $0) } ?? "—"
                        )
                        status(
                            "Designer Worst RMS After",
                            design.summary.maximumSpeakerErrorAfterDB.map { String(format: "%.2f dB", $0) } ?? "—"
                        )
                        status(
                            "Multi-Sub Objective",
                            design.summary.multiSubObjective.map { String(format: "%.3f", $0) } ?? "—"
                        )
                    }
                }

                if let prediction = calibration.latestPrediction {
                    Divider()
                    HStack(spacing: 10) {
                        Label(
                            prediction.accepted
                                ? "Prediction Verified"
                                : "Prediction Blocked",
                            systemImage: prediction.accepted
                                ? "checkmark.shield.fill"
                                : "exclamationmark.shield.fill"
                        )
                        .font(.callout.bold())
                        .foregroundStyle(
                            prediction.accepted ? .green : .red
                        )
                        Spacer()
                        Text(
                            "Confidence \(Int((prediction.confidence * 100).rounded()))%"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 24) {
                        status(
                            "Independent RMS Before",
                            String(
                                format: "%.2f dB",
                                prediction.speakerRMSErrorBeforeDB
                            )
                        )
                        status(
                            "Independent RMS After",
                            String(
                                format: "%.2f dB",
                                prediction.speakerRMSErrorAfterDB
                            )
                        )
                        status(
                            "Predicted Improvement",
                            String(
                                format: "%+.2f dB",
                                prediction.speakerImprovementDB
                            )
                        )
                        status(
                            "Max Residual",
                            String(
                                format: "%.2f dB",
                                prediction.maximumAbsoluteErrorAfterDB
                            )
                        )
                    }

                    HStack(spacing: 24) {
                        status(
                            "Worst Level Spread",
                            String(
                                format: "%.2f → %.2f dB",
                                prediction.maximumSpeakerLevelSpreadBeforeDB,
                                prediction.maximumSpeakerLevelSpreadAfterDB
                            )
                        )
                        status(
                            "Worst Timing Spread",
                            String(
                                format: "%.2f → %.2f ms",
                                prediction.maximumSpeakerTimingSpreadBeforeMs,
                                prediction.maximumSpeakerTimingSpreadAfterMs
                            )
                        )
                        if let before = prediction.subCombinedRMSErrorBeforeDB,
                           let after = prediction.subCombinedRMSErrorAfterDB {
                            status(
                                "Summed Subs",
                                String(
                                    format: "%.2f → %.2f dB RMS",
                                    before,
                                    after
                                )
                            )
                        }
                    }

                    if !prediction.blockingReasons.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(
                                Array(
                                    prediction.blockingReasons.enumerated()
                                ),
                                id: \.offset
                            ) { _, reason in
                                Label(
                                    reason,
                                    systemImage:
                                        "xmark.octagon.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                        }
                    }
                    if !prediction.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(
                                Array(prediction.warnings.enumerated()),
                                id: \.offset
                            ) { _, warning in
                                Label(
                                    warning,
                                    systemImage:
                                        "exclamationmark.triangle"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button("Generate Design") {
                        actionError = nil
                        Task {
                            do { _ = try await calibration.designCalibration() }
                            catch { actionError = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!calibration.campaignComplete || calibration.state == .measuring || calibration.state == .analyzing)

                    Button("Deploy to Playback System") {
                        perform { try calibration.deployLatestDesign() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        calibration.latestDesign == nil
                            || calibration.latestPrediction?.accepted != true
                            || engine.lifecycleState != .idle
                    )
                }
            }
            .padding(6)
        }
    }

    private var campaignProgress: Double {
        calibration.state == .measuring
            ? calibration.measurementProgress
            : calibration.measurementProgress
    }

    private var permissionLabel: String {
        switch microphone.permissionStatus {
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        }
    }

    private var stateBadge: some View {
        Text(calibration.state.rawValue.capitalized)
            .font(.caption.bold())
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }

    private func hasMeasurement(
        seat: MultichannelCalibrationSeat,
        source: MultichannelCalibrationSource
    ) -> Bool {
        calibration.measurements.contains {
            $0.seatID == seat.id && $0.source == source
        }
    }

    private func status(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).lineLimit(1)
        }
    }

    private func perform(_ operation: () throws -> Void) {
        actionError = nil
        do { try operation() }
        catch { actionError = error.localizedDescription }
    }
}
