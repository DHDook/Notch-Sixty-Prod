import SwiftUI

/// What the A/V-sync check says about a reviewed FIR plan, in words (E24 S12, closes E28 G44 and E24 G3).
struct SpeakerOptimizerFIRAVSyncVerdict: Equatable {
    var title: String
    var detail: String
    var allowed: Bool
    var programPathLatencyText: String
    var requiredVideoDelayText: String

    init(_ decision: SpeakerOptimizerFIRAVSyncDecision) {
        allowed = decision.canUseFIRForContext
        switch decision.status {
        case .audioOnlyAllowed: title = "Audio only: allowed"
        case .externalVideoDelayAvailable: title = "Synchronized video: allowed with external delay"
        case .externalVideoDelayRequired: title = "Synchronized video: blocked"
        case .externalVideoDelayInsufficient: title = "Synchronized video: delay capacity too small"
        }
        detail = decision.explanation
        programPathLatencyText = String(
            format: "%.2f ms (%llu frames)",
            Double(decision.programPathLatencyFrames) / decision.sampleRate * 1_000, decision.programPathLatencyFrames)
        requiredVideoDelayText = String(format: "%.2f ms", decision.requiredVideoDelayMilliseconds)
    }
}

/// Step 4b of the Speaker Optimizer: review, A/V-sync verdict, Apply, Rollback and measured verification of the FIR
/// proposal. Constructed by `ProductionMultichannelCalibrationWorkspace`, which builds the controller with
/// `SpeakerOptimizerGuidedFIRController.production` so the verdict counts the engine's live dynamics lookahead.
struct SpeakerOptimizerFIRCommissioningCard: View {
    var engine: AudioIOEngine
    @ObservedObject var guided: SpeakerOptimizerGuidedFIRController
    @ObservedObject var verification: SpeakerOptimizerFIRVerificationController
    var baseline: SpeakerOptimizerMeasurementSet?
    var characterization: SpeakerOptimizerCharacterizationMeasurementSet?
    var inputsReady: Bool
    /// True while the PEQ deployment is provisional, so FIR cannot be proposed on top of it.
    var otherDeploymentActive: Bool

    @State private var syncVideo = false
    @State private var videoCapacityText = ""
    @State private var actionError: String?

    private var context: SpeakerOptimizerFIRAVSyncContext {
        syncVideo
            ? .synchronizedVideo(externalVideoDelayCapacityMilliseconds: Double(videoCapacityText))
            : .audioOnly
    }

    var body: some View {
        GroupBox("Speaker Optimizer · FIR (linear phase)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Step 4b · Review and apply FIR").font(.headline)
                        Text("FIR adds audio-path latency. Review the headroom and the A/V-sync verdict before Apply; Apply is provisional until measured verification passes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(guided.state.rawValue).font(.caption.bold())
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }

                Toggle("Used with synchronized video", isOn: $syncVideo)
                    .onChange(of: syncVideo) { _, _ in refreshContext() }
                if syncVideo {
                    TextField("External video-delay capacity (ms)", text: $videoCapacityText)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        .onSubmit { refreshContext() }
                    Text("Notch Sixty does not delay video. Declare the delay your player, AVR or display can add.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Button("Generate FIR Proposal") {
                    perform {
                        guard let baseline, let characterization else {
                            throw SpeakerOptimizerGuidedFIRError.reviewRequired
                        }
                        try guided.prepareReview(
                            baseline: baseline, characterization: characterization, avSyncContext: context)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!inputsReady || otherDeploymentActive || (guided.applyReceipt != nil && guided.state != .rolledBack))

                if let proposal = guided.proposal {
                    Divider()
                    HStack(spacing: 22) {
                        item("Taps", "\(guided.candidateTapCount)")
                        item("Headroom", String(format: "%.1f dB", guided.requiredHeadroomDB))
                        item("Added FIR latency", String(format: "%.2f ms", guided.addedFIRLatencyMilliseconds))
                        item("Apply Stage", proposal.canApply ? "Available" : "Blocked")
                    }
                    if let decision = guided.avSyncDecision {
                        let verdict = SpeakerOptimizerFIRAVSyncVerdict(decision)
                        Label(verdict.title, systemImage: verdict.allowed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.callout.bold()).foregroundStyle(verdict.allowed ? .green : .orange)
                        HStack(spacing: 22) {
                            item("Program-path latency", verdict.programPathLatencyText)
                            item("Required video delay", verdict.requiredVideoDelayText)
                        }
                        Text(verdict.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if guided.applyReceipt == nil {
                        HStack(spacing: 10) {
                            Button("Approve & Apply FIR") {
                                perform { try guided.approveAndApply(userInitiated: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!guided.canApproveAndApply)
                            Text(engine.lifecycleState == .idle
                                 ? "DSP is stopped; Apply is available after review."
                                 : "Stop DSP playback before Apply.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let receipt = guided.applyReceipt, let plan = guided.plan, let baseline {
                    Divider()
                    Text(guided.state == .measuredAccepted
                         ? "Measured verification accepted: FIR verified"
                         : guided.state == .rolledBack
                            ? "FIR rolled back"
                            : guided.state == .measuredRejected
                                ? "Measured verification failed: rollback blocked"
                                : "FIR applied provisionally: measured verification required")
                        .font(.callout.bold())
                    HStack(spacing: 10) {
                        Button(verification.measurementSet == nil ? "Start Verification" : "Refresh / Resume Verification") {
                            perform { try verification.startOrResume(baseline: baseline, plan: plan, receipt: receipt) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(guided.state != .appliedPendingVerification)
                        Button("Measure Next Verification Repeat") {
                            perform { try verification.beginNextMeasurement() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!verification.canBeginMeasurement || guided.state != .appliedPendingVerification)
                        Button("Rollback FIR", role: .destructive) {
                            perform {
                                verification.cancelMeasurement()
                                try guided.rollback()
                            }
                        }
                        .disabled(!guided.canRollback)
                    }
                    if let progress = verification.progress {
                        ProgressView(value: progress.fractionComplete) {
                            Text("Verification repeats \(progress.completedSweepCount) / \(progress.requiredSweepCount)")
                        }
                    }
                }

                if let error = actionError ?? guided.lastErrorDescription ?? verification.lastErrorDescription {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(6)
        }
        .task(id: verification.state) {
            guard verification.state == .measuring else { return }
            while !Task.isCancelled && verification.state == .measuring {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                do { if try await verification.finishMeasurementIfComplete() { break } }
                catch { actionError = error.localizedDescription; break }
            }
        }
        .task(id: verification.verificationReport?.verificationMeasurementSetID) {
            guard let report = verification.verificationReport else { return }
            perform { try guided.recordVerification(report) }
        }
    }

    private func refreshContext() {
        guard guided.latencyPlan != nil else { return }
        perform { try guided.updateAVSyncContext(context) }
    }

    private func item(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).lineLimit(1)
        }
    }

    private func perform(_ operation: () throws -> Void) {
        actionError = nil
        do { try operation() } catch { actionError = error.localizedDescription }
    }
}
