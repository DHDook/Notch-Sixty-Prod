import SwiftUI

struct ProductionMultichannelCalibrationWorkspace: View {
    var engine: AudioIOEngine
    @ObservedObject var calibration: MultichannelCalibrationController
    @ObservedObject var microphone: RoomCorrectionCalibrationController
    @ObservedObject var profiles: ProductProfileController
    @StateObject private var optimizer: SpeakerOptimizerMeasurementController
    @StateObject private var characterization: SpeakerOptimizerCharacterizationController
    @StateObject private var guidedOptimizer: SpeakerOptimizerGuidedPEQController
    @StateObject private var verification: SpeakerOptimizerVerificationController
    @StateObject private var guidedFIR: SpeakerOptimizerGuidedFIRController
    @StateObject private var firVerification: SpeakerOptimizerFIRVerificationController

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
        self.engine = engine
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
        _guidedOptimizer = StateObject(
            wrappedValue: SpeakerOptimizerGuidedPEQController(
                profileStore: profiles
            )
        )
        _verification = StateObject(
            wrappedValue: SpeakerOptimizerVerificationController(
                engine: engine,
                profiles: profiles,
                microphone: microphone
            )
        )
        _guidedFIR = StateObject(
            wrappedValue: SpeakerOptimizerGuidedFIRController.production(engine: engine, profileStore: profiles)
        )
        _firVerification = StateObject(
            wrappedValue: SpeakerOptimizerFIRVerificationController(
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
        ProductionPageContainer {
            VStack(alignment: .leading, spacing: DesignSpacing.xl.pt) {
                header
                systemCard
                microphoneCard
                seatsCard
                campaignCard
                speakerOptimizerCard
                speakerCharacterizationCard
                speakerOptimizerCommissioningCard
                SpeakerOptimizerFIRCommissioningCard(
                    engine: engine,
                    guided: guidedFIR,
                    verification: firVerification,
                    baseline: optimizer.measurementSet,
                    characterization: characterization.measurementSet,
                    inputsReady: optimizer.evidenceReport?.optimizerReady == true && characterization.characterizationReady,
                    otherDeploymentActive: guidedOptimizer.state == .appliedPendingVerification)
                designCard

                if let error = actionError
                    ?? verification.lastErrorDescription
                    ?? guidedOptimizer.lastErrorDescription
                    ?? characterization.lastErrorDescription
                    ?? optimizer.lastErrorDescription
                    ?? calibration.lastErrorDescription
                    ?? microphone.lastErrorDescription {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(DesignType.label.font)
                        .foregroundStyle(StatusLevel.problem.color)
                        .textSelection(.enabled)
                        .padding(DesignSpacing.l.pt)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt))
                }
            }
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
        .task(id: verification.state) {
            guard verification.state == .measuring else { return }
            while !Task.isCancelled && verification.state == .measuring {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                do {
                    if try await verification.finishMeasurementIfComplete() {
                        break
                    }
                } catch {
                    actionError = error.localizedDescription
                    break
                }
            }
        }
        .task(id: verification.verificationReport?.verificationMeasurementSetID) {
            guard let report = verification.verificationReport else { return }
            do {
                try guidedOptimizer.recordVerification(report)
            } catch {
                actionError = error.localizedDescription
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
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text("Measure every physical speaker and subwoofer at each listening seat, then generate level, polarity, timing and bounded attenuation-only EQ for the selected Playback System.")
                .foregroundStyle(.secondary)
        }
    }

    private var systemCard: some View {
        GroupBox("Playback System") {
            VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                if let profile = calibration.profile {
                    HStack(spacing: DesignSpacing.xl.pt) {
                        status("System", profiles.selectedSystemProfileName)
                        status("Physical Layout", profile.systemDisplayName)
                        status("Program Layout", profile.programLayout.displayName)
                        status("Sources", "\(calibration.sources.count)")
                    }
                    HStack(spacing: DesignSpacing.xl.pt) {
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
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "Enable and fully map an Output Device Profile for this Playback System before calibrating speakers.",
                        systemImage: "speaker.slash"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(DesignSpacing.s.pt)
        }
    }

    private var microphoneCard: some View {
        GroupBox("Measurement Microphone") {
            VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                MeasurementMicrophoneCard(
                    microphone: microphone,
                    locked: calibration.state == .measuring || calibration.state == .analyzing,
                    onError: { actionError = $0 })

                Text("Normal DSP playback must be stopped during acoustic measurement. The measurement transport owns the output hardware temporarily and zeros every non-target output lane before each sweep.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
            .padding(DesignSpacing.s.pt)
        }
    }

    private var seatsCard: some View {
        GroupBox("Listening Seats") {
            MeasurementSeatsCard(
                calibration: calibration, microphone: microphone,
                locked: calibration.state == .measuring || calibration.state == .analyzing,
                editsDetails: true,
                onAdd: { perform { try calibration.addSeat() } },
                onRemove: { id in perform { try calibration.removeSeat(id) } },
                onUpdate: { id, name, included, weight in
                    perform { try calibration.updateSeat(id, name: name, included: included, weight: weight) }
                },
                accessory: { _ in EmptyView() })
                .padding(DesignSpacing.s.pt)
        }
    }

    private var campaignCard: some View {
        GroupBox("Measurement Campaign") {
            VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                        Text("\(calibration.completedMeasurementCount) of \(calibration.totalMeasurementCount) measurements")
                            .font(DesignType.sectionTitle.font)
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

                HStack(spacing: DesignSpacing.m.pt) {
                    Button(calibration.campaignComplete ? "Campaign Complete" : "Measure Next") {
                        perform { try calibration.beginNextMeasurement() }
                    }
                    .buttonStyle(.glassProminent)
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
                MeasurementReadinessNote(readiness: calibration.readiness, playbackNotice: calibration.playbackNotice)

                if !calibration.sources.isEmpty && !calibration.seats.isEmpty {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                        GridRow {
                            Text("Seat").font(DesignType.caption.font.bold())
                            Text("Source").font(DesignType.caption.font.bold())
                            Text("Status").font(DesignType.caption.font.bold())
                        }
                        ForEach(calibration.seats.filter(\.included)) { seat in
                            ForEach(Array(calibration.sources.enumerated()), id: \.offset) { _, source in
                                GridRow {
                                    Text(seat.name)
                                    Text(source.displayName)
                                    if hasMeasurement(seat: seat, source: source) {
                                        Label("Measured", systemImage: "checkmark.circle.fill")
                                            .foregroundStyle(StatusLevel.good.color)
                                    } else {
                                        Text("Pending").foregroundStyle(.secondary)
                                    }
                                }
                                .font(DesignType.caption.font)
                            }
                        }
                    }
                }
            }
            .padding(DesignSpacing.s.pt)
        }
    }

    private var speakerOptimizerCard: some View {
        GroupBox("Speaker Optimizer Measurements") {
            VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
                HStack(alignment: .top, spacing: DesignSpacing.l.pt) {
                    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                        Text("Repeated acoustic evidence")
                            .font(DesignType.sectionTitle.font)
                        Text(
                            "Build a baseline from repeated isolated speaker/sub sweeps. This stage measures only; it does not generate or deploy optimizer filters."
                        )
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(optimizer.state.rawValue.capitalized)
                        .font(DesignType.caption.font.bold())
                        .padding(.horizontal, DesignSpacing.s.pt)
                        .padding(.vertical, DesignSpacing.xs.pt)
                        .background(.quaternary, in: Capsule())
                }

                HStack(spacing: DesignSpacing.m.pt) {
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
                    .buttonStyle(.glass)

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

                    HStack(spacing: DesignSpacing.xl.pt) {
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
                        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                            Text(
                                optimizer.state == .measuring
                                    ? "Measuring \(step.displayName)"
                                    : "Next: \(step.displayName)"
                            )
                            .font(DesignType.label.font.bold())
                            Text(
                                "Move the selected microphone to \(step.position.name) and keep its position fixed for all repeats at that position."
                            )
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                        }
                    } else if progress.complete {
                        Label(
                            "All planned repeated sweeps are captured.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(StatusLevel.good.color)
                    }

                    if optimizer.state == .measuring {
                        ProgressView(
                            value: optimizer.activeMeasurementProgress
                        ) {
                            Text("Current optimizer sweep")
                        }
                    }

                    HStack(spacing: DesignSpacing.m.pt) {
                        Button("Measure Next Repeat") {
                            actionError = nil
                            do {
                                try optimizer.beginNextMeasurement()
                            } catch {
                                actionError = error.localizedDescription
                            }
                        }
                        .buttonStyle(.glassProminent)
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
                        HStack(spacing: DesignSpacing.m.pt) {
                            Label(
                                report.optimizerReady
                                    ? "Optimizer-ready evidence"
                                    : "Evidence not optimizer-ready",
                                systemImage: report.optimizerReady
                                    ? "checkmark.shield.fill"
                                    : "exclamationmark.shield.fill"
                            )
                            .font(DesignType.label.font.bold())
                            .foregroundStyle(
                                report.optimizerReady ? .green : .secondary
                            )
                            Spacer()
                            Text(
                                "Confidence \(Int((report.confidence * 100).rounded()))%"
                            )
                            .font(DesignType.caption.font.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }

                        Grid(
                            alignment: .leading,
                            horizontalSpacing: 14,
                            verticalSpacing: 6
                        ) {
                            GridRow {
                                Text("Position").font(DesignType.caption.font.bold())
                                Text("Source").font(DesignType.caption.font.bold())
                                Text("Repeats").font(DesignType.caption.font.bold())
                                Text("SNR").font(DesignType.caption.font.bold())
                                Text("Repeatability").font(DesignType.caption.font.bold())
                                Text("Timing").font(DesignType.caption.font.bold())
                                Text("Phase").font(DesignType.caption.font.bold())
                                Text("Status").font(DesignType.caption.font.bold())
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
                                .font(DesignType.caption.font)
                            }
                        }

                        if !report.blockingReasons.isEmpty {
                            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
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
                                    .font(DesignType.caption.font)
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
                    .font(DesignType.caption.font)
                    .foregroundStyle(StatusLevel.attention.color)
                }

                Text(
                    "Protected Low/Mid/High driver-bus measurements remain blocked in this version. They will not be excited through a raw physical-output bypass; a crossover-preserving protected measurement path is required first."
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            }
            .padding(DesignSpacing.s.pt)
        }
    }


    private var speakerCharacterizationCard: some View {
        GroupBox("Speaker Optimizer · Speaker Characterization") {
            VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
                HStack(alignment: .top, spacing: DesignSpacing.l.pt) {
                    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                        Text("Step 2 · Characterize each whole speaker")
                            .font(DesignType.sectionTitle.font)
                        Text(
                            "After the listening-position baseline qualifies, move the same microphone to the guided ~1 m position for each whole speaker. Three stationary repeats are taken before moving to the next speaker."
                        )
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(characterization.state.rawValue.capitalized)
                        .font(DesignType.caption.font.bold())
                        .padding(.horizontal, DesignSpacing.s.pt)
                        .padding(.vertical, DesignSpacing.xs.pt)
                        .background(.quaternary, in: Capsule())
                }

                if optimizer.evidenceReport?.optimizerReady != true {
                    Label(
                        "Complete an optimizer-ready listening-position baseline above before starting characterization.",
                        systemImage: "1.circle"
                    )
                    .font(DesignType.label.font)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: DesignSpacing.m.pt) {
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
                    .buttonStyle(.glass)
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

                if characterization.measurementSet != nil,
                   let progress = characterization.progress {
                    Divider()

                    HStack(spacing: DesignSpacing.xl.pt) {
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
                        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                            Text(
                                characterization.state == .measuring
                                    ? "Measuring \(step.target.source.displayName)"
                                    : "Next: \(step.target.source.displayName)"
                            )
                            .font(DesignType.label.font.bold())
                            Text(step.instruction)
                                .font(DesignType.caption.font)
                                .foregroundStyle(.secondary)
                            Text(
                                "Do not move the loudspeaker. This installed-room measurement is source-weighted evidence, not an anechoic claim."
                            )
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                        }
                    } else if progress.complete {
                        Label(
                            "All whole-speaker characterization repeats are captured.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(StatusLevel.good.color)
                    }

                    if characterization.state == .measuring {
                        ProgressView(
                            value: characterization.activeMeasurementProgress
                        ) {
                            Text("Current characterization sweep")
                        }
                    }

                    HStack(spacing: DesignSpacing.m.pt) {
                        Button("Measure Next Characterization Repeat") {
                            actionError = nil
                            do {
                                try characterization.beginNextMeasurement()
                            } catch {
                                actionError = error.localizedDescription
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!characterization.canBeginMeasurement)

                        if characterization.state == .measuring
                            || characterization.state == .analyzing {
                            Button("Cancel") {
                                characterization.cancelMeasurement()
                            }
                        }
                    }

                    if let evidence = characterization.evidenceReport {
                        HStack(spacing: DesignSpacing.m.pt) {
                            Label(
                                characterization.characterizationReady
                                    ? "Characterization evidence ready"
                                    : "Characterization not ready",
                                systemImage: characterization.characterizationReady
                                    ? "checkmark.shield.fill"
                                    : "exclamationmark.shield.fill"
                            )
                            .font(DesignType.label.font.bold())
                            .foregroundStyle(
                                characterization.characterizationReady
                                    ? .green : .secondary
                            )
                            Spacer()
                            Text(
                                "Confidence \(Int((evidence.confidence * 100).rounded()))%"
                            )
                            .font(DesignType.caption.font.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }

                    if let report = crossDomainClassificationReport {
                        Divider()
                        let summary =
                            SpeakerOptimizerCrossDomainSummary(report: report)
                        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                            Text("Step 3 · Compare speaker vs room evidence")
                                .font(DesignType.sectionTitle.font)
                            HStack(spacing: DesignSpacing.xl.pt) {
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
                                    Text("Source").font(DesignType.caption.font.bold())
                                    Text("Speaker-persistent")
                                        .font(DesignType.caption.font.bold())
                                    Text("Room / seat")
                                        .font(DesignType.caption.font.bold())
                                    Text("Ambiguous").font(DesignType.caption.font.bold())
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
                                    .font(DesignType.caption.font)
                                }
                            }

                            Text(
                                "Only speaker-persistent regions may drive the guided PEQ/FIR speaker-correction path. Room/seat-dependent, ambiguous, flat, below-window and unclassified regions remain protected."
                            )
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Text(
                    "Subwoofers remain in the listening-position integration campaign. Protected Low/Mid/High driver buses still require a crossover-preserving measurement path and are not directly swept."
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            }
            .padding(DesignSpacing.s.pt)
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


    private var speakerOptimizerCommissioningCard: some View {
        GroupBox("Speaker Optimizer · Commission & Verify") {
            VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
                HStack(alignment: .top, spacing: DesignSpacing.l.pt) {
                    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                        Text("Step 4 · Review and apply bounded PEQ")
                            .font(DesignType.sectionTitle.font)
                        Text(
                            "Generate a cut-only PEQ proposal from the qualified listening baseline plus speaker characterization. Apply is an explicit user action and is provisional until new microphone verification passes."
                        )
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(guidedOptimizer.state.rawValue)
                        .font(DesignType.caption.font.bold())
                        .padding(.horizontal, DesignSpacing.s.pt)
                        .padding(.vertical, DesignSpacing.xs.pt)
                        .background(.quaternary, in: Capsule())
                }

                Button("Generate PEQ Proposal") {
                    actionError = nil
                    do {
                        guard let baseline = optimizer.measurementSet,
                              let characterizationSet =
                                characterization.measurementSet else {
                            throw SpeakerOptimizerGuidedPEQError
                                .reviewRequired
                        }
                        try guidedOptimizer.prepareReview(
                            baseline: baseline,
                            characterization: characterizationSet
                        )
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
                .buttonStyle(.glass)
                .disabled(
                    optimizer.evidenceReport?.optimizerReady != true
                        || !characterization.characterizationReady
                        || guidedOptimizer.state
                            == .appliedPendingVerification
                        || guidedOptimizer.state == .measuredAccepted
                        || guidedOptimizer.state == .measuredRejected
                        || guidedFIR.state == .appliedPendingVerification
                )

                if let proposal = guidedOptimizer.proposal,
                   let plan = guidedOptimizer.plan {
                    Divider()
                    HStack(spacing: DesignSpacing.xl.pt) {
                        status("Sources", "\(proposal.sources.count)")
                        status(
                            "PEQ Bands",
                            "\(guidedOptimizer.candidateBandCount)"
                        )
                        status(
                            "Apply Stage",
                            proposal.canApply ? "Available" : "Blocked"
                        )
                        status(
                            "Confidence",
                            "\(Int((plan.candidate.evidenceConfidence * 100).rounded()))%"
                        )
                    }

                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 16,
                        verticalSpacing: 6
                    ) {
                        GridRow {
                            Text("Source").font(DesignType.caption.font.bold())
                            Text("Bands").font(DesignType.caption.font.bold())
                            Text("Max Cut").font(DesignType.caption.font.bold())
                            Text("Status").font(DesignType.caption.font.bold())
                        }
                        ForEach(
                            Array(plan.candidate.sources.enumerated()),
                            id: \.offset
                        ) { _, candidate in
                            GridRow {
                                Text(candidate.source.displayName)
                                Text("\(candidate.bands.count)")
                                Text(
                                    candidate.bands.map(\.gainDB).min().map {
                                        String(format: "%.1f dB", $0)
                                    } ?? "—"
                                )
                                Text(
                                    candidate.bands.isEmpty
                                        ? "Bypass"
                                        : "Speaker-persistent only"
                                )
                            }
                            .font(DesignType.caption.font)
                        }
                    }

                    if guidedOptimizer.applyReceipt == nil {
                        HStack(spacing: DesignSpacing.m.pt) {
                            Button("Approve & Apply PEQ") {
                                actionError = nil
                                do {
                                    try guidedOptimizer.approveAndApply(
                                        userInitiated: true
                                    )
                                } catch {
                                    actionError =
                                        error.localizedDescription
                                }
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(
                                !guidedOptimizer.canApproveAndApply
                            )

                            Text(
                                engine.lifecycleState == .idle
                                    ? "DSP is stopped; Apply is available after review."
                                    : "Stop DSP playback before Apply."
                            )
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if let receipt = guidedOptimizer.applyReceipt,
                   let plan = guidedOptimizer.plan,
                   let baseline = optimizer.measurementSet {
                    Divider()
                    Label(
                        guidedOptimizer.state == .measuredAccepted
                            ? "Measured verification accepted — deployment verified"
                            : guidedOptimizer.state == .rolledBack
                                && guidedOptimizer.verificationReport?.accepted == false
                                ? "Measured verification failed — PEQ rolled back automatically"
                                : guidedOptimizer.state == .measuredRejected
                                    ? "Measured verification failed — rollback blocked"
                                    : "PEQ applied provisionally — measured verification required",
                        systemImage:
                            guidedOptimizer.state == .measuredAccepted
                                ? "checkmark.shield.fill"
                                : guidedOptimizer.state == .measuredRejected
                                    || (guidedOptimizer.state == .rolledBack
                                        && guidedOptimizer.verificationReport?.accepted == false)
                                    ? "exclamationmark.shield.fill"
                                    : "waveform.badge.magnifyingglass"
                    )
                    .font(DesignType.label.font.bold())
                    .foregroundStyle(
                        guidedOptimizer.state == .measuredAccepted
                            ? .green
                            : guidedOptimizer.state == .measuredRejected
                                || (guidedOptimizer.state == .rolledBack
                                    && guidedOptimizer.verificationReport?.accepted == false)
                                ? .red
                                : .orange
                    )

                    Text("Step 5 · Re-measure the original listening positions")
                        .font(DesignType.sectionTitle.font)

                    HStack(spacing: DesignSpacing.m.pt) {
                        Button(
                            verification.measurementSet == nil
                                ? "Start Verification"
                                : "Refresh / Resume Verification"
                        ) {
                            actionError = nil
                            do {
                                try verification.startOrResume(
                                    baseline: baseline,
                                    plan: plan,
                                    receipt: receipt
                                )
                            } catch {
                                actionError =
                                    error.localizedDescription
                            }
                        }
                        .buttonStyle(.glass)
                        .disabled(
                            guidedOptimizer.state == .measuredAccepted
                                || guidedOptimizer.state == .measuredRejected
                                || guidedOptimizer.state == .rolledBack
                        )

                        Button("Rollback PEQ", role: .destructive) {
                            actionError = nil
                            do {
                                verification.cancelMeasurement()
                                try guidedOptimizer.rollback()
                            } catch {
                                actionError =
                                    error.localizedDescription
                            }
                        }
                        .disabled(!guidedOptimizer.canRollback)
                    }

                    if let verificationSet =
                            verification.measurementSet,
                       let progress = verification.progress {
                        HStack(spacing: DesignSpacing.xl.pt) {
                            status(
                                "Verification Repeats",
                                "\(progress.completedSweepCount) / \(progress.requiredSweepCount)"
                            )
                            status(
                                "Evidence",
                                verification.evidenceReport.map {
                                    $0.optimizerReady ? "Qualified" : "Pending"
                                } ?? "Pending"
                            )
                            status(
                                "Confidence",
                                verification.evidenceReport.map {
                                    "\(Int(($0.confidence * 100).rounded()))%"
                                } ?? "—"
                            )
                        }
                        ProgressView(value: progress.fractionComplete)

                        if let step = verification.activeOrNextStep {
                            Text(
                                verification.state == .measuring
                                    ? "Measuring \(step.displayName)"
                                    : "Next: \(step.displayName)"
                            )
                            .font(DesignType.label.font.bold())
                            Text(
                                "Return the same calibrated microphone to \(step.position.name) and keep it fixed for the repeated sweeps."
                            )
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                        } else if progress.complete {
                            Label(
                                "Fresh verification capture campaign complete.",
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(StatusLevel.good.color)
                        }

                        if verification.state == .measuring {
                            ProgressView(
                                value:
                                    verification.activeMeasurementProgress
                            ) {
                                Text("Current verification sweep")
                            }
                        }

                        HStack(spacing: DesignSpacing.m.pt) {
                            Button("Measure Next Verification Repeat") {
                                actionError = nil
                                do {
                                    try verification.beginNextMeasurement()
                                } catch {
                                    actionError =
                                        error.localizedDescription
                                }
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(
                                !verification.canBeginMeasurement
                                    || guidedOptimizer.state
                                        != .appliedPendingVerification
                            )

                            if verification.state == .measuring
                                || verification.state == .analyzing {
                                Button("Cancel") {
                                    verification.cancelMeasurement()
                                }
                            }

                            if !verificationSet.captures.isEmpty {
                                Button(
                                    "Reset Verification",
                                    role: .destructive
                                ) {
                                    actionError = nil
                                    do {
                                        try verification
                                            .resetVerification()
                                    } catch {
                                        actionError =
                                            error.localizedDescription
                                    }
                                }
                                .disabled(
                                    verification.state == .measuring
                                        || verification.state
                                            == .analyzing
                                        || guidedOptimizer.state
                                            != .appliedPendingVerification
                                )
                            }
                        }
                    }

                    if let report = verification.verificationReport {
                        Divider()
                        HStack(spacing: DesignSpacing.m.pt) {
                            Label(
                                report.accepted
                                    ? "Measured acceptance passed"
                                    : "Measured acceptance failed",
                                systemImage: report.accepted
                                    ? "checkmark.shield.fill"
                                    : "exclamationmark.shield.fill"
                            )
                            .font(DesignType.label.font.bold())
                            .foregroundStyle(
                                report.accepted ? .green : .red
                            )
                            Spacer()
                            Text(
                                report.shouldRollback
                                    ? (guidedOptimizer.state == .rolledBack
                                        ? "Rollback completed"
                                        : "Rollback blocked")
                                    : (guidedOptimizer.verificationFinalizationReceipt != nil
                                        ? "Verified & persisted"
                                        : "Verification finalization pending")
                            )
                            .font(DesignType.caption.font.bold())
                        }

                        Grid(
                            alignment: .leading,
                            horizontalSpacing: 14,
                            verticalSpacing: 6
                        ) {
                            GridRow {
                                Text("Source").font(DesignType.caption.font.bold())
                                Text("Filter tracking")
                                    .font(DesignType.caption.font.bold())
                                Text("Persistent improvement")
                                    .font(DesignType.caption.font.bold())
                                Text("Protected regression")
                                    .font(DesignType.caption.font.bold())
                                Text("Result").font(DesignType.caption.font.bold())
                            }
                            ForEach(
                                Array(report.sources.enumerated()),
                                id: \.offset
                            ) { _, source in
                                GridRow {
                                    Text(source.source.displayName)
                                    Text(
                                        String(
                                            format: "%.2f dB",
                                            source.filterTrackingRMSDB
                                        )
                                    )
                                    Text(
                                        String(
                                            format: "%+.2f dB",
                                            source.persistentImprovementDB
                                        )
                                    )
                                    Text(
                                        String(
                                            format: "%+.2f dB",
                                            source.protectedRegressionDB
                                        )
                                    )
                                    Text(
                                        source.accepted
                                            ? "Accepted"
                                            : "Rejected"
                                    )
                                    .foregroundStyle(
                                        source.accepted
                                            ? .green : .red
                                    )
                                }
                                .font(DesignType.caption.font)
                            }
                        }
                    }
                }

                Text(
                    "FIR deployment and crossover timing/polarity remain blocked. PEQ acceptance here verifies measured magnitude behavior only."
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            }
            .padding(DesignSpacing.s.pt)
        }
    }

    private var designCard: some View {
        GroupBox("Calibration Design") {
            VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
                Text("The product deployment is intentionally headroom-safe: speaker trims, speaker EQ, sub gain and sub EQ are attenuation-only. Timing and polarity remain fully available, and multi-sub relative relationships are preserved without positive digital gain.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)

                GroupBox("Adaptive Target") {
                    VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                        HStack(spacing: DesignSpacing.m.pt) {
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
                            .buttonStyle(.glass)
                            .disabled(!calibration.campaignComplete)

                            if calibration.intelligentTargetReport != nil {
                                Button("Use Flat") {
                                    calibration.clearIntelligentTarget()
                                }
                                .buttonStyle(.glass)
                            }
                        }

                        Text(
                            "Uses the completed full-range speaker measurements across all included seats. Subwoofer measurements do not shape the broadband target. The resulting curve is still independently checked when the calibration design is generated."
                        )
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)

                        if let report =
                            calibration.intelligentTargetReport {
                            HStack(spacing: DesignSpacing.xl.pt) {
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
                            HStack(spacing: DesignSpacing.xl.pt) {
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
                                .font(DesignType.caption.font)
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
                                .font(DesignType.caption.font)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(DesignSpacing.xs.pt)
                }

                if let design = calibration.latestDesign {
                    HStack(spacing: DesignSpacing.xl.pt) {
                        status("Speakers", "\(design.summary.speakerCount)")
                        status("Subs", "\(design.summary.subwooferCount)")
                        status("Seats", "\(design.summary.seatCount)")
                        status("Target", design.summary.targetName)
                    }
                    HStack(spacing: DesignSpacing.xl.pt) {
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
                    HStack(spacing: DesignSpacing.m.pt) {
                        Label(
                            prediction.accepted
                                ? "Prediction Verified"
                                : "Prediction Blocked",
                            systemImage: prediction.accepted
                                ? "checkmark.shield.fill"
                                : "exclamationmark.shield.fill"
                        )
                        .font(DesignType.label.font.bold())
                        .foregroundStyle(
                            prediction.accepted ? .green : .red
                        )
                        Spacer()
                        Text(
                            "Confidence \(Int((prediction.confidence * 100).rounded()))%"
                        )
                        .font(DesignType.caption.font.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: DesignSpacing.xl.pt) {
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

                    HStack(spacing: DesignSpacing.xl.pt) {
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
                        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
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
                                .font(DesignType.caption.font)
                                .foregroundStyle(StatusLevel.problem.color)
                            }
                        }
                    }
                    if !prediction.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                            ForEach(
                                Array(prediction.warnings.enumerated()),
                                id: \.offset
                            ) { _, warning in
                                Label(
                                    warning,
                                    systemImage:
                                        "exclamationmark.triangle"
                                )
                                .font(DesignType.caption.font)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack(spacing: DesignSpacing.m.pt) {
                    Button("Generate Design") {
                        actionError = nil
                        Task {
                            do { _ = try await calibration.designCalibration() }
                            catch { actionError = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(!calibration.campaignComplete || calibration.state == .measuring || calibration.state == .analyzing)

                    Button("Deploy to Playback System") {
                        perform { try calibration.deployLatestDesign() }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(
                        calibration.latestDesign == nil
                            || calibration.latestPrediction?.accepted != true
                            || engine.lifecycleState != .idle
                    )
                }
            }
            .padding(DesignSpacing.s.pt)
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
            .font(DesignType.caption.font.bold())
            .padding(.horizontal, DesignSpacing.s.pt)
            .padding(.vertical, DesignSpacing.xs.pt)
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
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            Text(label).font(DesignType.caption.font).foregroundStyle(.secondary)
            Text(value).font(DesignType.label.font).lineLimit(1)
        }
    }

    private func perform(_ operation: () throws -> Void) {
        actionError = nil
        do { try operation() }
        catch { actionError = error.localizedDescription }
    }
}
