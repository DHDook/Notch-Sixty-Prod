import AppKit
import AudioToolbox
import AVFAudio
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

    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var customViewController: NSViewController?
    @Published private(set) var parameters: [AUParameter] = []

    private var unit: AVAudioUnit?

    init(
        slotIndex: Int,
        slot: AudioUnitRackSlotState,
        descriptor: AudioUnitComponentDescriptor
    ) {
        self.slotIndex = slotIndex
        self.slotID = slot.id
        self.descriptor = descriptor
        self.initialState = slot.opaqueFullState
    }

    func load() async {
        guard loadState == .loading, unit == nil else { return }
        do {
            let unit = try await Self.instantiate(descriptor.identity)
            if let initialState {
                try Self.restore(initialState, to: unit.auAudioUnit)
            }
            self.unit = unit
            parameters = unit.auAudioUnit.parameterTree?.allParameters ?? []
            if descriptor.hasCustomView {
                customViewController =
                    await Self.requestViewController(for: unit.auAudioUnit)
            }
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
        }
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
        objectWillChange.send()
    }

    func captureState() throws -> Data {
        guard let unit else {
            throw AudioUnitPluginEditorError.stateUnavailable
        }
        guard let state =
                unit.auAudioUnit.fullStateForDocument
                    ?? unit.auAudioUnit.fullState else {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.descriptor.name)
                        .font(.title2.bold())
                    Text(
                        "\(session.descriptor.manufacturerName) · detached transactional editor"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Slot \(session.slotIndex + 1)")
                    .font(.caption.monospacedDigit().bold())
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

            HStack {
                Label(
                    "Changes are isolated until Apply. Apply re-runs offline preparation before the live rack can change.",
                    systemImage: "shield.lefthalf.filled"
                )
                .font(.caption)
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
        .padding(18)
        .task { await session.load() }
    }

    @ViewBuilder
    private var editorContent: some View {
        switch session.loadState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Opening detached Audio Unit editor…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let reason):
            ContentUnavailableView(
                "Unable to Open Plug-in Editor",
                systemImage: "exclamationmark.triangle",
                description: Text(reason)
            )

        case .ready:
            if let controller = session.customViewController {
                AudioUnitCustomViewContainer(
                    viewController: controller
                )
            } else if session.parameters.isEmpty {
                ContentUnavailableView(
                    "No Editor Surface",
                    systemImage: "slider.horizontal.3",
                    description: Text(
                        "This Audio Unit exposes neither a custom view nor host-visible parameters."
                    )
                )
            } else {
                genericParameterEditor
            }
        }
    }

    private var genericParameterEditor: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(
                    session.parameters,
                    id: \.address
                ) { parameter in
                    VStack(alignment: .leading, spacing: 6) {
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
                            .font(.caption.monospacedDigit())
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
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct PluginRackSlotRow: View {
    let index: Int
    let slot: AudioUnitRackSlotState
    let sampleRate: Double
    let report: AudioUnitOfflinePreparationReport?
    let quarantineEntry: AudioUnitQuarantineEntry?
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

    @State private var wetDryMix: Double

    init(
        index: Int,
        slot: AudioUnitRackSlotState,
        sampleRate: Double,
        report: AudioUnitOfflinePreparationReport?,
        quarantineEntry: AudioUnitQuarantineEntry?,
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
        onClearQuarantine: (() -> Void)?
    ) {
        self.index = index
        self.slot = slot
        self.sampleRate = sampleRate
        self.report = report
        self.quarantineEntry = quarantineEntry
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
        HStack(alignment: .center, spacing: 12) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit().bold())
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

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(slot.displayName ?? "Audio Unit")
                            .font(.subheadline.weight(.semibold))

                        statusBadge

                        if let latencyFrames {
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let quarantineEntry {
                        Text(quarantineEntry.lastFailureDescription)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
                .frame(minWidth: 210, alignment: .leading)

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 7) {
                        Text("Mix")
                            .font(.caption)
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
                        .frame(width: 120)
                        .disabled(isBusy)

                        Text(
                            "\(Int((wetDryMix * 100).rounded()))%"
                        )
                        .font(.caption.monospacedDigit())
                        .frame(width: 38, alignment: .trailing)
                    }

                    HStack(spacing: 6) {
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
                        .foregroundStyle(.red)
                        .help("Remove plug-in")
                        .disabled(isBusy)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .background(
            .quaternary.opacity(0.14),
            in: .rect(cornerRadius: 12)
        )
        .onChange(of: slot.wetDryMix) { _, newValue in
            wetDryMix = newValue
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if quarantineEntry != nil {
            Text("QUARANTINED")
                .font(.caption2.bold())
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Color.orange.opacity(0.12),
                    in: .capsule
                )
        } else if report != nil {
            Text(slot.bypassed ? "PREPARED · BYPASSED" : "PREPARED")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Color.primary.opacity(0.07),
                    in: .capsule
                )
        } else {
            Text(slot.bypassed ? "BYPASSED" : "NEEDS PREP")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
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
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
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
    @ObservedObject private var engine: AudioIOEngine
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

    init(product: ProductController) {
        self.product = product
        _engine = ObservedObject(
            wrappedValue: product.audioEngine
        )
        _host = ObservedObject(
            wrappedValue: product.audioUnitHost
        )
    }

    private var processingFormat: AudioUnitRackProcessingFormat {
        let channelCount: Int
        if let profile = engine.outputDeviceProfileConfiguration,
           profile.enabled {
            channelCount = profile.programLayout.roles.count
        } else if let profile =
                    engine.headphoneDeviceProfileConfiguration,
                  profile.enabled {
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
            maximumFramesPerSlice: 4_096
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
            VStack(alignment: .leading, spacing: 22) {
                header
                signalChainCard
                scanCard
                rackCard
                catalogCard
                safetyCard
            }
            .padding(28)
            .frame(
                maxWidth: 1_100,
                alignment: .topLeading
            )
        }
        .task {
            if host.lastScanDate == nil {
                host.scan(format: processingFormat)
            }
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
                }
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
        .alert(
            "Plug-in Rack Error",
            isPresented: Binding(
                get: { commandError != nil },
                set: {
                    if !$0 { commandError = nil }
                }
            )
        ) {
            Button("OK") { commandError = nil }
        } message: {
            Text(commandError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Plug-ins")
                    .font(.largeTitle.bold())
                Text(
                    "Transactional Audio Unit hosting, live rack controls, and Content Preset state."
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("LIVE RACK")
                .font(.caption.bold())
                .tracking(1.3)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .glassEffect(
                    .regular,
                    in: .capsule
                )
        }
    }

    private var signalChainCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Signal-chain position")
                .font(.headline)

            HStack(spacing: 10) {
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
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 18)
        )
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Installed Audio Units")
                        .font(.headline)
                    Text(
                        "\(processingFormat.channelCount)-channel symmetric rack · \(processingFormat.sampleRate / 1_000, specifier: "%.1f") kHz"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if mutationInFlight {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    host.scan(format: processingFormat)
                } label: {
                    Label(
                        "Scan",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.glass)
                .disabled(mutationInFlight)
            }

            HStack(spacing: 24) {
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
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            if let lastMutationSummary {
                Label(
                    lastMutationSummary,
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let error = host.lastErrorDescription {
                Label(
                    error,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            }
        }
        .padding(18)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 18)
        )
    }

    private var rackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playback Plug-in Rack")
                        .font(.headline)
                    Text(
                        "Order, bypass, wet/dry, opaque state, and plug-in identity follow the selected Content Preset."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Text(
                    "\(host.rackConfiguration.occupiedSlotCount)/\(host.rackConfiguration.slots.count) occupied"
                )
                .font(.caption.monospacedDigit())
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
                            }
                )
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
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 18)
        )
    }

    @ViewBuilder
    private var catalogCard: some View {
        if host.lastScanDate == nil {
            ContentUnavailableView(
                "Audio Unit catalog not scanned",
                systemImage: "puzzlepiece.extension",
                description: Text(
                    "Scan to inspect installed Audio Unit effects."
                )
            )
            .frame(
                maxWidth: .infinity,
                minHeight: 220
            )
            .padding(12)
            .glassEffect(
                .regular,
                in: .rect(cornerRadius: 18)
            )
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Compatibility Catalog")
                        .font(.headline)
                    Spacer()
                    Text(
                        "\(compatibleCount) compatible with the current rack format"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if host.discoveredComponents.isEmpty {
                    Text(
                        "No registered Audio Unit effects or music effects were found."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        host.discoveredComponents.prefix(12)
                    ) { component in
                        componentRow(component)
                    }

                    if host.discoveredComponents.count > 12 {
                        Text(
                            "Use Add Plug-in to search and filter the complete catalog."
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(18)
            .glassEffect(
                .regular,
                in: .rect(cornerRadius: 18)
            )
        }
    }

    private var safetyCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    "Detached editors, bounded transitions, deterministic protection"
                )
                .font(.subheadline.weight(.semibold))
                Text(
                    "Vendor UI edits happen on a detached Audio Unit copy. Apply serializes its state, re-runs offline preparation, and only then publishes a new live generation. Removal and bypass use the bounded PR82 transition rather than additive full-tail mixing, so correlated or nonlinear tails cannot consume unbounded headroom before the final protection stage."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "lock.shield")
        }
        .padding(16)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            .quaternary.opacity(0.16),
            in: .rect(cornerRadius: 14)
        )
    }

    private func addPluginSheet(
        _ target: PluginAddTarget
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.title)
                        .font(.title2.bold())
                    Text(
                        "\(processingFormat.channelCount)-channel · \(processingFormat.sampleRate / 1_000, specifier: "%.1f") kHz"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    addTarget = nil
                }
                .disabled(mutationInFlight)
            }

            HStack(spacing: 10) {
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
            }

            Divider()

            if filteredComponents.isEmpty {
                ContentUnavailableView(
                    "No Matching Audio Units",
                    systemImage: "magnifyingglass",
                    description: Text(
                        "Adjust the search or compatibility filters."
                    )
                )
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
        .padding(18)
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

        return HStack(alignment: .top, spacing: 12) {
            Image(
                systemName:
                    compatibility.compatible
                        ? "checkmark.circle.fill"
                        : "xmark.circle"
            )
            .foregroundStyle(
                compatibility.compatible
                    ? Color.primary.opacity(0.62)
                    : Color.orange
            )
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(component.name)
                        .font(.subheadline.weight(.semibold))
                    Text(component.versionString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(
                    "\(component.manufacturerName) · \(component.typeName)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if !compatibility.compatible {
                    Text(
                        compatibility.reasons.joined(
                            separator: " "
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let quarantineEntry {
                    Text(
                        quarantineEntry.lastFailureDescription
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 6) {
                    Text(lifecycleLabel(lifecycle))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    if component.hasCustomView {
                        Label(
                            "Vendor UI",
                            systemImage: "macwindow"
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 7) {
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
        .padding(.vertical, 10)
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
            spacing: 12
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
                    : Color.orange
            )
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(component.name)
                        .font(.subheadline.weight(.semibold))
                    Text(component.versionString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(
                    "\(component.manufacturerName) · \(component.typeName)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(component.identity.fourCCSummary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)

                if !compatibility.compatible {
                    Text(
                        compatibility.reasons.joined(
                            separator: " "
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(lifecycleLabel(lifecycle))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if component.hasCustomView {
                    Label(
                        "Vendor UI",
                        systemImage: "macwindow"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 7)
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

    private func openEditor(
        slot: AudioUnitRackSlotState,
        index: Int
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
                descriptor: descriptor
            )
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
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color.primary.opacity(0.10),
                in: .capsule
            )
    }
}
