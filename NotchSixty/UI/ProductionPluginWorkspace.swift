import AppKit
import AudioToolbox
import AVFAudio
import CoreAudioKit
import Foundation
import SwiftUI

private struct PluginAddTarget: Identifiable, Equatable {
    let slotIndex: Int?

    var id: String {
        slotIndex.map { "slot-\($0)" } ?? "append"
    }

    var title: String {
        slotIndex.map { "Add Plug-in to Slot \($0 + 1)" }
            ?? "Add Plug-in"
    }
}

private enum PluginCatalogFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case compatible = "Compatible"
    case prepared = "Prepared"
    case quarantined = "Quarantined"

    var id: String { rawValue }
}

private enum AudioUnitPluginEditorError: Error, LocalizedError {
    case instantiationFailed(String)
    case invalidSavedState
    case stateUnavailable
    case stateTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .instantiationFailed(let reason):
            return "The Audio Unit editor could not be opened. \(reason)"
        case .invalidSavedState:
            return "The saved Audio Unit state could not be restored into the detached editor."
        case .stateUnavailable:
            return "The Audio Unit did not expose a serializable full state to apply."
        case .stateTooLarge(let bytes):
            return "The Audio Unit editor state is too large (\(bytes) bytes)."
        }
    }
}

@MainActor
private final class AudioUnitPluginEditorSession: ObservableObject, Identifiable {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let id = UUID()
    let slotIndex: Int
    let slotID: UUID
    let descriptor: AudioUnitComponentDescriptor
    let initialState: Data?
    /// E33 S23 (`e33.page-enhancements`): edit the running plug-in; false with the flag off (detached copy, Apply).
    let liveEditEnabled: Bool
    private let liveAttachment: (target: AUAudioUnitEditTarget, renderedLatencyFrames: Int)?
    private let pendingPreset: AudioUnitPresetEntry?
    private let sampleRate: Double

    @Published private(set) var liveSession: AudioUnitLiveEditSession?
    @Published private(set) var latencyNotice: String?
    @Published private(set) var isEditingRunningUnit = false
    @Published private(set) var presets: [AudioUnitPresetEntry] = []
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var customViewController: NSViewController?
    @Published private(set) var parameters: [AUParameter] = []

    private var unit: AVAudioUnit?

    init(
        slotIndex: Int,
        slot: AudioUnitRackSlotState,
        descriptor: AudioUnitComponentDescriptor,
        liveEditEnabled: Bool = false,
        liveAttachment: (target: AUAudioUnitEditTarget, renderedLatencyFrames: Int)? = nil,
        pendingPreset: AudioUnitPresetEntry? = nil,
        sampleRate: Double = 48_000
    ) {
        self.liveEditEnabled = liveEditEnabled
        self.liveAttachment = liveAttachment
        self.pendingPreset = pendingPreset
        self.sampleRate = sampleRate
        self.slotIndex = slotIndex
        self.slotID = slot.id
        self.descriptor = descriptor
        self.initialState = slot.opaqueFullState
    }

    func load() async {
        guard loadState == .loading, unit == nil else { return }
        if liveEditEnabled, let liveAttachment {
            await attachToRunningUnit(liveAttachment)
            return
        }
        do {
            let unit = try await Self.instantiate(descriptor.identity)
            if let initialState {
                try unit.withNodeAUAudioUnit { au in
                    try Self.restore(initialState, to: au)
                }
            }
            self.unit = unit
            parameters = unit.withNodeAUAudioUnit { au in
                au.parameterTree?.allParameters ?? []
            }
            if descriptor.hasCustomView {
                let au = unit.withNodeAUAudioUnit { au in au }
                customViewController =
                    await Self.requestViewController(for: au)
            }
            if liveEditEnabled {
                let au = unit.withNodeAUAudioUnit { au in au }
                let target = AUAudioUnitEditTarget(audioUnit: au, sampleRate: sampleRate)
                try startLiveSession(target: target, renderedLatencyFrames: target.reportedLatencyFrames ?? 0)
            }
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// E33 S23: the editor shows the unit the rack renders, so every change is heard at once.
    private func attachToRunningUnit(
        _ attachment: (target: AUAudioUnitEditTarget, renderedLatencyFrames: Int)
    ) async {
        do {
            let au = attachment.target.audioUnit
            parameters = au.parameterTree?.allParameters ?? []
            if descriptor.hasCustomView {
                customViewController = await Self.requestViewController(for: au)
            }
            isEditingRunningUnit = true
            try startLiveSession(
                target: attachment.target,
                renderedLatencyFrames: attachment.renderedLatencyFrames
            )
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func startLiveSession(
        target: AUAudioUnitEditTarget,
        renderedLatencyFrames: Int
    ) throws {
        let session = try AudioUnitLiveEditSession(target: target, renderedLatencyFrames: renderedLatencyFrames)
        liveSession = session
        presets = session.presets
        if let pendingPreset {
            try session.applyPreset(pendingPreset)
            refreshAfterEdit()
        }
    }

    /// Re-reads the readouts and the latency notice; called after each edit and on a short poll while the sheet is open.
    func refreshAfterEdit() {
        guard let liveSession else { return }
        latencyNotice = liveSession.latencyChanged
            ? AudioUnitLiveEditSession.latencyNotice(
                rendered: liveSession.renderedLatencyFrames,
                now: liveSession.reportedLatencyFrames,
                sampleRate: sampleRate
            )
            : nil
        objectWillChange.send()
    }

    func applyPreset(_ entry: AudioUnitPresetEntry) throws {
        try liveSession?.applyPreset(entry)
        refreshAfterEdit()
    }

    func revertEdits() throws {
        try liveSession?.revert()
        refreshAfterEdit()
    }

    func setParameter(
        _ parameter: AUParameter,
        value: Double
    ) {
        let clamped = min(
            max(value, Double(parameter.minValue)),
            Double(parameter.maxValue)
        )
        parameter.value = AUValue(clamped)
        refreshAfterEdit()
        objectWillChange.send()
    }

    func captureState() throws -> Data {
        guard let unit else {
            throw AudioUnitPluginEditorError.stateUnavailable
        }
        guard let state = unit.withNodeAUAudioUnit({ au in
                au.fullState ?? au.fullStateForDocument
              }) else {
            throw AudioUnitPluginEditorError.stateUnavailable
        }
        guard PropertyListSerialization.propertyList(
            state,
            isValidFor: .binary
        ) else {
            throw AudioUnitPluginEditorError.stateUnavailable
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: state,
            format: .binary,
            options: 0
        )
        guard data.count
                <= AudioUnitRackSlotState.maximumOpaqueStateBytes else {
            throw AudioUnitPluginEditorError.stateTooLarge(data.count)
        }
        return data
    }

    private static func instantiate(
        _ identity: AudioUnitComponentIdentity
    ) async throws -> AVAudioUnit {
        let description = AudioComponentDescription(
            componentType: identity.componentType,
            componentSubType: identity.componentSubType,
            componentManufacturer: identity.componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return try await withCheckedThrowingContinuation {
            continuation in
            AVAudioUnit.instantiate(
                with: description,
                options: []
            ) { unit, error in
                if let error {
                    continuation.resume(
                        throwing: AudioUnitPluginEditorError
                            .instantiationFailed(error.localizedDescription)
                    )
                } else if let unit {
                    continuation.resume(returning: unit)
                } else {
                    continuation.resume(
                        throwing: AudioUnitPluginEditorError
                            .instantiationFailed(
                                "The system returned neither a unit nor an error."
                            )
                    )
                }
            }
        }
    }

    private static func restore(
        _ data: Data,
        to audioUnit: AUAudioUnit
    ) throws {
        guard data.count
                <= AudioUnitRackSlotState.maximumOpaqueStateBytes else {
            throw AudioUnitPluginEditorError.stateTooLarge(data.count)
        }
        let object = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let state = object as? [String: Any] else {
            throw AudioUnitPluginEditorError.invalidSavedState
        }
        audioUnit.fullState = state
    }

    private static func requestViewController(
        for audioUnit: AUAudioUnit
    ) async -> NSViewController? {
        await audioUnit.requestViewController()
    }
}

private struct AudioUnitCustomViewContainer:
    NSViewControllerRepresentable {
    let viewController: NSViewController

    func makeNSViewController(
        context: Context
    ) -> NSViewController {
        viewController
    }

    func updateNSViewController(
        _ nsViewController: NSViewController,
        context: Context
    ) {}
}

private struct AudioUnitEditorSheet: View {
    @ObservedObject var session: AudioUnitPluginEditorSession
    let isApplying: Bool
    let onCancel: () -> Void
    let onApply: () -> Void
    /// Live editing: Done saves (or just closes when nothing changed). Apply and Cancel are not shown.
    let onDone: () -> Void
    let onError: (Error) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text(session.descriptor.name)
                        .font(DesignType.sectionTitle.font)
                    Text(
                        "\(session.descriptor.manufacturerName) · detached transactional editor"
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Slot \(session.slotIndex + 1)")
                    .font(DesignType.caption.font.monospacedDigit().bold())
                    .foregroundStyle(.secondary)
            }

            Divider()

            editorContent
                .frame(
                    minWidth: 620,
                    idealWidth: 760,
                    maxWidth: .infinity,
                    minHeight: 380,
                    idealHeight: 500,
                    maxHeight: .infinity
                )

            Divider()

            if session.liveEditEnabled {
                liveFooter
            } else {
                HStack {
                    Label(
                        "Changes are isolated until Apply. Apply re-runs offline preparation before the live rack can change.",
                        systemImage: "shield.lefthalf.filled"
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Cancel", role: .cancel, action: onCancel)
                        .disabled(isApplying)
                    Button("Apply", action: onApply)
                        .buttonStyle(.glassProminent)
                        .disabled(
                            isApplying
                                || session.loadState != .ready
                        )
                }
            }
        }
        .padding(DesignSpacing.l.pt)
        .interactiveDismissDisabled(session.liveEditEnabled)
        .task { await session.load() }
        .task {
            // A custom plug-in view changes the unit without telling us, so the delay notice polls.
            while session.liveEditEnabled, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                session.refreshAfterEdit()
            }
        }
    }

    private var liveFooter: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            if let notice = session.latencyNotice {
                Label(notice, systemImage: "clock.badge.exclamationmark")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.orange)
            }
            HStack {
                Label(
                    session.isEditingRunningUnit
                        ? "Changes are heard as you make them. Revert returns to how the plug-in was when this window opened."
                        : "Audio is not running through this plug-in, so changes are heard when it starts. Revert returns to how the plug-in was when this window opened.",
                    systemImage: "ear"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)

                Spacer()

                Menu("Presets") {
                    if session.presets.isEmpty {
                        Text("This plug-in lists no presets")
                    }
                    ForEach(session.presets) { preset in
                        Button(preset.name) {
                            do { try session.applyPreset(preset) } catch { onError(error) }
                        }
                    }
                }
                .disabled(session.presets.isEmpty || session.loadState != .ready)

                Button("Revert") {
                    do { try session.revertEdits() } catch { onError(error) }
                }
                .disabled(isApplying || session.loadState != .ready)
                Button("Done", action: onDone)
                    .buttonStyle(.glassProminent)
                    .disabled(isApplying)
            }
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        switch session.loadState {
        case .loading:
            VStack(spacing: DesignSpacing.m.pt) {
                ProgressView()
                Text("Opening detached Audio Unit editor…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let reason):
            DesignStateView(kind: .failed, title: "Unable to Open Plug-in Editor", detail: reason)

        case .ready:
            if let controller = session.customViewController {
                AudioUnitCustomViewContainer(
                    viewController: controller
                )
            } else if session.parameters.isEmpty {
                DesignStateView(
                    kind: .empty, title: "No Editor Surface",
                    detail: "This Audio Unit exposes neither a custom view nor host-visible parameters.",
                    systemImage: "slider.horizontal.3")
            } else {
                genericParameterEditor
            }
        }
    }

    private var genericParameterEditor: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
                ForEach(
                    session.parameters,
                    id: \.address
                ) { parameter in
                    VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                        HStack {
                            Text(parameter.displayName)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(
                                String(
                                    format: "%.4g",
                                    Double(parameter.value)
                                )
                            )
                            .font(DesignType.caption.font.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }

                        if parameter.minValue
                            < parameter.maxValue {
                            Slider(
                                value: Binding(
                                    get: {
                                        Double(parameter.value)
                                    },
                                    set: {
                                        session.setParameter(
                                            parameter,
                                            value: $0
                                        )
                                    }
                                ),
                                in: Double(parameter.minValue)
                                    ... Double(parameter.maxValue)
                            )
                            .designSlider(parameter.displayName, value: Double(parameter.value), unit: .plain(""))
                        }
                    }
                    .padding(.vertical, DesignSpacing.xs.pt)
                }
            }
            .padding(.horizontal, DesignSpacing.xs.pt)
        }
    }
}

/// E33 S23: what the slot menu offers.
/// E33 S24: what a rack row shows besides its name.
private struct PluginSlotReadings {
    let load: AudioUnitLoadDisplay
    let latencyText: String
}

/// E33 S25: the Channels choice for a stereo-only plug-in on a session wider than stereo (decision 29).
private struct PluginSlotChannels {
    let mode: AudioUnitSlotChannelMode
    let onChange: (AudioUnitSlotChannelMode) -> Void
}

/// E33 S24: drag a rack row onto another to reorder. The Move buttons stay for the keyboard and VoiceOver.
private struct PluginRowDrag: ViewModifier {
    let enabled: Bool
    let slotID: UUID
    let onDrop: (UUID) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(slotID.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let text = items.first, let dragged = UUID(uuidString: text) else { return false }
                    onDrop(dragged)
                    return true
                }
        } else {
            content
        }
    }
}

private struct PluginSlotMenu {
    let presets: [AudioUnitPresetEntry]
    let canPaste: Bool
    let onChoosePreset: (AudioUnitPresetEntry) -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
}

private struct PluginRackSlotRow: View {
    let index: Int
    let slot: AudioUnitRackSlotState
    let sampleRate: Double
    let report: AudioUnitOfflinePreparationReport?
    let quarantineEntry: AudioUnitQuarantineEntry?
    let rateNote: String?
    let isBusy: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onAdd: () -> Void
    let onBypassChange: (Bool) -> Void
    let onWetDryCommit: (Double) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onClearQuarantine: (() -> Void)?
    /// E33 S23: nil with `e33.page-enhancements` off. The slot menu: the plug-in's own presets, Copy and Paste settings.
    let slotMenu: PluginSlotMenu?
    /// E33 S24: nil with `e33.page-enhancements` off. Load and latency in milliseconds for this slot.
    let readings: PluginSlotReadings?
    /// E33 S25: nil unless the plug-in is stereo-only on a wider session (flag on).
    let channels: PluginSlotChannels?

    @State private var wetDryMix: Double

    init(
        index: Int,
        slot: AudioUnitRackSlotState,
        sampleRate: Double,
        report: AudioUnitOfflinePreparationReport?,
        quarantineEntry: AudioUnitQuarantineEntry?,
        rateNote: String? = nil,
        isBusy: Bool,
        canMoveUp: Bool,
        canMoveDown: Bool,
        onAdd: @escaping () -> Void,
        onBypassChange: @escaping (Bool) -> Void,
        onWetDryCommit: @escaping (Double) -> Void,
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        onClearQuarantine: (() -> Void)?,
        slotMenu: PluginSlotMenu? = nil,
        readings: PluginSlotReadings? = nil,
        channels: PluginSlotChannels? = nil
    ) {
        self.channels = channels
        self.slotMenu = slotMenu
        self.readings = readings
        self.index = index
        self.slot = slot
        self.sampleRate = sampleRate
        self.report = report
        self.quarantineEntry = quarantineEntry
        self.rateNote = rateNote
        self.isBusy = isBusy
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.onAdd = onAdd
        self.onBypassChange = onBypassChange
        self.onWetDryCommit = onWetDryCommit
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.onEdit = onEdit
        self.onRemove = onRemove
        self.onClearQuarantine = onClearQuarantine
        _wetDryMix = State(initialValue: slot.wetDryMix)
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignSpacing.m.pt) {
            Text("\(index + 1)")
                .font(DesignType.caption.font.monospacedDigit().bold())
                .foregroundStyle(.secondary)
                .frame(width: 22)

            if slot.isEmpty {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(.tertiary)
                    .frame(width: 22)

                Text("Empty Slot")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button(action: onAdd) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.glass)
                .disabled(isBusy)
            } else {
                Image(systemName: "waveform.badge.plus")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    HStack(spacing: DesignSpacing.s.pt) {
                        Text(slot.displayName ?? "Audio Unit")
                            .font(.subheadline.weight(.semibold))

                        statusBadge

                        if let readings {
                            metricBadge(
                                "Latency \(readings.latencyText)",
                                systemImage: "clock"
                            )
                            metricBadge(
                                readings.load.text,
                                systemImage: readings.load.level == .nearCutOut
                                    ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent"
                            )
                        } else if let latencyFrames {
                            metricBadge(
                                latencyText(latencyFrames),
                                systemImage: "clock"
                            )
                        }

                        if let tailFrames, tailFrames > 0 {
                            metricBadge(
                                tailText(tailFrames),
                                systemImage: "waveform.path"
                            )
                        }
                    }

                    if let manufacturer = slot.manufacturerName {
                        Text(manufacturer)
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                    }

                    if let channels {
                        Picker("Channels", selection: Binding(
                            get: { channels.mode },
                            set: { channels.onChange($0) }
                        )) {
                            ForEach(AudioUnitSlotChannelMode.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(isBusy)
                        .accessibilityHint("This plug-in is stereo only. Choose which speakers it runs on.")
                    }

                    if let quarantineEntry {
                        Text(quarantineEntry.lastFailureDescription)
                            .font(DesignType.caption.font)
                            .foregroundStyle(StatusLevel.attention.color)
                            .lineLimit(2)
                    } else if let warning = readings?.load.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(DesignType.caption.font)
                            .foregroundStyle(StatusLevel.attention.color)
                            .lineLimit(2)
                    } else if let rateNote {
                        Text(rateNote)
                            .font(DesignType.caption.font)
                            .foregroundStyle(StatusLevel.attention.color)
                            .lineLimit(2)
                    }
                }
                .frame(minWidth: 210, alignment: .leading)

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: DesignSpacing.s.pt) {
                    HStack(spacing: DesignSpacing.s.pt) {
                        Text("Mix")
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)

                        Slider(
                            value: $wetDryMix,
                            in: 0...1,
                            onEditingChanged: { editing in
                                if !editing {
                                    onWetDryCommit(wetDryMix)
                                }
                            }
                        )
                        .designSlider("Wet and dry mix", value: wetDryMix, unit: .percent)
                        .frame(width: 120)
                        .disabled(isBusy)

                        Text(
                            "\(Int((wetDryMix * 100).rounded()))%"
                        )
                        .font(DesignType.caption.font.monospacedDigit())
                        .frame(width: 38, alignment: .trailing)
                    }

                    HStack(spacing: DesignSpacing.s.pt) {
                        Toggle(
                            "Bypass",
                            isOn: Binding(
                                get: { slot.bypassed },
                                set: onBypassChange
                            )
                        )
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(isBusy)

                        Button(action: onEdit) {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(.glass)
                        .help("Open detached plug-in editor")
                        .disabled(isBusy)

                        if let slotMenu {
                            Menu {
                                Menu("Presets") {
                                    if slotMenu.presets.isEmpty {
                                        Text("Presets are listed while audio runs through this plug-in. Open the editor to choose one.")
                                    }
                                    ForEach(slotMenu.presets) { preset in
                                        Button(preset.name) { slotMenu.onChoosePreset(preset) }
                                    }
                                }
                                Button("Copy settings", action: slotMenu.onCopy)
                                Button("Paste settings", action: slotMenu.onPaste)
                                    .disabled(!slotMenu.canPaste)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.button)
                            .buttonStyle(.glass)
                            .help("Plug-in presets, copy and paste settings")
                            .disabled(isBusy)
                        }

                        Button(action: onMoveUp) {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.glass)
                        .help("Move plug-in earlier in the rack")
                        .disabled(isBusy || !canMoveUp)

                        Button(action: onMoveDown) {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.glass)
                        .help("Move plug-in later in the rack")
                        .disabled(isBusy || !canMoveDown)

                        if let onClearQuarantine {
                            Button(action: onClearQuarantine) {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.glass)
                            .help(
                                "Clear quarantine. The plug-in must pass fresh preparation before it can run."
                            )
                            .disabled(isBusy)
                        }

                        Button(
                            role: .destructive,
                            action: onRemove
                        ) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.glass)
                        .foregroundStyle(StatusLevel.problem.color)
                        .help("Remove plug-in")
                        .disabled(isBusy)
                    }
                }
            }
        }
        .padding(.horizontal, DesignSpacing.l.pt)
        .padding(.vertical, DesignSpacing.m.pt)
        .frame(minHeight: 64)
        .designSurface(.medium)
        .onChange(of: slot.wetDryMix) { _, newValue in
            wetDryMix = newValue
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if quarantineEntry != nil {
            Text("QUARANTINED")
                .font(DesignType.caption.font.bold())
                .foregroundStyle(StatusLevel.attention.color)
                .padding(.horizontal, DesignSpacing.s.pt)
                .padding(.vertical, DesignSpacing.xs.pt)
                .background(
                    StatusLevel.attention.color.opacity(0.12),
                    in: .capsule
                )
        } else if report != nil {
            Text(slot.bypassed ? "PREPARED · BYPASSED" : "PREPARED")
                .font(DesignType.caption.font.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignSpacing.s.pt)
                .padding(.vertical, DesignSpacing.xs.pt)
                .background(
                    Color.primary.opacity(0.07),
                    in: .capsule
                )
        } else {
            Text(slot.bypassed ? "BYPASSED" : "NEEDS PREP")
                .font(DesignType.caption.font.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignSpacing.s.pt)
                .padding(.vertical, DesignSpacing.xs.pt)
                .background(
                    Color.primary.opacity(0.07),
                    in: .capsule
                )
        }
    }

    private func metricBadge(
        _ text: String,
        systemImage: String
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(DesignType.caption.font.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, DesignSpacing.s.pt)
            .padding(.vertical, DesignSpacing.xs.pt)
            .background(
                Color.primary.opacity(0.06),
                in: .capsule
            )
    }

    private var latencyFrames: Int? {
        report?.probe.latencyFrames
            ?? slot.lastKnownLatencyFrames
    }

    private var tailFrames: Int? {
        report?.probe.tailFrames
            ?? slot.lastKnownTailFrames
    }

    private func latencyText(_ frames: Int) -> String {
        guard sampleRate > 0 else { return "\(frames) fr" }
        let milliseconds = Double(frames) / sampleRate * 1_000
        return String(
            format: "%d fr · %.2f ms",
            frames,
            milliseconds
        )
    }

    private func tailText(_ frames: Int) -> String {
        guard sampleRate > 0 else { return "\(frames) tail" }
        let milliseconds = Double(frames) / sampleRate * 1_000
        return String(
            format: "%.0f ms tail",
            milliseconds
        )
    }
}

struct ProductionPluginWorkspace: View {
    let product: ProductController
    private var engine: AudioIOEngine
    @ObservedObject private var host: AudioUnitHostController

    @State private var addTarget: PluginAddTarget?
    @State private var editorSession: AudioUnitPluginEditorSession?
    @State private var pendingRemovalIndex: Int?
    @State private var catalogSearch = ""
    @State private var catalogFilter: PluginCatalogFilter = .all
    @State private var manufacturerFilter = "All Manufacturers"
    @State private var mutationInFlight = false
    @State private var commandError: String?
    @State private var lastMutationSummary: String?
    /// E33 S24: latest load reading per slot, refreshed by the poll below while the page is shown.
    @State private var loadReadings: [UUID: AudioUnitLoadReading] = [:]
    @State private var showIncompatible = false

    init(product: ProductController) {
        self.product = product
        engine = product.audioEngine
        _host = ObservedObject(
            wrappedValue: product.audioUnitHost
        )
    }

    /// E33 S25: true for an occupied slot whose plug-in is stereo only on a session wider than stereo.
    private func slotRunsAsPairs(_ slot: AudioUnitRackSlotState) -> Bool {
        guard let component = slot.component, let descriptor = host.descriptor(for: component) else { return false }
        return processingFormat.runsAsStereoPairs(on: descriptor)
    }

    private var processingFormat: AudioUnitRackProcessingFormat {
        let channelCount: Int
        var roles: [OutputProgramRole]?
        if let profile = engine.outputDeviceProfileConfiguration,
           profile.enabled {
            roles = profile.programLayout.roles
            channelCount = profile.programLayout.roles.count
        } else if let profile =
                    engine.headphoneDeviceProfileConfiguration,
                  profile.enabled {
            roles = profile.programLayout.roles
            channelCount = profile.programLayout.roles.count
        } else {
            channelCount = 2
        }
        return AudioUnitRackProcessingFormat(
            sampleRate:
                engine.selectedOutputDevice?.nominalSampleRate
                    ?? 48_000,
            channelCount: max(
                1,
                min(
                    AudioUnitRackProcessingFormat.maximumChannelCount,
                    channelCount
                )
            ),
            maximumFramesPerSlice: AudioUnitRackProcessingFormat
                .recommendedMaximumFramesPerSlice(
                    sampleRate: engine.selectedOutputDevice?.nominalSampleRate ?? 48_000
                ),
            channelRoles: roles,
            allowsStereoPairs: FeatureFlags().isEnabled(.eqPageEnhancements)
        )
    }

    private var compatibleCount: Int {
        host.discoveredComponents.lazy.filter {
            host.compatibility(
                of: $0,
                for: processingFormat
            ).compatible
        }.count
    }

    private var manufacturers: [String] {
        let names = Set(
            host.discoveredComponents.map(\.manufacturerName)
        )
        return ["All Manufacturers"]
            + names.sorted {
                $0.localizedCaseInsensitiveCompare($1)
                    == .orderedAscending
            }
    }

    private var filteredComponents: [AudioUnitComponentDescriptor] {
        host.discoveredComponents.filter { component in
            guard catalogVisible(component) else { return false }
            let compatibility = host.compatibility(
                of: component,
                for: processingFormat
            )
            let lifecycle =
                host.lifecycleByComponent[component.identity]
            let quarantined =
                host.quarantine.entry(for: component.identity) != nil

            let filterMatches: Bool
            switch catalogFilter {
            case .all:
                filterMatches = true
            case .compatible:
                filterMatches = compatibility.compatible
            case .prepared:
                filterMatches = lifecycle == .prepared
            case .quarantined:
                filterMatches = quarantined
            }

            let manufacturerMatches =
                manufacturerFilter == "All Manufacturers"
                    || component.manufacturerName
                        == manufacturerFilter

            let trimmed = catalogSearch.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let searchMatches =
                trimmed.isEmpty
                    || component.name.localizedCaseInsensitiveContains(
                        trimmed
                    )
                    || component.manufacturerName
                        .localizedCaseInsensitiveContains(trimmed)
                    || component.typeName
                        .localizedCaseInsensitiveContains(trimmed)

            return filterMatches
                && manufacturerMatches
                && searchMatches
        }
    }

    private var nextAddTarget: PluginAddTarget? {
        if let index =
            host.rackConfiguration.slots.firstIndex(
                where: { $0.isEmpty }
            ) {
            return PluginAddTarget(slotIndex: index)
        }
        guard host.rackConfiguration.slots.count
                < AudioUnitRackConfiguration.maximumSlotCount else {
            return nil
        }
        return PluginAddTarget(slotIndex: nil)
    }

    private var rackLatencyFrames: Int? {
        try? host.executionPlan(
            for: processingFormat
        ).totalLatencyFrames
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.xl.pt) {
                header
                if enhanced {
                    signalChainLine
                } else {
                    signalChainCard
                }
                scanCard
                rackCard
                catalogCard
                if !enhanced {
                    safetyCard
                }
            }
            .padding(DesignSpacing.xl.pt)
            .frame(
                maxWidth: 1_100,
                alignment: .topLeading
            )
        }
        .task {
            if host.lastScanDate == nil {
                await host.refresh(format: processingFormat)
            }
        }
        .task {
            guard enhanced else { return }
            host.startWatchingRegistrations { processingFormat }
            await pollLoadReadings()
        }
        .onDisappear {
            host.stopWatchingRegistrations()
        }
        .sheet(item: $addTarget) { target in
            addPluginSheet(target)
        }
        .sheet(item: $editorSession) { session in
            AudioUnitEditorSheet(
                session: session,
                isApplying: mutationInFlight,
                onCancel: {
                    editorSession = nil
                },
                onApply: {
                    applyEditor(session)
                },
                onDone: {
                    closeLiveEditor(session)
                },
                onError: { commandError = $0.localizedDescription }
            )
        }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(
                get: { pendingRemovalIndex != nil },
                set: {
                    if !$0 { pendingRemovalIndex = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Plug-in", role: .destructive) {
                if let index = pendingRemovalIndex {
                    pendingRemovalIndex = nil
                    runMutation(.remove(slot: index))
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRemovalIndex = nil
            }
        } message: {
            Text(
                "Removal uses a bounded click-safe transition. Long wet tails are not mixed additively after removal, keeping downstream headroom and protection deterministic."
            )
        }
        .designMessage("Plug-in Rack Error", message: $commandError)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                Text(
                    "Transactional Audio Unit hosting, live rack controls, and Content Preset state."
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("LIVE RACK")
                .font(DesignType.caption.font.bold())
                .tracking(1.3)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignSpacing.m.pt)
                .padding(.vertical, DesignSpacing.s.pt)
                .designSurface(.small)
        }
    }

    /// E33 S24 (decision 30): the signal-chain card shrinks to one line.
    private var signalChainLine: some View {
        Text("Signal chain: Playback DSP, Plug-in Rack, System Correction, Protection.")
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
    }

    private var signalChainCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Signal-chain position")
                .font(DesignType.sectionTitle.font)

            HStack(spacing: DesignSpacing.m.pt) {
                chainNode("Playback DSP")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                chainNode("Plug-in Rack")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                chainNode("System Correction")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                chainNode("Protection")
            }

            Text(
                "The rack is Playback/content state. Every edit is prepared off realtime and crosses PR82's commit barrier before saved or live rack state changes."
            )
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .designSurface(.large)
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Installed Audio Units")
                        .font(DesignType.sectionTitle.font)
                    Text(
                        "\(processingFormat.channelCount)-channel symmetric rack · \(processingFormat.sampleRate / 1_000, specifier: "%.1f") kHz"
                    )
                    .font(DesignType.caption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if mutationInFlight || host.scanInFlight {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    Task { await host.refresh(format: processingFormat) }
                } label: {
                    Label(
                        "Scan",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.glass)
                .disabled(mutationInFlight || host.scanInFlight)
            }

            HStack(spacing: DesignSpacing.xl.pt) {
                scanMetric(
                    "Discovered",
                    "\(host.discoveredComponents.count)"
                )
                scanMetric(
                    "Compatible",
                    "\(compatibleCount)"
                )
                scanMetric(
                    "Prepared",
                    "\(host.preparedComponentCount)"
                )
                scanMetric(
                    "Quarantined",
                    "\(host.quarantinedComponentCount)"
                )

                if let rackLatencyFrames {
                    scanMetric(
                        "Rack Latency",
                        latencySummary(rackLatencyFrames)
                    )
                }
            }

            if let date = host.lastScanDate {
                Text(
                    "Last scan: \(date.formatted(date: .omitted, time: .standard))"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.tertiary)
            }

            if let lastMutationSummary {
                Label(
                    lastMutationSummary,
                    systemImage: "checkmark.circle"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            }

            if let error = host.lastErrorDescription {
                Label(
                    error,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(StatusLevel.attention.color)
                .textSelection(.enabled)
            }
        }
        .padding(DesignSpacing.l.pt)
        .designSurface(.large)
    }

    private var rackCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Playback Plug-in Rack")
                        .font(DesignType.sectionTitle.font)
                    Text(
                        "Order, bypass, wet/dry, opaque state, and plug-in identity follow the selected Content Preset."
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if enhanced, host.rackConfiguration.occupiedSlotCount > 0 {
                    Toggle(
                        "Bypass rack",
                        isOn: Binding(
                            get: { AudioUnitRackBypass.isBypassed(host.rackConfiguration) },
                            set: { setRackBypassed($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(mutationInFlight)
                    .help("Bypass every plug-in. The rack keeps its delay, so level and timing do not jump.")
                }

                Text(
                    "\(host.rackConfiguration.occupiedSlotCount)/\(host.rackConfiguration.slots.count) occupied"
                )
                .font(DesignType.caption.font.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            ForEach(
                Array(
                    host.rackConfiguration.slots.enumerated()
                ),
                id: \.element.id
            ) { index, slot in
                let report =
                    preparedReport(for: slot)
                let quarantineEntry =
                    slot.component.flatMap {
                        host.quarantine.entry(for: $0)
                    }

                PluginRackSlotRow(
                    index: index,
                    slot: slot,
                    sampleRate: processingFormat.sampleRate,
                    report: report,
                    quarantineEntry: quarantineEntry,
                    rateNote: host.rateRefusalNote(
                        forSlot: index,
                        sampleRate: processingFormat.sampleRate
                    ),
                    isBusy: mutationInFlight,
                    canMoveUp: index > 0,
                    canMoveDown:
                        index + 1
                            < host.rackConfiguration.slots.count,
                    onAdd: {
                        addTarget =
                            PluginAddTarget(
                                slotIndex: index
                            )
                    },
                    onBypassChange: {
                        runMutation(
                            .setBypassed(
                                slot: index,
                                bypassed: $0
                            )
                        )
                    },
                    onWetDryCommit: {
                        runMutation(
                            .setWetDryMix(
                                slot: index,
                                mix: $0
                            )
                        )
                    },
                    onMoveUp: {
                        runMutation(
                            .move(
                                from: index,
                                to: index - 1
                            )
                        )
                    },
                    onMoveDown: {
                        runMutation(
                            .move(
                                from: index,
                                to: index + 1
                            )
                        )
                    },
                    onEdit: {
                        openEditor(
                            slot: slot,
                            index: index
                        )
                    },
                    onRemove: {
                        pendingRemovalIndex = index
                    },
                    onClearQuarantine:
                        quarantineEntry == nil
                            ? nil
                            : {
                                if let component = slot.component {
                                    host.clearQuarantine(
                                        component
                                    )
                                }
                            },
                    slotMenu: liveEditEnabled && slot.component != nil
                        ? PluginSlotMenu(
                            presets: host.liveEditTarget(slotIndex: index, sampleRate: processingFormat.sampleRate)?
                                .target.presets() ?? [],
                            canPaste: host.settingsClipboard?.canPaste(onto: slot) ?? false,
                            onChoosePreset: { openEditor(slot: slot, index: index, preset: $0) },
                            onCopy: { copySettings(slot) },
                            onPaste: { pasteSettings(onto: slot, index: index) }
                        )
                        : nil,
                    readings: enhanced && slot.component != nil
                        ? PluginSlotReadings(
                            load: AudioUnitLoadDisplay(loadReadings[slot.id]),
                            latencyText: AudioUnitLatencyDisplay.milliseconds(
                                frames: report?.probe.latencyFrames ?? slot.lastKnownLatencyFrames ?? 0,
                                sampleRate: processingFormat.sampleRate
                            )
                        )
                        : nil,
                    channels: enhanced && slotRunsAsPairs(slot)
                        ? PluginSlotChannels(
                            mode: slot.channels,
                            onChange: { runMutation(.setChannelMode(slot: index, mode: $0)) }
                        )
                        : nil
                )
                .modifier(PluginRowDrag(
                    enabled: enhanced && !mutationInFlight,
                    slotID: slot.id,
                    onDrop: { dragged in
                        if let move = AudioUnitRackDrag.mutation(
                            draggedID: dragged,
                            onto: slot.id,
                            in: host.rackConfiguration
                        ) {
                            runMutation(move)
                        }
                    }
                ))
            }

            HStack {
                Button {
                    addTarget = nextAddTarget
                } label: {
                    Label(
                        "Add Plug-in",
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.glassProminent)
                .disabled(
                    mutationInFlight
                        || nextAddTarget == nil
                )

                Spacer()

                Text(
                    "Up to \(AudioUnitRackConfiguration.maximumSlotCount) slots · edits are transactional"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(DesignSpacing.l.pt)
        .designSurface(.large)
    }

    @ViewBuilder
    private var catalogCard: some View {
        if host.lastScanDate == nil {
            DesignStateView(
                kind: .empty, title: "Audio Unit catalog not scanned",
                detail: "Scan to inspect installed Audio Unit effects.",
                systemImage: "puzzlepiece.extension")
            .frame(
                maxWidth: .infinity,
                minHeight: 220
            )
            .padding(DesignSpacing.m.pt)
            .designSurface(.large)
        } else {
            VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                HStack {
                    Text("Compatibility Catalog")
                        .font(DesignType.sectionTitle.font)
                    Spacer()
                    Text(
                        "\(compatibleCount) compatible with the current rack format"
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                    if enhanced {
                        Toggle("Show incompatible", isOn: $showIncompatible)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
                if incompatibleHiddenCount > 0 {
                    Text("\(incompatibleHiddenCount) incompatible plug-ins are hidden. Turn on Show incompatible to see why.")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.tertiary)
                }

                if host.discoveredComponents.isEmpty {
                    Text(
                        "No registered Audio Unit effects or music effects were found."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        host.discoveredComponents.filter(catalogVisible).prefix(12)
                    ) { component in
                        componentRow(component)
                    }

                    if host.discoveredComponents.filter(catalogVisible).count > 12 {
                        Text(
                            "Use Add Plug-in to search and filter the complete catalog."
                        )
                        .font(DesignType.caption.font)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(DesignSpacing.l.pt)
            .designSurface(.large)
        }
    }

    private var safetyCard: some View {
        Label {
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                Text(
                    "Detached editors, bounded transitions, deterministic protection"
                )
                .font(.subheadline.weight(.semibold))
                Text(
                    "Vendor UI edits happen on a detached Audio Unit copy. Apply serializes its state, re-runs offline preparation, and only then publishes a new live generation. Removal and bypass use the bounded PR82 transition rather than additive full-tail mixing, so correlated or nonlinear tails cannot consume unbounded headroom before the final protection stage."
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "lock.shield")
        }
        .padding(DesignSpacing.l.pt)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .designSurface(.medium)
    }

    private func addPluginSheet(
        _ target: PluginAddTarget
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text(target.title)
                        .font(DesignType.sectionTitle.font)
                    Text(
                        "\(processingFormat.channelCount)-channel · \(processingFormat.sampleRate / 1_000, specifier: "%.1f") kHz"
                    )
                    .font(DesignType.caption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    addTarget = nil
                }
                .disabled(mutationInFlight)
            }

            HStack(spacing: DesignSpacing.m.pt) {
                TextField(
                    "Search plug-ins or manufacturers",
                    text: $catalogSearch
                )
                .textFieldStyle(.roundedBorder)

                Picker(
                    "Manufacturer",
                    selection: $manufacturerFilter
                ) {
                    ForEach(manufacturers, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .frame(width: 220)

                Picker(
                    "Filter",
                    selection: $catalogFilter
                ) {
                    ForEach(PluginCatalogFilter.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .frame(width: 180)

                if enhanced {
                    Toggle("Show incompatible", isOn: $showIncompatible)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            Divider()

            if filteredComponents.isEmpty {
                DesignStateView(
                    kind: .empty, title: "No Matching Audio Units",
                    detail: "Adjust the search or compatibility filters.",
                    systemImage: "magnifyingglass")
                .frame(
                    maxWidth: .infinity,
                    minHeight: 280
                )
            } else {
                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: 0
                    ) {
                        ForEach(filteredComponents) {
                            component in
                            browserComponentRow(
                                component,
                                target: target
                            )
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 360)
            }
        }
        .padding(DesignSpacing.l.pt)
        .frame(
            minWidth: 760,
            idealWidth: 860,
            minHeight: 520
        )
    }

    private func browserComponentRow(
        _ component: AudioUnitComponentDescriptor,
        target: PluginAddTarget
    ) -> some View {
        let compatibility = host.compatibility(
            of: component,
            for: processingFormat
        )
        let lifecycle =
            host.lifecycleByComponent[component.identity]
        let quarantineEntry =
            host.quarantine.entry(for: component.identity)

        return HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
            Image(
                systemName:
                    compatibility.compatible
                        ? "checkmark.circle.fill"
                        : "xmark.circle"
            )
            .foregroundStyle(
                compatibility.compatible
                    ? Color.primary.opacity(0.62)
                    : StatusLevel.attention.color
            )
            .frame(width: 22)

            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                HStack(spacing: DesignSpacing.s.pt) {
                    Text(component.name)
                        .font(.subheadline.weight(.semibold))
                    Text(component.versionString)
                        .font(DesignType.caption.font.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(
                    "\(component.manufacturerName) · \(component.typeName)"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)

                if let reasonText = catalogReasonText(
                    component,
                    compatibility: compatibility,
                    quarantine: nil
                ) {
                    Text(reasonText)
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }

                if let quarantineEntry {
                    Text(
                        enhanced
                            ? AudioUnitCatalogReasons.quarantineReason(for: component, entry: quarantineEntry).text
                            : quarantineEntry.lastFailureDescription
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(StatusLevel.attention.color)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: DesignSpacing.s.pt) {
                HStack(spacing: DesignSpacing.s.pt) {
                    Text(lifecycleLabel(lifecycle))
                        .font(DesignType.caption.font.bold())
                        .foregroundStyle(.secondary)

                    if component.hasCustomView {
                        Label(
                            "Vendor UI",
                            systemImage: "macwindow"
                        )
                        .font(DesignType.caption.font)
                        .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: DesignSpacing.s.pt) {
                    if quarantineEntry != nil {
                        Button("Clear Quarantine") {
                            host.clearQuarantine(
                                component.identity
                            )
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(mutationInFlight)
                    }

                    Button("Add") {
                        install(
                            component,
                            target: target
                        )
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .disabled(
                        mutationInFlight
                            || !compatibility.compatible
                            || quarantineEntry != nil
                    )
                }
            }
        }
        .padding(.vertical, DesignSpacing.m.pt)
    }

    private func componentRow(
        _ component: AudioUnitComponentDescriptor
    ) -> some View {
        let compatibility = host.compatibility(
            of: component,
            for: processingFormat
        )
        let lifecycle =
            host.lifecycleByComponent[component.identity]

        return HStack(
            alignment: .top,
            spacing: DesignSpacing.m.pt
        ) {
            Image(
                systemName:
                    compatibility.compatible
                        ? "checkmark.circle.fill"
                        : "xmark.circle"
            )
            .foregroundStyle(
                compatibility.compatible
                    ? Color.primary.opacity(0.62)
                    : StatusLevel.attention.color
            )
            .frame(width: 22)

            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                HStack(spacing: DesignSpacing.s.pt) {
                    Text(component.name)
                        .font(.subheadline.weight(.semibold))
                    Text(component.versionString)
                        .font(DesignType.caption.font.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(
                    "\(component.manufacturerName) · \(component.typeName)"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
                Text(component.identity.fourCCSummary)
                    .font(DesignType.caption.font.monospaced())
                    .foregroundStyle(.tertiary)

                if let reasonText = catalogReasonText(
                    component,
                    compatibility: compatibility,
                    quarantine: host.quarantine.entry(for: component.identity)
                ) {
                    Text(reasonText)
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: DesignSpacing.xs.pt) {
                Text(lifecycleLabel(lifecycle))
                    .font(DesignType.caption.font.bold())
                    .foregroundStyle(.secondary)
                if component.hasCustomView {
                    Label(
                        "Vendor UI",
                        systemImage: "macwindow"
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, DesignSpacing.s.pt)
    }

    private var removalTitle: String {
        guard let index = pendingRemovalIndex,
              host.rackConfiguration.slots.indices.contains(
                index
              ) else {
            return "Remove Plug-in?"
        }
        return "Remove \(host.rackConfiguration.slots[index].displayName ?? "Plug-in")?"
    }

    private func install(
        _ component: AudioUnitComponentDescriptor,
        target: PluginAddTarget
    ) {
        let mutation: AudioUnitRackMutation
        if let slotIndex = target.slotIndex {
            mutation = .install(
                component: component.identity,
                slot: slotIndex,
                initiallyBypassed: false
            )
        } else {
            mutation = .append(
                component: component.identity,
                initiallyBypassed: false
            )
        }

        runMutation(mutation) {
            addTarget = nil
            catalogSearch = ""
            catalogFilter = .all
            manufacturerFilter = "All Manufacturers"
        }
    }

    private var liveEditEnabled: Bool {
        FeatureFlags.isEnabledProcessWide(.eqPageEnhancements)
    }

    /// E33 S24 readings and rack controls share the page-enhancements flag.
    private var enhanced: Bool { liveEditEnabled }

    private func pollLoadReadings() async {
        while !Task.isCancelled {
            loadReadings = host.takeLoadReadings()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func setRackBypassed(_ bypassed: Bool) {
        let configuration: AudioUnitRackConfiguration
        if bypassed {
            // Session-only (G84): the host keeps the earlier flags and the Content Preset saves the rack with them.
            let result = AudioUnitRackBypass.bypassing(host.rackConfiguration)
            configuration = result.configuration
            runMutation(.replaceConfiguration(configuration)) { host.rememberRackBypass(saved: result.saved) }
            return
        }
        configuration = AudioUnitRackBypass.restoring(host.rackConfiguration, saved: host.rackBypassSaved)
        runMutation(.replaceConfiguration(configuration))
    }

    /// Plain reason and advice with the flag on; the engineering text with it off.
    private func catalogReasonText(
        _ component: AudioUnitComponentDescriptor,
        compatibility: AudioUnitComponentCompatibility,
        quarantine: AudioUnitQuarantineEntry?
    ) -> String? {
        if enhanced {
            let reasons = AudioUnitCatalogReasons.reasons(
                for: component,
                format: processingFormat,
                quarantine: quarantine
            )
            return reasons.isEmpty ? nil : reasons.map(\.text).joined(separator: "\n")
        }
        return compatibility.compatible ? nil : compatibility.reasons.joined(separator: " ")
    }

    /// Hidden by default with the flag on (a quarantined plug-in stays listed so it can be cleared).
    private func catalogVisible(_ component: AudioUnitComponentDescriptor) -> Bool {
        guard enhanced, !showIncompatible else { return true }
        return host.compatibility(of: component, for: processingFormat).compatible
            || host.quarantine.entry(for: component.identity) != nil
    }

    private var incompatibleHiddenCount: Int {
        enhanced && !showIncompatible
            ? host.discoveredComponents.filter { !catalogVisible($0) }.count
            : 0
    }

    private func openEditor(
        slot: AudioUnitRackSlotState,
        index: Int,
        preset: AudioUnitPresetEntry? = nil
    ) {
        guard let component = slot.component,
              let descriptor =
                host.descriptor(for: component) else {
            commandError =
                "The selected Audio Unit is no longer available in the current catalog."
            return
        }
        editorSession =
            AudioUnitPluginEditorSession(
                slotIndex: index,
                slot: slot,
                descriptor: descriptor,
                liveEditEnabled: liveEditEnabled,
                liveAttachment: liveEditEnabled
                    ? host.liveEditTarget(slotIndex: index, sampleRate: processingFormat.sampleRate)
                    : nil,
                pendingPreset: preset,
                sampleRate: processingFormat.sampleRate
            )
    }

    /// E33 S23: closing keeps the changes and saves them through the existing rack transaction; a change in the
    /// plug-in's delay takes the existing controlled restart. A failed save leaves the editor open (Revert undoes).
    private func closeLiveEditor(_ session: AudioUnitPluginEditorSession) {
        guard let live = session.liveSession else {
            editorSession = nil
            return
        }
        do {
            switch try live.finish() {
            case .unchanged:
                live.end()
                editorSession = nil
            case .commit(let state, _):
                runMutation(.setOpaqueFullState(slot: session.slotIndex, state: state), onSuccess: {
                    live.end()
                    editorSession = nil
                })
            }
        } catch {
            commandError = error.localizedDescription
        }
    }

    private func copySettings(_ slot: AudioUnitRackSlotState) {
        host.settingsClipboard = AudioUnitSettingsClipboard(copying: slot)
    }

    private func pasteSettings(onto slot: AudioUnitRackSlotState, index: Int) {
        guard let clipboard = host.settingsClipboard else { return }
        do {
            runMutation(try clipboard.pasteMutation(onto: slot, index: index))
        } catch {
            commandError = error.localizedDescription
        }
    }

    private func applyEditor(
        _ session: AudioUnitPluginEditorSession
    ) {
        do {
            let state = try session.captureState()
            runMutation(
                .setOpaqueFullState(
                    slot: session.slotIndex,
                    state: state
                )
            ) {
                editorSession = nil
            }
        } catch {
            commandError = error.localizedDescription
        }
    }

    private func preparedReport(
        for slot: AudioUnitRackSlotState
    ) -> AudioUnitOfflinePreparationReport? {
        guard let report =
                host.preparationReport(
                    forSlotID: slot.id
                ),
              report.component == slot.component,
              report.format == processingFormat,
              report.capturedFullState
                == slot.opaqueFullState else {
            return nil
        }
        return report
    }

    private func runMutation(
        _ mutation: AudioUnitRackMutation,
        onSuccess: (() -> Void)? = nil
    ) {
        guard !mutationInFlight else { return }
        mutationInFlight = true
        commandError = nil

        Task { @MainActor in
            defer { mutationInFlight = false }
            do {
                let activation =
                    try await product.mutateAudioUnitRack(
                        mutation
                    )
                lastMutationSummary =
                    activationSummary(activation)
                onSuccess?()
            } catch {
                commandError =
                    error.localizedDescription
            }
        }
    }

    private func activationSummary(
        _ activation: AudioUnitRackMutationActivation
    ) -> String {
        switch activation {
        case .noAudioChange:
            return "Rack updated; no live audio transition was required."
        case .stagedForNextStart:
            return "Rack updated and staged for the next processing start."
        case .seamlessCrossfade(let generation):
            return "Live rack updated with seamless generation \(generation) crossfade."
        case .controlledRestart:
            return "Rack latency changed; playback used the controlled restart path."
        }
    }

    private func lifecycleLabel(
        _ state: AudioUnitComponentLifecycleState?
    ) -> String {
        switch state {
        case .discovered:
            return "DISCOVERED"
        case .probing:
            return "PREPARING"
        case .prepared:
            return "PREPARED"
        case .quarantined:
            return "QUARANTINED"
        case nil:
            return "UNSCANNED"
        }
    }

    private func scanMetric(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            Text(title)
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignType.sectionTitle.font)
                .monospacedDigit()
        }
    }

    private func latencySummary(
        _ frames: Int
    ) -> String {
        guard processingFormat.sampleRate > 0 else {
            return "\(frames) fr"
        }
        let milliseconds =
            Double(frames)
                / processingFormat.sampleRate
                * 1_000
        return String(
            format: "%d fr / %.2f ms",
            frames,
            milliseconds
        )
    }

    private func chainNode(
        _ title: String
    ) -> some View {
        Text(title)
            .font(DesignType.caption.font.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, DesignSpacing.m.pt)
            .padding(.vertical, DesignSpacing.s.pt)
            .background(
                Color.primary.opacity(0.10),
                in: .capsule
            )
    }
}
