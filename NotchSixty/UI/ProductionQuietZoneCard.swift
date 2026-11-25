import SwiftUI

/// E12 S19 (flag `e12.active-acoustics-page`): the one Quiet Zone card. A short setup list, one "where to quiet"
/// choice, and the only two switches on the page: Arm, and Feed-forward under it. It never arms by itself: both
/// switches are the user's own action, through the same controller calls the old cards used.
struct ProductionQuietZoneCard: View {
    @ObservedObject var quietZone: ActiveQuietZoneController
    @ObservedObject var ambient: AmbientCompensationController
    @ObservedObject var microphone: RoomCorrectionCalibrationController
    var engineRunning: Bool
    /// Shown under the card when an action fails (arming refused, for example).
    var perform: (@escaping () throws -> Void) -> Void

    private var model: QuietZoneCardModel {
        QuietZoneCardModel(quietZone.cardInputs(
            engineRunning: engineRunning,
            microphonePermissionGranted: microphone.permissionStatus == .authorized,
            microphoneName: microphone.selectedInputDevice?.name,
            measuredModelName: ambient.selectedModelPosition?.name))
    }

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            setupList(model)
            playbackModelPicker
            Divider()
            areaPicker(model)
            Divider()
            switches(model)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quiet Zone").font(.headline)
                Text("Closed-loop low-frequency anti-noise for stable 25–150 Hz environmental tones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(quietZone.status.displayName.uppercased())
                .font(.caption.bold())
                .tracking(1)
                .foregroundStyle(quietZone.status == .fault ? .red : quietZone.status == .cancelling ? .green : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private func setupList(_ model: QuietZoneCardModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up").font(.subheadline.bold())
            ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: step.state == .done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(step.state == .done ? .green : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(index + 1). \(step.title)").font(.callout.bold())
                        Text(step.detail).font(.caption).foregroundStyle(.secondary)
                        if let action = step.nextAction {
                            Text("Next: \(action)").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var playbackModelPicker: some View {
        HStack(spacing: 12) {
            Text("Measured position").foregroundStyle(.secondary)
            Picker("Measured position", selection: Binding(
                get: { ambient.configuration.playbackModelPositionID },
                set: { id in perform { try ambient.setPlaybackModelPosition(id) } }
            )) {
                Text("Select…").tag(UUID?.none)
                ForEach(ambient.availableModelPositions) { position in
                    Text(position.name).tag(UUID?.some(position.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer()
            if let measured = ambient.selectedModelPosition {
                Text("\(measured.sampleRate / 1_000, specifier: "%.1f") kHz")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func areaPicker(_ model: QuietZoneCardModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where to quiet").font(.subheadline.bold())
            Picker("Where to quiet", selection: Binding(
                get: { model.inputs.area },
                set: { quietZone.setAreaChoice($0) }
            )) {
                ForEach(QuietZoneAreaChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                        .disabled(model.reason(for: choice) != nil)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)
            ForEach(QuietZoneAreaChoice.allCases.filter { model.reason(for: $0) != nil }) { choice in
                Text("\(choice.title): \(model.reason(for: choice) ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func switches(_ model: QuietZoneCardModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(model.armSwitch.title, isOn: Binding(
                    get: { quietZone.arm.isArmed },
                    set: { on in perform { try quietZone.setEnabled(on) } }
                ))
                .toggleStyle(.switch)
                .disabled(!model.armSwitch.isEnabled)
                Text(model.armSwitch.disabledReason ?? model.armStatusLine)
                    .font(.caption)
                    .foregroundStyle(model.armSwitch.disabledReason == nil && !quietZone.arm.latchedByEvent ? Color.secondary : Color.orange)
                if model.armSwitch.disabledReason != nil {
                    Text(model.armStatusLine).font(.caption).foregroundStyle(.secondary)
                }
                if quietZone.arm.isArmed {
                    Button("Disarm now", role: .destructive) { quietZone.arm.disarm(.user) }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Toggle(model.feedForwardSwitch.title, isOn: Binding(
                        get: { quietZone.feedForwardArming?.isRequested ?? false },
                        set: { on in
                            if on { _ = quietZone.requestFeedForwardLive() } else { quietZone.cancelFeedForwardLive() }
                        }
                    ))
                    .toggleStyle(.switch)
                    .disabled(!model.feedForwardSwitch.isEnabled)
                    Text(model.readiness.title.uppercased())
                        .font(.caption.bold())
                        .foregroundStyle(model.readiness == .ready ? .green : .secondary)
                }
                .padding(.leading, 18)
                if let reason = model.feedForwardSwitch.disabledReason {
                    Text(reason).font(.caption).foregroundStyle(.orange).padding(.leading, 18)
                }
                if case .notReady(let reason, let action) = model.readiness {
                    Text("\(reason) \(action)").font(.caption).foregroundStyle(.secondary).padding(.leading, 18)
                } else if let arming = quietZone.feedForwardArming {
                    FeedForwardPhaseLine(arming: arming).padding(.leading, 18)
                }
                Text("Feed-forward plays upstream-reference anti-noise. It fades in over 3 seconds after its checks pass, and any fault turns it off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
        }
    }
}

private struct FeedForwardPhaseLine: View {
    @ObservedObject var arming: FeedForwardLiveArmingController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .fadingIn = arming.phase { ProgressView(value: arming.fadeProgress) }
            if case .waiting(let why) = arming.phase {
                Text("Waiting: \(why).").font(.caption).foregroundStyle(.secondary)
            }
            if let message = arming.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
