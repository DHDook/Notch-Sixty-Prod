import SwiftUI
import UniformTypeIdentifiers

// E12 S3: the guided-setup window and its steps. E12 S29: the frame around the steps (step list, time remaining,
// Close and continue later, Cancel confirmation, restore-failure dialog, summary page). Each step is in its own file
// under `UI/SystemSetup`, and the model is `SystemSetupFlowModel`.

/// Where the summary page sends the user once the sheet closes.
enum SystemSetupExit: Equatable {
    case listen, fullSettings, roomAdvisor
}

struct ProductionSystemSetupFlowView: View {
    @StateObject private var model: SystemSetupFlowModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingCancel = false

    private let preset: SystemSetupPreset
    private let onExit: (SystemSetupExit) -> Void

    init(engine: AudioIOEngine, profiles: ProductProfileController,
         microphone: RoomCorrectionCalibrationController, calibration: MultichannelCalibrationController,
         advisor: RoomTreatmentAdvisorController, preset: SystemSetupPreset = .full,
         onExit: @escaping (SystemSetupExit) -> Void = { _ in }) {
        self.preset = preset
        self.onExit = onExit
        _model = StateObject(wrappedValue: SystemSetupFlowModel(
            engine: engine, profiles: profiles, microphone: microphone, calibration: calibration,
            services: ProductionSystemSetupServices.production(
                engine: engine, profiles: profiles, microphone: microphone, calibration: calibration)))
        self.advisor = advisor
    }

    private let advisor: RoomTreatmentAdvisorController

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if model.summary == nil {
                SystemSetupStepList(model: model)
                Divider()
            }
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { stepContent }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message = model.message {
                    Divider()
                    Text(message).font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 820, minHeight: 540)
        .onAppear { if !model.isRunning { model.begin(preset: preset) } }
        .onDisappear { model.endComparison() }
        .confirmationDialog(
            "Cancel the setup?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Discard my progress and cancel", role: .destructive) { cancelNow() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Your measurements and choices will be thrown away and your earlier settings put back. To keep them, use Close and continue later.")
        }
        .alert("Your earlier settings were not put back", isPresented: Binding(
            get: { model.restoreFailure != nil }, set: { _ in })) {
            Button("OK") { model.restoreFailure = nil; dismiss() }
        } message: {
            Text((model.restoreFailure ?? "") + " Check the Speakers and Room pages before you carry on.")
        }
    }

    private func cancelNow() {
        model.cancel()
        if model.restoreFailure == nil { dismiss() }
    }

    private func closeForLater() {
        model.closeForLater()
        if model.restoreFailure == nil { dismiss() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.summary != nil ? "Your system is set up" : (model.preset == .quick ? "Quick setup" : "Set up my system"))
                .font(.title3.weight(.semibold))
            if model.summary == nil {
                let position = model.stepPosition
                ProgressView(value: Double(position.position), total: Double(position.total))
                HStack {
                    Text("Step \(position.position) of \(position.total): \(Self.title(model.step))")
                    Spacer()
                    Text(model.timeRemainingText)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var footer: some View {
        Group {
            if model.summary != nil {
                HStack {
                    Button("Done") { dismiss() }
                    Spacer()
                    if model.quickFinished {
                        Button("Open the full setup") { model.beginFullAfterQuick() }.keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { leaveButtons; primaryButtons }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) { leaveButtons }
                        HStack(spacing: 8) { primaryButtons }
                    }
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var leaveButtons: some View {
        Button("Cancel", role: .cancel) {
            if model.cancelNeedsConfirmation { confirmingCancel = true } else { cancelNow() }
        }
        Button("Close and continue later") { closeForLater() }
            .help("Puts your earlier settings back and keeps your measurements. Set Up My System resumes where you left off.")
        if model.preset == .quick {
            Button("Switch to full setup") { model.openFullSetup() }
                .help("Adds the Speakers and Room steps and more seats. Nothing you have chosen changes.")
        }
    }

    @ViewBuilder
    private var primaryButtons: some View {
        Spacer(minLength: 8)
        if let reason = model.nextBlockedReason {
            Text(reason).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320, alignment: .trailing)
        }
        Button("Back") { model.back() }.disabled(model.step == model.visibleSteps.first)
        if model.flow.canSkip(model.step) {
            Button("Skip") { model.skip() }
        }
        if model.step == .save {
            Button("Save") { model.save() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.nextBlockedReason != nil)
        } else {
            Button("Next") { model.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(!SystemSetupFlowModel.builtSteps.contains(model.step) || model.nextBlockedReason != nil)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        if let summary = model.summary {
            SystemSetupSummaryPage(model: model, summary: summary) { exit in
                onExit(exit)
                dismiss()
            }
        } else {
            stepBody
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch model.step {
        case .output: SystemSetupOutputStep(model: model)
        case .topology: SystemSetupSpeakersStep(model: model)
        case .microphone: SystemSetupMicrophoneStep(model: model)
        case .measure: SystemSetupMeasureStep(model: model)
        case .alignment: SystemSetupAlignmentStep(model: model)
        case .bass: SystemSetupBassStep(model: model)
        case .correction: SystemSetupCorrectionStep(model: model)
        case .verify: SystemSetupVerifyStep(model: model)
        case .save: SystemSetupSaveStep(model: model)
        case .room:
            Text("Optional. Describe the room so seat and speaker suggestions can pre-fill the next steps, or skip.")
                .foregroundStyle(.secondary)
            ProductionRoomGeometrySection(advisor: advisor)
        }
    }

    static func title(_ step: SystemSetupStep) -> String {
        switch step {
        case .output: return "Output"
        case .topology: return "Speakers"
        case .microphone: return "Microphone and level"
        case .room: return "Room"
        case .measure: return "Measure seats"
        case .alignment: return "Alignment"
        case .bass: return "Bass"
        case .correction: return "Correction"
        case .verify: return "Verify"
        case .save: return "Save"
        }
    }
}
