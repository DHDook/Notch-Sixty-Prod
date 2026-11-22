import AppKit
import Combine
import Foundation
import SwiftUI

struct ProductionEqualizerView: View {
    var engine: AudioIOEngine
    @ObservedObject var autoPreamp: EQAutoPreampController
    var reference: ProductionReferenceNavigator? = nil
    /// E27 S3b: EQ A/B and Listen; nil or unavailable hides the controls.
    var comparison: EQComparisonController? = nil
    var audition: EQAuditionController? = nil
    /// E27 S2b: program spectrum overlay; nil or unavailable hides the switch.
    var programAnalyser: EQProgramAnalyserController? = nil
    /// E33 S19: the saved Room Correction project behind the reference curves; nil shows none.
    var referenceProjects: RoomCorrectionProjectController? = nil
    @State private var referenceCurves: [EQReferenceCurve] = []
    @AppStorage(EQReferenceSelection.preferenceKey) private var referenceRaw = ""
    /// E32 S1: one compiled response per (bands, rate), shared by the graph and its band curves.
    @State private var responseCache = EQResponseCache.shared
    @ObservedObject private var liveOverlay = MeasurementLiveOverlayStore.shared
    @State private var selectedBandID: UUID?
    @State private var dragPreview: EQBand?
    @State private var pendingDragBand: EQBand?
    @State private var pendingPublishTask: Task<Void, Never>?
    @State private var actionError: String?
    @State private var showCompare = false
    /// E27 S1: undo and redo for edits made on this page, on the window's undo manager.
    @Environment(\.undoManager) private var undoManager
    @State private var history = EQEditHistory()
    /// E27 S2: the graph's view, ranges and band curves. Ranges and curves persist.
    @AppStorage(PreferenceKeys.Equalizer.graphYRange) private var yRangeRaw = EQGraphYRange.plusMinus24.rawValue
    @AppStorage(PreferenceKeys.Equalizer.graphXZoom) private var xZoomRaw = EQGraphXZoom.full.rawValue
    @AppStorage(PreferenceKeys.Equalizer.bandCurves) private var bandCurvesRaw = EQBandCurvesMode.selected.rawValue
    @State private var graphView: EQGraphView = .magnitude
    @State private var series: EQAnalysisSeries?
    @State private var autoMemory = EQAutoRangeMemory()
    /// E33 S1: new layout, hint, picker and wording. Off keeps today's page.
    private let enhanced = FeatureFlags().isEnabled(.eqPageEnhancements)
    @State private var pageWidth = 1_000.0
    /// E33 S2 (design 9): the one-line gesture hint, shown until dismissed or the user first works a handle.
    @State private var gestureHintVisible = EQHandleAccessibility.shouldShowHint()
    /// The sanitiser moved this band to fit its range; cleared by the next edit of the band.
    @State private var movedNote: (id: UUID, text: String)?

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Runs an EQ edit and records it as one undo step (`coalesceKey` joins repeated steps on
    /// the same field). Bypass, the edit-lane picker, A/B and audition do not go through here.
    private func recorded(coalesceKey: String? = nil, _ action: () throws -> Void) {
        let before = engine.stereoEQConfiguration
        perform(action)
        history.record(before: before, after: engine.stereoEQConfiguration, coalesceKey: coalesceKey)
    }

    /// `recorded` for an edit that finishes off the main actor (E6 G55: the Linear phase FIR design
    /// runs off main, so the Phase picker returns at once). One undo step when the edit lands.
    private func recordedOffMain(coalesceKey: String? = nil, _ action: @escaping () async throws -> Void) {
        let before = engine.stereoEQConfiguration
        Task { @MainActor in
            do {
                try await action()
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
            history.record(before: before, after: engine.stereoEQConfiguration, coalesceKey: coalesceKey)
        }
    }

    /// One band edit as one undo step. At linear phase the design runs off the main actor (E33 S11c, G97, G98); otherwise it
    /// is the plain synchronous edit.
    private func recordedBandEdit(coalesceKey: String? = nil, _ band: EQBand) {
        if engine.eqEditDesignsOffMain {
            recordedOffMain(coalesceKey: coalesceKey) { try await engine.updateEQBandOffMain(band) }
        } else {
            recorded(coalesceKey: coalesceKey) { try engine.updateEQBand(band) }
        }
    }

    private func configureHistory() {
        history.configure(
            undoManager: undoManager,
            live: { engine.stereoEQConfiguration },
            apply: { try engine.replaceStereoEQConfiguration($0) }
        )
    }

    /// A/B loudness-match failures, as a stream the banner follows (empty without A/B).
    private var comparisonErrors: AnyPublisher<String, Never> {
        comparison?.$lastError.compactMap { $0 }.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
    }

    private var configuration: StereoEQConfiguration { engine.stereoEQConfiguration }
    /// Bands in frequency order, so band numbers always follow frequency (ties keep stored order).
    private var bands: [EQBand] { Self.frequencyOrdered(configuration.editableBands) }
    private static func frequencyOrdered(_ bands: [EQBand]) -> [EQBand] {
        bands.enumerated()
            .sorted { ($0.element.frequencyHz, $0.offset) < ($1.element.frequencyHz, $1.offset) }
            .map(\.element)
    }
    private var sampleRate: Double { engine.selectedOutputDevice?.nominalSampleRate ?? 48_000 }
    private var maximumFrequency: Double { EQBandRules.maximumFrequency(sampleRate: sampleRate) }
    private var yRange: EQGraphYRange { EQGraphYRange(rawValue: yRangeRaw) ?? .plusMinus24 }
    private var xZoom: EQGraphXZoom {
        let zoom = EQGraphXZoom(rawValue: xZoomRaw) ?? .full
        return zoom == .subsonic && !enhanced ? .full : zoom
    }
    private var bandCurvesMode: EQBandCurvesMode { EQBandCurvesMode(rawValue: bandCurvesRaw) ?? .selected }
    /// The bands as drawn: the band under a drag shows its preview.
    private var shownBands: [EQBand] {
        Self.frequencyOrdered(bands.map { band in dragPreview.flatMap { $0.id == band.id ? $0 : nil } ?? band })
    }

    private struct AnalysisKey: Equatable {
        let bands: [EQBand]
        let phaseMode: EQPhaseMode
        let linearPhaseLength: EQLinearPhaseLength
        let sampleRate: Double
        let view: EQGraphView
        let zoom: EQGraphXZoom
    }

    private var analysisKey: AnalysisKey {
        AnalysisKey(
            bands: shownBands, phaseMode: configuration.phaseMode, linearPhaseLength: configuration.effectiveLinearPhaseLength,
            sampleRate: sampleRate, view: graphView, zoom: xZoom)
    }

    /// Phase, group delay, impulse and step are computed off the main thread on value types and
    /// restarted by the next edit after a 50 ms pause (design 6). Magnitude draws directly.
    private func refreshSeries(_ key: AnalysisKey) async {
        guard key.view != .magnitude else {
            series = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return }
        let upper = key.zoom.maximumFrequency(sampleRate: key.sampleRate)
        // Cancel the detached work with the task, so rapid edits do not stack up
        // large linear-phase designs (FFT buffers at high rates).
        let work = Task.detached(priority: .userInitiated) { () -> EQAnalysisSeries? in
            if Task.isCancelled { return nil }
            let analysis = EQFilterAnalysis(
                bands: key.bands, phaseMode: key.phaseMode, sampleRate: key.sampleRate, linearPhaseLength: key.linearPhaseLength)
            let grid = EQFilterAnalysis.frequencyGrid(lower: key.zoom.minimumFrequency, upper: upper, count: 360)
            return analysis.series(for: key.view, frequencies: grid)
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard let result else { return }
        guard !Task.isCancelled else { return }
        series = result
    }

    private var referenceProjectPublisher: AnyPublisher<RoomCorrectionProject?, Never> {
        referenceProjects?.$project.eraseToAnyPublisher() ?? Just(nil).eraseToAnyPublisher()
    }

    var body: some View {
        ScrollView {
            pageContent
        }
        .task(id: analysisKey) { await refreshSeries(analysisKey) }
        .onAppear {
            // E33 S4: the Dynamics page's link row asks for a band; honour it once.
            if let requested = EQBandFocusRequest.shared.take(), bands.contains(where: { $0.id == requested }) {
                selectedBandID = requested
            }
            dropStaleGroup()
            ensureSelection()
            configureHistory()
        }
        .onChange(of: undoManager.map(ObjectIdentifier.init)) { _, _ in configureHistory() }
        .onChange(of: engine.stereoEQConfiguration) { _, _ in history.observeLiveChange() }
        .onReceive(autoPreamp.$lastError.compactMap { $0 }) { actionError = $0 }
        .onReceive(referenceProjectPublisher) { project in
            referenceCurves = enhanced
                ? RoomCorrectionReferenceCurveSource(project: project).referenceCurves(now: Date()) : []
        }
        .onReceive(comparisonErrors) { actionError = $0 }
        .onChange(of: configuration.channelMode) { _, _ in resetSelectionForBank() }
        .onChange(of: configuration.editChannel) { _, _ in resetSelectionForBank() }
        .onChange(of: engine.eqGroupRoleCodes) { _, _ in dropStaleGroup() }
        .onChange(of: bands.map(\.id)) { _, _ in ensureSelection() }
        .onDisappear {
            pendingPublishTask?.cancel()
            pendingPublishTask = nil
            pendingDragBand = nil
            dragPreview = nil
            // Leaving the page ends its history and any held Listen (E27 S4, G14).
            EQPageLifecycle.leave(history: history, audition: audition)
        }
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            header
            ProductionActionErrorBanner(message: $actionError)
            if inactiveBandCount > 0 {
                Label(
                    "\(inactiveBandCount) band\(inactiveBandCount == 1 ? "" : "s") sit above Nyquist (\(sampleRate / 2_000, specifier: "%.1f") kHz) at this device rate and are skipped. They are kept and play again at a higher rate.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(StatusLevel.attention.color)
                .accessibilityIdentifier("eq.nyquist.note")
            }
            modeBar

            // E33 S20 part 2 (G39): the speaker group the lists below edit; hidden on a stereo session.
            if enhanced {
                EQGroupSelector(model: groupModel, choose: chooseGroup)
            }

            if enhanced, let reach = engine.eqReachText {
                Text(reach)
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("eq.reach.line")
            }

            if showCompare, let comparison, let audition {
                ProductionEQCompareBar(
                    comparison: comparison, audition: audition, history: history,
                    selectedBand: bands.first { $0.id == selectedBandID }, perform: { perform($0) }
                )
            }

            ProductionEQGainBar(engine: engine, autoPreamp: autoPreamp, perform: { perform($0) })

            if enhanced {
                enhancedMainArea
            } else {
                responseGraph(tall: false)
                HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
                    bandsPanel
                        .frame(minWidth: 260, maxWidth: .infinity)
                    bandEditorPane
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 320)
                }
                .frame(height: 250)
            }
        }
        .padding(.horizontal, DesignSpacing.l.pt)
        .padding(.vertical, DesignSpacing.s.pt)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { pageWidth = $0 }
        .modifier(EQClipboardCommandsModifier(enabled: enhanced, commands: transferCommands))
    }

    /// Owner layout of 21 Nov 2026: the response graph takes the left column at full height; the band list sits
    /// above a one-column band editor on the right. Below the breakpoint the three stack: graph, list, editor.
    @ViewBuilder
    private var enhancedMainArea: some View {
        let wide = EQEditorLayout.columns(pageWidth: pageWidth) == .two
        if wide {
            HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
                responseGraph(tall: true)
                enhancedSidePanels
                    .frame(width: EQEditorLayout.listWidth(pageWidth: pageWidth))
            }
        } else {
            VStack(spacing: DesignSpacing.m.pt) {
                responseGraph(tall: false)
                enhancedSidePanels
            }
        }
    }

    private var enhancedSidePanels: some View {
        VStack(spacing: DesignSpacing.m.pt) {
            bandsPanel
                .frame(height: EQEditorLayout.listHeight(bandCount: bands.count))
            bandEditorPane(columns: .one)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if !enhanced {
                Text("Static and Dynamic EQ share one band model. Drag a band on the response graph or edit it in the Bands panel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(activeBandCount) ACTIVE")
                .font(DesignType.caption.font.bold())
                .tracking(1.1)
                .foregroundStyle(.secondary)
        }
    }

    /// E33 S20 part 2: the chips for the running layout (empty on a stereo session) and the group being edited.
    private var groupModel: EQGroupSelectorModel {
        EQGroupSelectorModel.make(
            configuration: configuration, shape: engine.dynamicsSessionDescription?.shape, sampleRate: sampleRate)
    }
    private var editingGroup: Bool { enhanced && configuration.editGroupKey != nil }

    private func chooseGroup(_ group: EQChannelGroup?) {
        audition?.stop()
        perform { try engine.setEQEditGroup(group) }
        resetSelectionForBank()
    }

    /// A group chosen under another layout means nothing now: back to All.
    private func dropStaleGroup() {
        guard configuration.editGroupKey != nil,
              configuration.editGroup(roleCodes: engine.eqGroupRoleCodes) == nil else { return }
        chooseGroup(nil)
    }

    private var activeBandCount: Int { configuration.activeBandCount(sampleRate: sampleRate) }
    private var inactiveBandCount: Int { configuration.aboveNyquistBandCount(sampleRate: sampleRate) }

    private var modeBar: some View {
        GlassEffectContainer(spacing: DesignSpacing.m.pt) {
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                // One row: Channels, Phase (with its status caption and the reach line when they fit), then
                // Compare over Bypass. Narrower windows drop the captions, then wrap the groups.
                ViewThatFits(in: .horizontal) {
                    modeRow(captions: true)
                    modeRow(captions: false)
                    VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                        HStack(alignment: .center, spacing: DesignSpacing.l.pt) { channelsGroup; Spacer(minLength: 8); switchesGroup }
                        phaseGroup(caption: false)
                    }
                }
                if let note = engine.unpairedEQLaneNote {
                    Text(note)
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, DesignSpacing.m.pt)
            .padding(.vertical, DesignSpacing.s.pt)
            .designSurface(.medium)
        }
    }

    private func modeRow(captions: Bool) -> some View {
        HStack(alignment: .center, spacing: DesignSpacing.l.pt) {
            channelsGroup
            phaseGroup(caption: captions)
            Spacer(minLength: 8)
            switchesGroup
        }
    }

    private func inlineLabel(_ text: String) -> some View {
        Text(text)
            .font(DesignType.caption.font.bold())
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var channelsGroup: some View {
        HStack(spacing: DesignSpacing.s.pt) {
            inlineLabel("CHANNELS")
            Picker("Channels", selection: Binding(
                get: { configuration.channelMode },
                set: { mode in recorded { try engine.setEQChannelMode(mode) } }
            )) {
                ForEach(EQChannelMode.allCases) { mode in Text(mode.displayName).tag(mode) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(editingGroup)

            if configuration.channelMode != .linked, !editingGroup {
                Picker("Edit Channel", selection: Binding(
                    get: { configuration.editChannel },
                    set: { engine.setEQEditChannel($0) }
                )) {
                    ForEach(editChannels) { channel in Text(channel.displayName).tag(channel) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    private func phaseGroup(caption: Bool) -> some View {
        HStack(spacing: DesignSpacing.s.pt) {
            inlineLabel("PHASE")
            phasePicker
            if enhanced, configuration.phaseMode == .linearPhase {
                EQLinearPhaseLengthControl(
                    engine: engine, configuration: configuration, sampleRate: sampleRate
                ) { length in recordedOffMain { try await engine.setEQLinearPhaseLengthOffMain(length) } }
            }
            if caption {
                responseCaption
            }
        }
    }

    private var switchesGroup: some View {
        HStack(spacing: DesignSpacing.m.pt) {
            if comparison != nil, audition != nil {
                Toggle("Compare", isOn: $showCompare)
                    .toggleStyle(.switch)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Toggle("Bypass", isOn: Binding(
                get: { configuration.bypassed },
                set: { bypassed in perform { try engine.setEQBypassed(bypassed) } }
            ))
            .toggleStyle(.switch)
            .fixedSize(horizontal: true, vertical: false)
        }
        .layoutPriority(1)
    }

    private var phasePicker: some View {
        Picker("Phase", selection: Binding(
            get: { configuration.phaseMode },
            set: { mode in recordedOffMain { try await engine.setEQPhaseModeOffMain(mode) } }
        )) {
            ForEach(EQPhaseMode.allCases) { mode in Text(mode.displayName).tag(mode) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var responseCaption: some View {
        Text("\(configuration.phaseMode.displayName) · \(activeLaneLabel) · \(sampleRate / 1_000, specifier: "%.1f") kHz")
            .font(DesignType.caption.font.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private func responseGraph(tall: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            graphControls

            let shown = shownBands
            let program = responseCache.program(bands: shown, sampleRate: sampleRate)
            let geometry = graphGeometry(program: program)
            ProductionEQResponseGraph(
                geometry: geometry,
                graphView: graphView,
                series: series,
                curvesMode: bandCurvesMode,
                referenceCurves: EQReferenceSelection.visible(
                    referenceCurves, chosen: EQReferenceSelection.kinds(from: referenceRaw)),
                otherLane: EQBandCurves.otherLane(in: configuration),
                bands: bands,
                selectedBandID: selectedBandID,
                previewBand: dragPreview,
                sampleRate: sampleRate,
                bypassed: configuration.bypassed,
                onSelect: { selectedBandID = $0; dismissGestureHint() },
                onPreview: { band in
                    // Option-press on a handle auditions that band until release.
                    if let audition, audition.active == nil,
                       NSEvent.modifierFlags.contains(.option) {
                        audition.start(band: band)
                    }
                    if !history.isGestureOpen { history.beginGesture(before: engine.stereoEQConfiguration) }
                    selectedBandID = band.id
                    dragPreview = band
                    scheduleCoalescedPublish(band)
                },
                onCommit: { band in
                    audition?.stop()
                    pendingPublishTask?.cancel()
                    pendingPublishTask = nil
                    pendingDragBand = nil
                    let sanitized = sanitize(band)
                    dragPreview = nil
                    if engine.eqEditDesignsOffMain {
                        // The design runs off the main actor; the gesture ends when the edit lands (G97).
                        Task { @MainActor in
                            do { try await engine.updateEQBandOffMain(sanitized); actionError = nil } catch {
                                actionError = error.localizedDescription
                            }
                            history.endGesture(after: engine.stereoEQConfiguration)
                        }
                    } else {
                        perform { try engine.updateEQBand(sanitized) }
                        history.endGesture(after: engine.stereoEQConfiguration)
                    }
                },
                onNudge: { axis, direction, step in nudgeSelectedBand(axis, direction, step) },
                onDeleteSelected: { if let id = selectedBandID { removeBand(id) } },
                onScaleQ: { id, scale in scaleQ(of: id, scale) },
                onAddBand: { frequency, gain in addBand(atFrequency: frequency, gain: gain) },
                onResetBand: { id in resetBand(id) },
                enhancedAccessibility: enhanced,
                onAdjustFrequency: { id, direction in adjustBandFrequency(id, direction) },
                onAdjustGain: { id, action in adjustBandGain(id, action) },
                rtaOverlay: liveOverlay.showsRTA ? liveOverlay.rtaCurve : nil,
                programAnalyser: programAnalyser,
                program: program,
                programFor: { [responseCache, sampleRate] bands in responseCache.program(bands: bands, sampleRate: sampleRate) }
            )
            .frame(
                minHeight: tall ? 320 : 200, idealHeight: tall ? 420 : 280,
                maxHeight: tall ? 460 : 340)

            graphFooter

            if let note = graphView == .magnitude ? nil : series?.note {
                Label(note, systemImage: "info.circle")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
            if graphView != .magnitude {
                Text("Bands are edited on the Magnitude view or in the Bands list.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }

            if bands.contains(where: { $0.enabled && $0.type == .fir }) {
                Label(
                    "Per-band FIR processing remains active, but imported FIR magnitude is intentionally omitted from this first live curve rather than approximated inaccurately.",
                    systemImage: "info.circle"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            }
        }
        .padding(DesignSpacing.m.pt)
        .designSurface(.medium)
    }

    /// One row: view picker on the left, option controls on the right. When they do not fit, the options wrap to a
    /// second line, so nothing scrolls sideways. The frequency range sits under the graph (`graphFooter`).
    private var graphControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignSpacing.m.pt) {
                graphViewPicker
                Spacer(minLength: 8)
                graphOptionControls
            }
            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                graphViewPicker
                HStack(spacing: DesignSpacing.m.pt) {
                    Spacer(minLength: 0)
                    graphOptionControls
                }
            }
        }
    }

    /// The gesture hint (until dismissed) with the frequency range at the right of the same line.
    private var graphFooter: some View {
        HStack(spacing: DesignSpacing.m.pt) {
            if enhanced && gestureHintVisible && graphView == .magnitude {
                HStack(spacing: DesignSpacing.s.pt) {
                    Image(systemName: "hand.point.up.left")
                    Text(EQHandleAccessibility.hintText)
                    Button("Got it") { dismissGestureHint() }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("eq.graph.hint.dismiss")
                }
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("eq.graph.hint")
            }
            Spacer(minLength: 8)
            graphZoomPicker
        }
    }

    private var graphViewPicker: some View {
        Picker("View", selection: $graphView) {
            ForEach(EQGraphView.allCases) { view in Text(view.displayName).tag(view) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityLabel("Graph view")
    }

    private var graphZoomPicker: some View {
        Picker("Frequencies", selection: $xZoomRaw) {
            ForEach(EQGraphXZoom.allCases.filter { enhanced || $0 != .subsonic }) { zoom in Text(zoom.displayName).tag(zoom.rawValue) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(!graphView.isFrequencyDomain)
        .accessibilityLabel("Frequency range")
    }

    private var graphOptionControls: some View {
        HStack(spacing: DesignSpacing.m.pt) {
            if let programAnalyser {
                EQProgramAnalyserSwitch(analyser: programAnalyser)
            }

            if enhanced, !referenceCurves.isEmpty {
                EQReferenceCurveMenu(curves: referenceCurves, raw: $referenceRaw)
                    .disabled(graphView != .magnitude)
            }

            // E33 S21: fit bands to a saved measurement. The proposal changes nothing until the user keeps it.
            if enhanced, referenceCurves.contains(where: { $0.kind != .target }) {
                EQFitBandsButton(
                    curves: referenceCurves, sampleRate: sampleRate, existingBandCount: bands.count,
                    keep: { fitted in
                        recorded {
                            var next = engine.stereoEQConfiguration
                            next.replaceEditableBands(fitted)
                            try engine.replaceStereoEQConfiguration(next)
                        }
                        selectedBandID = bands.first?.id
                    })
            }

            Picker("Band curves", selection: $bandCurvesRaw) {
                ForEach(EQBandCurvesMode.allCases) { mode in Text(mode.displayName).tag(mode.rawValue) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(graphView != .magnitude)
            .help("Band curves: draw the selected band, every band or none under the total curve")

            Picker("Range", selection: $yRangeRaw) {
                ForEach(EQGraphYRange.allCases) { range in Text(range.displayName).tag(range.rawValue) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(graphView != .magnitude)
            .help("Visible gain range; Auto fits the largest response plus 3 dB")
        }
    }

    /// The graph's coordinate maps for the chosen zoom and gain range. Auto widens during a
    /// drag but only narrows once the drag ends.
    private func graphGeometry(program: [EQResponseSection]) -> EQGraphGeometry {
        var half = yRange.fixedHalfRange ?? 24
        if graphView == .magnitude, yRange == .auto {
            let upper = xZoom.maximumFrequency(sampleRate: sampleRate)
            let grid = EQFilterAnalysis.frequencyGrid(lower: xZoom.minimumFrequency, upper: upper, count: 180)
            let peak = grid.reduce(0.0) { max($0, abs(ProductionEQResponseMath.responseDB(program: program, sampleRate: sampleRate, frequencyHz: $1))) }
            half = autoMemory.resolve(.auto, peakMagnitudeDB: peak, growOnly: dragPreview != nil)
        }
        return EQGraphGeometry(sampleRate: sampleRate, zoom: xZoom, visibleDB: -half...half)
    }

    // MARK: Bands panel

    private var bandsPanel: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            bandsPanelHeader
                .padding(.horizontal, DesignSpacing.s.pt)
            if enhanced { EQMatchedFiltersOffer(bands: bands, onUse: useMatchedFilters) }

            if bands.isEmpty {
                ContentUnavailableView {
                    Label("No EQ Bands", systemImage: "slider.horizontal.3")
                } description: {
                    Text("Add a band to begin shaping the response.")
                } actions: {
                    Button { addBand() } label: { Label("Add Band", systemImage: "plus") }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("eq.bands.empty.add")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: DesignSpacing.xs.pt) {
                            ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                                bandRow(index: index, band: band)
                                    .id(band.id)
                            }
                        }
                        .padding(.horizontal, DesignSpacing.xs.pt)
                        .padding(.bottom, DesignSpacing.s.pt)
                    }
                    .onChange(of: selectedBandID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) }
                    }
                    .onAppear {
                        if let selectedBandID { proxy.scrollTo(selectedBandID, anchor: .top) }
                    }
                }
            }
        }
        .padding(DesignSpacing.m.pt)
        .frame(maxHeight: .infinity, alignment: .top)
        .designSurface(.large)
    }

    private var bandsPanelHeader: some View {
        HStack(spacing: DesignSpacing.s.pt) {
            Text("Bands").font(DesignType.sectionTitle.font)
            Text(EQBandPanelModel.countText(count: bands.count, maximum: EQConfiguration.maximumBandCount))
                .font(DesignType.caption.font.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if enhanced {
                EQTransferMenu(commands: transferCommands, canAddBands: bands.count < EQConfiguration.maximumBandCount)
            }
            Button { selectAdjacentBand(offset: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("[", modifiers: [.command])
            .help("Previous band (⌘[)")
            .accessibilityLabel("Previous band")
            .accessibilityIdentifier("eq.bands.previous")
            .disabled(bands.count < 2)
            Button { selectAdjacentBand(offset: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("]", modifiers: [.command])
            .help("Next band (⌘])")
            .accessibilityLabel("Next band")
            .accessibilityIdentifier("eq.bands.next")
            .disabled(bands.count < 2)
            Button {
                addBand()
            } label: {
                Label("Add Band", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("Add EQ band (⇧⌘N)")
            .accessibilityIdentifier("eq.bands.add")
            .disabled(bands.count >= EQConfiguration.maximumBandCount)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("eq.bands.header")
    }

    @ViewBuilder
    private func bandRow(index: Int, band storedBand: EQBand) -> some View {
        let isSelected = selectedBandID == storedBand.id
        let band = (dragPreview?.id == storedBand.id ? dragPreview : nil) ?? storedBand
        let nyquistLimit = nyquistLimit(of: band)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                selectedBandID = band.id
            } label: {
                HStack(spacing: DesignSpacing.s.pt) {
                    Text("\(index + 1)")
                        .font(DesignType.caption.font.bold().monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .frame(width: 22, height: 22)
                        .background(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.22),
                            in: .circle
                        )
                    Text(band.type.displayName)
                        .font(DesignType.caption.font.bold())
                        .lineLimit(1)
                    if band.dynamic.enabled {
                        Text("DYN")
                            .font(DesignType.caption.font)
                            .padding(.horizontal, DesignSpacing.xs.pt).padding(.vertical, DesignSpacing.xs.pt)
                            .background(StatusLevel.attention.color.opacity(0.28), in: .capsule)
                    }
                    Spacer(minLength: 4)
                    Text(EQBandPanelModel.frequencyText(band.frequencyHz))
                        .font(DesignType.caption.font.monospacedDigit())
                    Text(EQBandPanelModel.gainText(band.gainDB))
                        .font(DesignType.caption.font.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 52, alignment: .trailing)
                    Circle()
                        .fill(!band.enabled ? Color.secondary.opacity(0.35) : (nyquistLimit == nil ? StatusLevel.good.color : StatusLevel.attention.color))
                        .frame(width: 7, height: 7)
                }
                .frame(minHeight: 34)
                .padding(.horizontal, DesignSpacing.s.pt)
                .contentShape(Rectangle())
                .opacity(band.enabled ? 1 : 0.55)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(EQBandPanelModel.accessibilityLabel(number: index + 1, band: band))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("eq.bands.row.\(index + 1)")
            if let nyquistLimit {
                Text(EQBandRules.nyquistText(limitHz: nyquistLimit))
                    .font(DesignType.caption.font)
                    .foregroundStyle(StatusLevel.attention.color)
                    .padding(.horizontal, 38)
                    .padding(.bottom, DesignSpacing.xs.pt)
                    .accessibilityIdentifier("eq.bands.row.\(index + 1).nyquist")
            }
            if enhanced, let note = EQSubsonicNote.note(for: band) {
                Text(note)
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 38)
                    .padding(.bottom, DesignSpacing.xs.pt)
                    .accessibilityIdentifier("eq.bands.row.\(index + 1).subsonic")
            }
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
            in: .rect(cornerRadius: DesignRadius.medium.pt)
        )
    }

    /// The Nyquist limit when `band` is enabled but skipped above it; nil otherwise.
    private func nyquistLimit(of band: EQBand) -> Double? {
        guard band.enabled, case .aboveNyquist(let limit) = EQBandRules.renderState(band, sampleRate: sampleRate) else { return nil }
        return limit
    }

    private var bandEditorPane: some View { bandEditorPane(columns: .one) }

    private func bandEditorPane(columns: EQEditorLayout.Columns) -> some View {
        Group {
            if let id = selectedBandID,
               let index = bands.firstIndex(where: { $0.id == id }),
               let binding = selectedBandBinding(for: id) {
                let band = binding.wrappedValue
                if enhanced {
                    // Owner layout of 21 Nov 2026: one column, sized to its content, below the band list.
                    VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                        editorHeader(number: index + 1, band: band, binding: binding)
                        staticControls(band: band, binding: binding)
                        Divider()
                        dynamicColumn(band: band, binding: binding)
                    }
                    .padding(DesignSpacing.m.pt)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .accessibilityIdentifier("eq.bands.editor.oneColumn")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
                            editorHeader(number: index + 1, band: band, binding: binding)
                            staticControls(band: band, binding: binding)
                            Divider()
                            dynamicColumn(band: band, binding: binding)
                        }
                        .padding(DesignSpacing.l.pt)
                    }
                }
            } else {
                Text(bands.isEmpty ? "Add a band to edit it here." : "Select a band to edit it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(DesignSpacing.l.pt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: enhanced ? nil : .infinity)
        .designSurface(.large)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("eq.bands.editor")
    }

    @ViewBuilder
    private func dynamicColumn(band: EQBand, binding: Binding<EQBand>) -> some View {
        if editingGroup {
            Label("Speaker group bands are ordinary filters. Dynamic EQ is available under All.", systemImage: "bolt.slash")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        } else if band.type.supportsDynamicEQ {
            dynamicControls(band: band, binding: binding)
        } else {
            Label("Dynamic EQ is unavailable for this filter type.", systemImage: "bolt.slash")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
    }

    private func editorHeader(number: Int, band: EQBand, binding: Binding<EQBand>) -> some View {
        // The switch sits beside the section title it controls, as in
        // System Settings, so its position alone reads as on or off.
        HStack {
            Text("Band \(number)").font(DesignType.sectionTitle.font)
            Text(band.type.displayName).font(DesignType.caption.font).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Toggle("Band", isOn: binding.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .help(band.enabled ? "Band is on. Click to turn it off." : "Band is off. Click to turn it on.")
            Button(role: .destructive) {
                removeBand(band.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.delete, modifiers: [.command])
            .help("Remove selected band (⌘⌫)")
        }
    }

    /// One labelled control. Enhanced pages use a compact inline label so two related items can share a row;
    /// the legacy page keeps the full-width `LabeledContent`.
    @ViewBuilder
    private func item<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        if enhanced {
            HStack(spacing: DesignSpacing.s.pt) { Text(title); content() }
        } else {
            LabeledContent(title) { content() }
        }
    }

    @ViewBuilder
    private func item<L: View, C: View>(@ViewBuilder label: () -> L, @ViewBuilder content: () -> C) -> some View {
        if enhanced {
            HStack(spacing: DesignSpacing.s.pt) { label(); content() }
        } else {
            LabeledContent { content() } label: { label() }
        }
    }

    /// Related controls on one row when they fit, stacked otherwise (screen-fit rule: no sideways scroll).
    @ViewBuilder
    private func pair<A: View, B: View, C: View>(
        @ViewBuilder _ first: () -> A, @ViewBuilder second: () -> B, @ViewBuilder third: () -> C = { EmptyView() }
    ) -> some View {
        if enhanced {
            let a = first()
            let b = second()
            let c = third()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSpacing.m.pt) { a; b; c; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: DesignSpacing.s.pt) { a; b; c }
            }
        } else {
            first()
            second()
            third()
        }
    }

    @ViewBuilder
    private func staticControls(band: EQBand, binding: Binding<EQBand>) -> some View {
        VStack(alignment: .leading, spacing: enhanced ? DesignSpacing.s.pt : DesignSpacing.l.pt) {
            pair {
                item("Filter") {
                    Picker("Filter", selection: binding.type) {
                        if enhanced {
                            ForEach(EQFilterPickerModel.sections, id: \.title) { section in
                                Section(section.title) {
                                    ForEach(section.types) { type in filterOption(type, band: band) }
                                }
                            }
                        } else {
                            ForEach(EQFilterType.allCases) { type in filterOption(type, band: band) }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            } second: {
                if band.type == .peaking {
                    Toggle("Constant-Q peak", isOn: binding.constantQ).toggleStyle(.switch)
                } else if band.type.supportsSlope {
                    item("Slope") {
                        Picker("Slope", selection: binding.slope) {
                            ForEach(EQFilterSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                        }
                        .labelsHidden()
                        .frame(minWidth: enhanced ? 110 : 150)
                    }
                }
            }

            pair {
                item("Frequency") {
                    HStack(spacing: DesignSpacing.s.pt) {
                        EQNumberField(
                            title: "Frequency",
                            field: .frequency,
                            value: band.frequencyHz,
                            band: band,
                            maximumFrequency: maximumFrequency,
                            width: enhanced ? 72 : 110,
                            identifier: "eq.bands.editor.frequency"
                        ) { newValue, isStep in
                            commitField(band, key: isStep ? "field.frequency" : nil) { $0.frequencyHz = newValue }
                        }
                        .disabled(band.type == .fir)
                        Text("Hz").foregroundStyle(.secondary).fixedSize()
                    }
                }
            } second: {
                item("Gain") {
                    HStack(spacing: DesignSpacing.s.pt) {
                        EQNumberField(
                            title: "Gain",
                            field: .gain,
                            value: band.gainDB,
                            band: band,
                            maximumFrequency: maximumFrequency,
                            width: enhanced ? 56 : 90,
                            identifier: "eq.bands.editor.gain"
                        ) { newValue, isStep in
                            commitField(band, key: isStep ? "field.gain" : nil) { $0.gainDB = newValue }
                        }
                        .disabled(!band.type.productionHasGainControl)
                        Text("dB").foregroundStyle(.secondary).fixedSize()
                    }
                }
            } third: {
                item(label: {
                    HStack(spacing: DesignSpacing.xs.pt) {
                        Text("Q")
                        if let reference {
                            ProductionReferenceHelpButton(
                                navigator: reference,
                                articleID: "equalizer",
                                formulaID: "biquad",
                                destination: .dspReference,
                                label: "Open EQ filter math in DSP Reference"
                            )
                            .buttonStyle(.borderless)
                        }
                    }
                }) {
                    EQNumberField(
                        title: "Q",
                        field: .q,
                        value: band.q,
                        band: band,
                        maximumFrequency: maximumFrequency,
                        width: enhanced ? 56 : 90,
                        identifier: "eq.bands.editor.q"
                    ) { newValue, isStep in
                        commitField(band, key: isStep ? "field.q" : nil) { $0.q = newValue }
                    }
                    .disabled(!band.type.productionHasQControl)
                }
            }

            if band.type == .linkwitzTransform {
                pair {
                    item("Target Frequency") {
                        HStack(spacing: DesignSpacing.s.pt) {
                            EQNumberField(
                                title: "Target Frequency",
                                field: .linkwitzTargetFrequency,
                                value: band.linkwitzTargetHz,
                                band: band,
                                maximumFrequency: maximumFrequency,
                                width: 110,
                                identifier: "eq.bands.editor.linkwitzTargetFrequency"
                            ) { newValue, isStep in
                                commitField(band, key: isStep ? "field.linkwitzTargetHz" : nil) { $0.linkwitzTargetHz = newValue }
                            }
                            Text("Hz").foregroundStyle(.secondary).fixedSize()
                        }
                    }
                } second: {
                    item("Target Q") {
                        EQNumberField(
                            title: "Target Q",
                            field: .linkwitzTargetQ,
                            value: band.linkwitzTargetQ,
                            band: band,
                            maximumFrequency: maximumFrequency,
                            identifier: "eq.bands.editor.linkwitzTargetQ"
                        ) { newValue, isStep in
                            commitField(band, key: isStep ? "field.linkwitzTargetQ" : nil) { $0.linkwitzTargetQ = newValue }
                        }
                    }
                }
            }

            if band.type == .fir {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text(band.firKernel?.name ?? "No FIR kernel loaded")
                        .font(.subheadline.bold())
                    if let taps = band.firKernel?.taps.count {
                        Text("\(taps) taps").font(DesignType.caption.font.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func filterOption(_ type: EQFilterType, band: EQBand) -> some View {
        Text(type.displayName)
            .tag(type)
            .disabled(
                (editingGroup && (type == .fir || type == .linkwitzTransform))
                    || (type == .fir && band.firKernel == nil)
                    || (type == .allPass && configuration.phaseMode != .minimumPhase)
            )
    }

    @ViewBuilder
    private func dynamicControls(band: EQBand, binding: Binding<EQBand>) -> some View {
        VStack(alignment: .leading, spacing: enhanced ? DesignSpacing.s.pt : DesignSpacing.l.pt) {
            HStack {
                Text("Dynamic EQ").font(DesignType.sectionTitle.font)
                Spacer()
                Toggle("Dynamic", isOn: binding.dynamic.enabled).toggleStyle(.switch)
            }
            if enhanced {
                Text(EQDynamicHint.rangeText)
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("eq.bands.editor.dynamicHint")
            }
            if enhanced, let movedNote, movedNote.id == band.id {
                Text(movedNote.text)
                    .font(DesignType.caption.font)
                    .foregroundStyle(StatusLevel.attention.color)
                    .accessibilityIdentifier("eq.bands.editor.movedNote")
            }

            if band.dynamic.enabled {
                pair {
                    item("Direction") {
                        Picker("Direction", selection: binding.dynamic.direction) {
                            ForEach(DynamicEQDirection.allCases) { direction in Text(direction.displayName).tag(direction) }
                        }
                        .labelsHidden().frame(minWidth: enhanced ? 110 : 150)
                        .disabled(band.type == .notch)
                    }
                } second: {
                    item("Detector") {
                        Picker("Detector", selection: binding.dynamic.detectorMode) {
                            ForEach(DynamicEQDetectorMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                        }
                        .labelsHidden().frame(minWidth: enhanced ? 90 : 120)
                    }
                }

                pair {
                    metricField("Threshold", .threshold, value: binding.dynamic.thresholdDB, suffix: "dB")
                } second: {
                    metricField("Ratio", .ratio, value: binding.dynamic.ratio, suffix: ":1")
                } third: {
                    metricField("Max Cut", .maxCut, value: binding.dynamic.rangeDB, suffix: "dB")
                }
                pair {
                    metricField("Attack", .attack, value: binding.dynamic.attackMs, suffix: "ms")
                } second: {
                    metricField("Release", .release, value: binding.dynamic.releaseMs, suffix: "ms")
                } third: {
                    if band.dynamic.detectorMode == .rms {
                        metricField("RMS Window", .rmsWindow, value: binding.dynamic.rmsWindowMs, suffix: "ms")
                    }
                }

                if band.dynamic.direction != .cutOnly {
                    Text("Boost").font(.subheadline.bold()).padding(.top, DesignSpacing.xs.pt)
                    pair {
                        metricField("Boost Threshold", .boostThreshold, value: binding.dynamic.boostThresholdDB, suffix: "dB")
                    } second: {
                        metricField("Boost Ratio", .boostRatio, value: binding.dynamic.boostRatio, suffix: ":1")
                    } third: {
                        metricField("Max Boost", .maxBoost, value: binding.dynamic.maxBoostDB, suffix: "dB")
                    }
                }
            } else {
                Text("Enable Dynamic to add level-dependent correction to this ordinary EQ band. Static gain remains owned by the band itself.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metricField(_ label: String, _ metric: EQDynamicMetric, value: Binding<Double>, suffix: String) -> some View {
        item(label) {
            HStack(spacing: DesignSpacing.s.pt) {
                EQDynamicMetricField(title: label, metric: metric, value: value, width: enhanced ? 64 : 92)
                Text(suffix).foregroundStyle(.secondary).fixedSize()
            }
        }
    }

    private var editChannels: [EQEditChannel] {
        switch configuration.channelMode {
        case .linked: return [.linked]
        case .independent: return [.left, .right]
        case .midSide: return [.mid, .side]
        }
    }

    private var activeLaneLabel: String {
        configuration.channelMode == .linked ? configuration.channelMode.displayName : configuration.editChannel.displayName
    }

    private func selectedBandBinding(for id: UUID) -> Binding<EQBand>? {
        guard bands.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: {
                if let dragPreview, dragPreview.id == id { return dragPreview }
                return engine.stereoEQConfiguration.editableBands.first(where: { $0.id == id })
                    ?? EQBand(id: id, enabled: false)
            },
            set: { updated in
                pendingPublishTask?.cancel()
                pendingPublishTask = nil
                pendingDragBand = nil
                dragPreview = nil
                recordedBandEdit(fitted(updated))
            }
        )
    }

    /// Applies one field edit to a band (typed value or arrow step) as one undo step.
    private func commitField(_ band: EQBand, key: String?, _ change: (inout EQBand) -> Void) {
        var updated = band
        change(&updated)
        pendingPublishTask?.cancel()
        pendingPublishTask = nil
        pendingDragBand = nil
        dragPreview = nil
        recordedBandEdit(coalesceKey: key.map { "\($0).\(band.id)" }, fitted(updated))
    }

    /// E33 S2: Import, Export, copy, paste and "Copy lane to...". Each change is one undo step.
    private var transferCommands: EQTransferCommands {
        EQTransferCommands(
            current: { engine.stereoEQConfiguration },
            apply: { new in
                recorded { try engine.replaceStereoEQConfiguration(new) }
                if !bands.contains(where: { $0.id == selectedBandID }) { selectedBandID = bands.first?.id }
            },
            selectedBandID: { selectedBandID },
            inputPreampDB: { engine.gainConfiguration.inputPreampDB },
            applyPreampDB: { value in try autoPreamp.setManual(value) },
            reportError: { actionError = $0 }
        )
    }

    private func dismissGestureHint() {
        guard gestureHintVisible else { return }
        gestureHintVisible = false
        EQHandleAccessibility.markHintShown()
    }

    private func addBand() {
        let band = EQMatchedFiltersPolicy.newBand(EQBand(frequencyHz: suggestedFrequency(), q: 1.0), enhanced: enhanced)
        let before = engine.stereoEQConfiguration
        do {
            try engine.addEQBand(band)
            selectedBandID = band.id
            history.record(before: before, after: engine.stereoEQConfiguration)
        } catch {
            actionError = "Could not add the band: \(error.localizedDescription)"
        }
    }


    /// E33 S26: switch every eligible cookbook band to the matched design as one undoable edit (an unsaved change).
    private func useMatchedFilters() {
        let targets = EQMatchedFiltersPolicy.eligible(bands)
        guard !targets.isEmpty else { return }
        var next = engine.stereoEQConfiguration
        for var band in targets {
            band.filterMethod = .matched
            next.updateEditableBand(band)
        }
        if engine.eqEditDesignsOffMain {
            recordedOffMain { try await engine.applyEQConfigurationOffMain(next) }
        } else {
            recorded { try engine.replaceStereoEQConfiguration(next) }
        }
    }

    private func removeBand(_ id: UUID) {
        let previousBands = bands
        let before = engine.stereoEQConfiguration
        do {
            try engine.removeEQBand(id: id)
            selectedBandID = EQBandPanelModel.selectionAfterRemoving(
                removed: id,
                selected: selectedBandID,
                bandsBefore: previousBands
            )
            history.record(before: before, after: engine.stereoEQConfiguration)
        } catch {
            actionError = "Could not remove the band: \(error.localizedDescription)"
        }
    }

    // MARK: Graph gestures (E27 S1)

    private func band(withID id: UUID) -> EQBand? {
        bands.first(where: { $0.id == id })
    }

    /// Arrow keys on the focused graph: left/right frequency, up/down gain.
    private func nudgeSelectedBand(_ axis: EQGraphKeyAxis, _ direction: EQNudge.Direction, _ step: EQNudge.Step) {
        guard let id = selectedBandID, var edited = band(withID: id) else { return }
        switch axis {
        case .frequency:
            guard edited.type != .fir else { return }
            edited.frequencyHz = EQNudge.nudged(
                edited.frequencyHz, field: .frequency, direction: direction, step: step,
                band: edited, maximumFrequency: maximumFrequency
            )
        case .gain:
            guard edited.type.productionHasGainControl else { return }
            edited.gainDB = EQNudge.nudged(
                edited.gainDB, field: .gain, direction: direction, step: step,
                band: edited, maximumFrequency: maximumFrequency
            )
        }
        commitField(edited, key: "nudge.\(axis)") { _ in }
    }

    /// E33 S2: a VoiceOver frequency step on a handle (the arrow-key table), one undo step per action.
    private func adjustBandFrequency(_ id: UUID, _ direction: EQNudge.Direction) {
        guard let band = band(withID: id) else { return }
        selectedBandID = id
        let edited = EQHandleAccessibility.frequency(band, direction: direction, maximumFrequency: maximumFrequency)
        guard edited != band else { return }
        commitField(edited, key: "ax.frequency") { _ in }
    }

    /// E33 S2: a VoiceOver gain action on a handle.
    private func adjustBandGain(_ id: UUID, _ action: EQHandleAccessibility.GainAction) {
        guard let band = band(withID: id) else { return }
        selectedBandID = id
        let edited = EQHandleAccessibility.gain(band, action: action, maximumFrequency: maximumFrequency)
        guard edited != band else { return }
        commitField(edited, key: "ax.gain") { _ in }
    }

    /// Scroll or pinch over a handle. Does nothing for filters without a Q.
    private func scaleQ(of id: UUID, _ scale: EQGraphQScale) {
        guard var edited = band(withID: id), edited.type.productionHasQControl else { return }
        let limits = EQValueParser.range(for: .q, band: edited, maximumFrequency: maximumFrequency)
        switch scale {
        case .notches(let notches): edited.q = EQNudge.q(edited.q, scrollNotches: notches, range: limits)
        case .magnification(let value): edited.q = EQNudge.q(edited.q, magnification: value, range: limits)
        }
        guard edited.q != band(withID: id)?.q else { return }
        selectedBandID = id
        commitField(edited, key: "scroll.q") { _ in }
    }

    /// Double-click on empty graph: a peaking band at that frequency and gain, Q 1.0.
    private func addBand(atFrequency frequency: Double, gain: Double) {
        guard bands.count < EQConfiguration.maximumBandCount else {
            actionError = "The EQ is at its limit of \(EQConfiguration.maximumBandCount) bands. Remove a band to add another."
            return
        }
        let band = sanitize(EQMatchedFiltersPolicy.newBand(EQBand(
            type: .peaking,
            frequencyHz: min(max(frequency, EQBandRules.editFloor(for: .peaking)), maximumFrequency),
            gainDB: gain,
            q: EQNudge.addedBandQ
        ), enhanced: enhanced))
        recorded { try engine.addEQBand(band) }
        if bands.contains(where: { $0.id == band.id }) { selectedBandID = band.id }
    }

    /// Double-click on a handle: gain back to 0 dB and Q to the default.
    private func resetBand(_ id: UUID) {
        guard var edited = band(withID: id) else { return }
        selectedBandID = id
        if edited.type.productionHasGainControl { edited.gainDB = 0 }
        if edited.type.productionHasQControl { edited.q = EQNudge.defaultQ }
        guard edited != band(withID: id) else { return }
        commitField(edited, key: nil) { _ in }
    }

    private func selectAdjacentBand(offset: Int) {
        selectedBandID = EQBandPanelModel.adjacentSelection(from: selectedBandID, offset: offset, bands: bands)
    }


    private func suggestedFrequency() -> Double {
        guard let last = bands.last else { return 1_000 }
        return min(maximumFrequency * 0.95, max(20, last.frequencyHz * 1.6))
    }

    private func ensureSelection() {
        selectedBandID = EQBandPanelModel.ensuredSelection(current: selectedBandID, bands: bands)
    }

    private func resetSelectionForBank() {
        pendingPublishTask?.cancel()
        pendingPublishTask = nil
        pendingDragBand = nil
        dragPreview = nil
        selectedBandID = bands.first?.id
    }

    private func scheduleCoalescedPublish(_ band: EQBand) {
        pendingDragBand = sanitize(band)
        guard pendingPublishTask == nil else { return }

        pendingPublishTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let next = pendingDragBand else { break }
                pendingDragBand = nil
                if engine.eqEditDesignsOffMain {
                    do { try await engine.updateEQBandOffMain(next); actionError = nil } catch {
                        actionError = error.localizedDescription
                    }
                } else {
                    perform { try engine.updateEQBand(next) }
                }
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard !Task.isCancelled else { break }
            }
            pendingPublishTask = nil
        }
    }

    /// `sanitize` for an edit the user made: records a "moved to fit" note when the rules changed it, and clears
    /// the band's old note otherwise (E33 S1, design 8).
    private func fitted(_ input: EQBand) -> EQBand {
        let result = sanitize(input)
        if enhanced {
            movedNote = EQDynamicHint.movedNote(from: input, to: result).map { (id: input.id, text: $0) }
        }
        return result
    }

    private func sanitize(_ input: EQBand) -> EQBand {
        EQBandRules.sanitized(input, sampleRate: sampleRate)
    }
}

/// Which value an arrow key moves on the graph.
private enum EQGraphKeyAxis {
    case frequency
    case gain
}

/// A Q change from scroll notches or a pinch.
private enum EQGraphQScale {
    case notches(Int)
    case magnification(Double)
}

private struct ProductionEQResponseGraph: View {
    /// E27 S2: the coordinate maps (zoom and gain range), view, curve and ghost choices.
    let geometry: EQGraphGeometry
    let graphView: EQGraphView
    let series: EQAnalysisSeries?
    let curvesMode: EQBandCurvesMode
    /// E33 S19: read-only measurement and target curves; never an input to the EQ.
    let referenceCurves: [EQReferenceCurve]
    let otherLane: (label: String, bands: [EQBand])?
    let bands: [EQBand]
    let selectedBandID: UUID?
    let previewBand: EQBand?
    let sampleRate: Double
    let bypassed: Bool
    let onSelect: (UUID) -> Void
    let onPreview: (EQBand) -> Void
    let onCommit: (EQBand) -> Void
    /// E27 S1: arrow keys on the focused graph move the selected band.
    let onNudge: (EQGraphKeyAxis, EQNudge.Direction, EQNudge.Step) -> Void
    let onDeleteSelected: () -> Void
    /// Scroll or pinch over a handle scales that band's Q.
    let onScaleQ: (UUID, EQGraphQScale) -> Void
    /// Double-click on empty graph adds a band at (frequency, gain).
    let onAddBand: (Double, Double) -> Void
    /// Double-click on a handle resets its gain and Q.
    let onResetBand: (UUID) -> Void
    /// E33 S2: handle VoiceOver actions and the focus ring (flag-gated by the page).
    let enhancedAccessibility: Bool
    let onAdjustFrequency: (UUID, EQNudge.Direction) -> Void
    let onAdjustGain: (UUID, EQHandleAccessibility.GainAction) -> Void
    /// E11 S10: live RTA of the measurement microphone, drawn behind the EQ curve.
    var rtaOverlay: RoomCorrectionFrequencyResponse?
    /// E27 S2b: program input and output spectrum, drawn first (behind everything).
    /// E32 S1: the analyser model is read only by `EQProgramSpectrumLayer`, so its 20 Hz ticks redraw
    /// that layer and not this graph or the page.
    var programAnalyser: EQProgramAnalyserController?
    /// The compiled response of `displayBands`, from the page's cache.
    let program: [EQResponseSection]
    /// Cached compile of any band set (band curves, dynamic envelopes, ghost lane).
    let programFor: ([EQBand]) -> [EQResponseSection]

    @State private var hover = EQGraphHoverModel()
    @State private var dragSession: EQGraphGeometry.DragSession?
    @State private var scrollAccumulator = EQNudge.ScrollAccumulator()
    @FocusState private var graphFocused: Bool

    private var minimumFrequency: Double { geometry.minimumFrequency }
    private var minimumDB: Double { geometry.displayMinimumDB }
    private var maximumDB: Double { geometry.displayMaximumDB }

    private var graphMaximumFrequency: Double { geometry.maximumFrequency }

    private var displayBands: [EQBand] {
        bands.map { band in
            if let previewBand, previewBand.id == band.id { return previewBand }
            return band
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // Handles sit on the magnitude axes, so the other views are read-only.
            let handleBands = graphView == .magnitude
                ? Array(displayBands.enumerated()).filter { $0.element.type != .fir }
                : []
            ZStack {
                RoundedRectangle(cornerRadius: DesignRadius.medium.pt, style: .continuous)
                    .fill(.black.opacity(0.17))

                Canvas { context, _ in
                    if graphView == .magnitude { drawGrid(context: &context, size: size) }
                }
                .opacity(bypassed ? 0.35 : 1)
                .allowsHitTesting(false)

                if graphView == .magnitude, let programAnalyser {
                    EQProgramSpectrumLayer(
                        analyser: programAnalyser, size: size,
                        xPosition: { xPosition($0, width: size.width) },
                        minimumFrequency: minimumFrequency, maximumFrequency: graphMaximumFrequency
                    )
                    .opacity(bypassed ? 0.35 : 1)
                    .allowsHitTesting(false)
                }

                Canvas { context, _ in
                    if graphView == .magnitude {
                        drawReferenceCurves(context: &context, size: size)
                        drawRTAOverlay(context: &context, size: size)
                        drawGhostLane(context: &context, size: size)
                        drawBandCurves(context: &context, size: size)
                        drawResponse(context: &context, size: size, program: program)
                    } else if let series, series.view == graphView {
                        EQGraphSeriesDrawing.draw(
                            context: &context, size: size, series: series,
                            geometry: geometry, sampleRate: sampleRate
                        )
                    }
                }
                .opacity(bypassed ? 0.35 : 1)
                .allowsHitTesting(false)

                // Empty-graph double-click adds a band; a click also focuses the graph for keys.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture(count: 2).onEnded { value in
                            guard graphView == .magnitude else { return }
                            let target = geometry.position(at: value.location, size: size)
                            onAddBand(target.frequencyHz, target.gainDB)
                        }
                    )
                    .simultaneousGesture(TapGesture().onEnded { graphFocused = true })
                    .accessibilityHidden(true)

                ForEach(handleBands, id: \.element.id) { index, band in
                    let point = point(for: band, size: size)
                    let isSelected = selectedBandID == band.id
                    let diameter: CGFloat = isSelected ? 22 : 20
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        Circle()
                            .stroke(isSelected ? Color.white.opacity(0.9) : Color.secondary.opacity(0.8), lineWidth: isSelected ? 2 : 1)
                        if band.dynamic.enabled {
                            Circle()
                                .stroke(Color.orange, lineWidth: 1.5)
                                .padding(-3.5)
                        }
                        if enhancedAccessibility && isSelected && graphFocused {
                            Circle()
                                .stroke(Color.accentColor, lineWidth: 2)
                                .padding(-6)
                        }
                        Text("\(index + 1)")
                            .font(DesignType.caption.font.weight(.bold).monospacedDigit())
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .frame(width: diameter, height: diameter)
                    .opacity(band.enabled ? 1 : 0.42)
                    // The hit shape must be set on the handle itself, before `.position` expands
                    // the view to the whole graph; otherwise one handle swallows every click.
                    .contentShape(Circle().inset(by: -10))
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("eq.graph"))
                            .onChanged { value in
                                graphFocused = true
                                onSelect(band.id)
                                if dragSession == nil {
                                    dragSession = EQGraphGeometry.DragSession(origin: point, start: value.startLocation)
                                }
                                onPreview(movedBand(band, value: value, size: size))
                            }
                            .onEnded { value in
                                onCommit(movedBand(band, value: value, size: size))
                                dragSession = nil
                            }
                    )
                    // A plain click selects the band; the drag above only fires once the pointer moves.
                    .simultaneousGesture(TapGesture().onEnded {
                        graphFocused = true
                        onSelect(band.id)
                    })
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onResetBand(band.id) })
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(EQBandPanelModel.accessibilityLabel(number: index + 1, band: band))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { onSelect(band.id) }
                    .modifier(EQHandleAccessibilityActions(
                        enabled: enhancedAccessibility, band: band,
                        onAdjustFrequency: { onAdjustFrequency(band.id, $0) },
                        onAdjustGain: { onAdjustGain(band.id, $0) }))
                    .accessibilityIdentifier("eq.graph.handle.\(index + 1)")
                    .position(point)
                }
                if bypassed {
                    Text("EQ BYPASSED")
                        .font(DesignType.caption.font.bold()).tracking(1.7)
                        .padding(.horizontal, DesignSpacing.m.pt).padding(.vertical, DesignSpacing.s.pt)
                        .background(.ultraThinMaterial, in: .capsule)
                        .allowsHitTesting(false)
                }

                if graphView == .magnitude {
                EQGraphHoverOverlay(
                    model: hover,
                    geometry: geometry,
                    size: size,
                    handles: handleBands.map { index, band in
                        EQGraphHoverHandle(
                            handle: EQGraphGeometry.Handle(id: band.id, center: point(for: band, size: size)),
                            number: index + 1,
                            band: band,
                            hasGain: band.type.productionHasGainControl,
                            hasQ: band.type.productionHasQControl
                        )
                    },
                    responseDB: { ProductionEQResponseMath.responseDB(program: program, sampleRate: sampleRate, frequencyHz: $0) }
                )
                }
            }
            .coordinateSpace(name: "eq.graph")
            .background(
                EQGraphEventCatcher(
                    onScroll: { point, delta, precise in
                        guard let id = handleID(at: point, size: size) else {
                            scrollAccumulator.reset()
                            return false
                        }
                        let notches = scrollAccumulator.add(delta: delta, precise: precise)
                        if notches != 0 { onScaleQ(id, .notches(notches)) }
                        return true
                    },
                    onMagnify: { point, magnification in
                        guard let id = handleID(at: point, size: size) else { return false }
                        onScaleQ(id, .magnification(magnification))
                        return true
                    }
                )
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hover.location = location
                case .ended: hover.location = nil
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($graphFocused)
            .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
        }
        .accessibilityLabel("Equalizer frequency response")
    }

    // MARK: Interaction

    private func movedBand(_ band: EQBand, value: DragGesture.Value, size: CGSize) -> EQBand {
        let flags = NSEvent.modifierFlags
        var session = dragSession ?? EQGraphGeometry.DragSession(origin: point(for: band, size: size), start: value.startLocation)
        let moved = session.update(
            location: value.location,
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            bounds: size
        )
        dragSession = session
        var updated = band
        updated.frequencyHz = geometry.frequency(x: moved.x, width: size.width)
        if band.type.productionHasGainControl {
            updated.gainDB = geometry.gain(y: moved.y, height: size.height)
        }
        return updated
    }

    private func handleID(at point: CGPoint, size: CGSize) -> UUID? {
        guard graphView == .magnitude else { return nil }
        let handles = displayBands
            .filter { $0.type != .fir }
            .map { EQGraphGeometry.Handle(id: $0.id, center: self.point(for: $0, size: size)) }
        return EQGraphGeometry.hitHandle(at: point, handles: handles)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard selectedBandID != nil else { return .ignored }
        // Command combinations (for example Command-[ and Command-]) belong to the menu.
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) { return .ignored }
        let step = EQNudge.Step(shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option))
        switch press.key {
        case .leftArrow: onNudge(.frequency, .down, step)
        case .rightArrow: onNudge(.frequency, .up, step)
        case .upArrow: onNudge(.gain, .up, step)
        case .downArrow: onNudge(.gain, .down, step)
        case .delete, .deleteForward: onDeleteSelected()
        default: return .ignored
        }
        return .handled
    }

    // MARK: Drawing

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let frequencies: [Double] = [5, 10, 20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000, 40_000, 80_000, 160_000]
        for frequency in frequencies where frequency <= graphMaximumFrequency && frequency >= minimumFrequency {
            let x = xPosition(frequency, width: size.width)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
            context.draw(
                Text(axisFrequency(frequency)).font(DesignType.caption.font).foregroundStyle(.secondary),
                at: CGPoint(x: min(max(x, 24), size.width - 24), y: size.height - 11)
            )
        }

        let half = maximumDB
        let step = EQGraphYRange.gridStep(halfRange: half)
        var db = -half
        while db <= half + 1.0e-9 {
            let y = yPosition(db, height: size.height)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            let isZero = abs(db) < 1.0e-9
            context.stroke(path, with: .color(.secondary.opacity(isZero ? 0.34 : 0.14)), lineWidth: isZero ? 1.3 : 1)
            // The bottom label would sit on the 20 Hz frequency label, so it is omitted;
            // the top label is drawn below its gridline instead of above the plot.
            if !isZero && y < size.height - 24 {
                context.draw(
                    Text(String(format: "%g", db)).font(DesignType.caption.font).foregroundStyle(.secondary),
                    at: CGPoint(x: 16, y: abs(db - half) < 1.0e-9 ? y + 8 : y - 7)
                )
            }
            db += step
        }
    }

    /// E33 S19: stored points only, joined by straight lines on the log axis.
    private func drawReferenceCurves(context: inout GraphicsContext, size: CGSize) {
        for curve in referenceCurves {
            var path = Path()
            var started = false
            for (frequency, db) in zip(curve.frequenciesHz, curve.gainDB)
            where frequency >= minimumFrequency && frequency <= graphMaximumFrequency {
                let point = CGPoint(x: xPosition(frequency, width: size.width), y: yPosition(db, height: size.height))
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
            guard started else { continue }
            let color = EQReferenceCurveStyle.color(for: curve.kind)
            let opacity = curve.isOutOfDate ? 0.4 : 0.85
            let style = StrokeStyle(lineWidth: 1.5, dash: curve.kind == .target || curve.isOutOfDate ? [5, 4] : [])
            context.stroke(path, with: .color(color.opacity(opacity)), style: style)
        }
    }

    private func drawRTAOverlay(context: inout GraphicsContext, size: CGSize) {
        guard let rtaOverlay else { return }
        var path = Path()
        var started = false
        for (frequency, db) in zip(rtaOverlay.frequenciesHz, rtaOverlay.magnitudeDB) where frequency >= minimumFrequency && frequency <= graphMaximumFrequency && db.isFinite {
            let point = CGPoint(x: xPosition(frequency, width: size.width), y: yPosition(db, height: size.height))
            if started { path.addLine(to: point) } else { path.move(to: point); started = true }
        }
        guard started else { return }
        context.stroke(path, with: .color(.orange.opacity(0.7)), lineWidth: 1.5)
    }

    /// The curve through `evaluate` over the visible frequency span, as a path.
    private func curvePath(size: CGSize, evaluate: (Double) -> Double) -> (path: Path, points: [CGPoint]) {
        let count = max(180, Int(size.width / 3))
        var path = Path()
        var points: [CGPoint] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let t = Double(index) / Double(max(1, count - 1))
            let frequency = exp(log(minimumFrequency) + t * (log(graphMaximumFrequency) - log(minimumFrequency)))
            let point = CGPoint(x: CGFloat(t) * size.width, y: yPosition(evaluate(frequency), height: size.height))
            points.append(point)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return (path, points)
    }

    private func drawResponse(context: inout GraphicsContext, size: CGSize, program: [EQResponseSection]) {
        guard !program.isEmpty else { return }
        let curve = curvePath(size: size) {
            ProductionEQResponseMath.responseDB(program: program, sampleRate: sampleRate, frequencyHz: $0)
        }
        context.stroke(curve.path, with: .color(.accentColor), lineWidth: 2.4)
    }

    /// Band fill (design 8): each drawn band's own curve, filled down to 0 dB for the selection
    /// and stroked thin for the rest; dynamic bands shade the gain range they can reach.
    private func drawBandCurves(context: inout GraphicsContext, size: CGSize) {
        let zeroY = yPosition(0, height: size.height)
        for band in displayBands where band.enabled && band.dynamic.enabled {
            guard let envelope = EQBandCurves.dynamicEnvelope(of: band) else { continue }
            let lowerProgram = programFor([envelope.lower])
            let upperProgram = programFor([envelope.upper])
            let lower = curvePath(size: size) { ProductionEQResponseMath.responseDB(program: lowerProgram, sampleRate: sampleRate, frequencyHz: $0) }
            let upper = curvePath(size: size) { ProductionEQResponseMath.responseDB(program: upperProgram, sampleRate: sampleRate, frequencyHz: $0) }
            var shade = Path()
            if let first = upper.points.first { shade.move(to: first) }
            upper.points.dropFirst().forEach { shade.addLine(to: $0) }
            lower.points.reversed().forEach { shade.addLine(to: $0) }
            shade.closeSubpath()
            context.fill(shade, with: .color(.orange.opacity(band.id == selectedBandID ? 0.28 : 0.16)))
        }

        for band in EQBandCurves.drawn(mode: curvesMode, bands: displayBands, selectedID: selectedBandID) {
            let bandProgram = programFor([band])
            let curve = curvePath(size: size) { ProductionEQResponseMath.responseDB(program: bandProgram, sampleRate: sampleRate, frequencyHz: $0) }
            let isSelected = band.id == selectedBandID
            if isSelected, let first = curve.points.first, let last = curve.points.last {
                var fill = Path()
                fill.move(to: CGPoint(x: first.x, y: zeroY))
                curve.points.forEach { fill.addLine(to: $0) }
                fill.addLine(to: CGPoint(x: last.x, y: zeroY))
                fill.closeSubpath()
                context.fill(fill, with: .color(.accentColor.opacity(0.22)))
            }
            context.stroke(
                curve.path,
                with: .color(.accentColor.opacity(isSelected ? 0.85 : 0.4)),
                lineWidth: isSelected ? 1.4 : 1
            )
        }
    }

    /// The lane that is not being edited (Left/Right or Mid/Side), dashed and faint.
    private func drawGhostLane(context: inout GraphicsContext, size: CGSize) {
        guard let otherLane, !otherLane.bands.isEmpty else { return }
        let program = programFor(otherLane.bands)
        guard !program.isEmpty else { return }
        let curve = curvePath(size: size) {
            ProductionEQResponseMath.responseDB(program: program, sampleRate: sampleRate, frequencyHz: $0)
        }
        context.stroke(curve.path, with: .color(.secondary.opacity(0.65)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        context.draw(
            Text("\(otherLane.label) (not editing)").font(DesignType.caption.font).foregroundStyle(.secondary),
            at: CGPoint(x: size.width - 60, y: 12)
        )
    }

    private func point(for band: EQBand, size: CGSize) -> CGPoint {
        geometry.point(
            frequency: band.frequencyHz,
            gainDB: band.type.productionHasGainControl ? band.gainDB : 0,
            size: size
        )
    }

    private func xPosition(_ frequency: Double, width: CGFloat) -> CGFloat {
        geometry.x(frequency: frequency, width: width)
    }

    private func yPosition(_ db: Double, height: CGFloat) -> CGFloat {
        geometry.y(db: db, height: height)
    }

    private func axisFrequency(_ value: Double) -> String {
        value >= 1_000 ? "\(Int(value / 1_000))k" : "\(Int(value))"
    }
}

/// One biquad of a drawn response, in double precision. The engine designs its sections in double, so the curve
/// evaluates the double design too (E33 G16: float coefficients drift from the engine below about 10 Hz).
struct EQResponseSection: Equatable, Sendable {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
    }

    init(_ c: N60BiquadCoefficients) {
        self.init(b0: Double(c.b0), b1: Double(c.b1), b2: Double(c.b2), a1: Double(c.a1), a2: Double(c.a2))
    }

    /// The double design of a compiled section when it is the cookbook design behind the float coefficients (checked by
    /// rounding it to float and comparing); otherwise the float coefficients (matched, Linkwitz, first-order, tilt).
    init(_ section: N60BiquadBandSnapshot, sampleRate: Double) {
        var d = [Double](repeating: 0, count: 5)
        let c = section.coefficients
        // Matched designs (types 16 and up) come from the core entry point that also feeds the engine.
        if section.type.rawValue >= 16,
           n60_eq_design_section(UInt32(section.type.rawValue), sampleRate, section.frequencyHz, section.gainDB, section.q, &d) == 1 {
            self.init(b0: d[0], b1: d[1], b2: d[2], a1: d[3], a2: d[4])
        } else if N60BiquadDesignDouble(section.type, sampleRate, section.frequencyHz, section.gainDB, section.q, &d),
           Float(d[0]) == c.b0, Float(d[1]) == c.b1, Float(d[2]) == c.b2, Float(d[3]) == c.a1, Float(d[4]) == c.a2 {
            self.init(b0: d[0], b1: d[1], b2: d[2], a1: d[3], a2: d[4])
        } else {
            self.init(c)
        }
    }
}

enum ProductionEQResponseMath {
    static func compile(bands: [EQBand], sampleRate: Double) -> [EQResponseSection] {
        var program: [EQResponseSection] = []
        for band in bands where band.enabled && band.type != .fir {
            guard let sections = try? band.compiledSections(sampleRate: sampleRate) else { continue }
            program.append(contentsOf: sections.map { EQResponseSection($0, sampleRate: sampleRate) })
        }
        return program
    }

    static func responseDB(
        program: [EQResponseSection],
        sampleRate: Double,
        frequencyHz: Double
    ) -> Double {
        guard sampleRate.isFinite, sampleRate > 0, frequencyHz > 0, frequencyHz < sampleRate * 0.5 else { return 0 }
        let total = program.reduce(0.0) { partial, coefficients in
            partial + sectionResponseDB(coefficients, sampleRate: sampleRate, frequencyHz: frequencyHz)
        }
        return min(max(total, -48), 48)
    }

    private static func sectionResponseDB(
        _ coefficients: EQResponseSection,
        sampleRate: Double,
        frequencyHz: Double
    ) -> Double {
        let omega = 2 * Double.pi * frequencyHz / sampleRate
        let cos1 = cos(omega)
        let sin1 = sin(omega)
        let cos2 = cos(2 * omega)
        let sin2 = sin(2 * omega)

        let b0 = coefficients.b0
        let b1 = coefficients.b1
        let b2 = coefficients.b2
        let a1 = coefficients.a1
        let a2 = coefficients.a2

        let nr = b0 + b1 * cos1 + b2 * cos2
        let ni = -b1 * sin1 - b2 * sin2
        let dr = 1 + a1 * cos1 + a2 * cos2
        let di = -a1 * sin1 - a2 * sin2
        let numerator = nr * nr + ni * ni
        let denominator = dr * dr + di * di
        guard numerator.isFinite, denominator.isFinite, numerator > 1.0e-20, denominator > 1.0e-20 else { return 0 }
        return 10 * log10(numerator / denominator)
    }
}

extension EQFilterType {
    var productionHasGainControl: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf, .tilt: return true
        case .lowPass, .highPass, .bandPass, .linkwitzTransform, .fir, .notch, .allPass: return false
        }
    }

    /// Types whose Q the band editor lets the user change (scroll, pinch and the Q field).
    var productionHasQControl: Bool {
        switch self {
        case .tilt, .fir: return false
        default: return true
        }
    }
}
