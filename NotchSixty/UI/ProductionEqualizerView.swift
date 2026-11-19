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
    private func recordedOffMain(_ action: @escaping () async throws -> Void) {
        let before = engine.stereoEQConfiguration
        Task { @MainActor in
            do {
                try await action()
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
            history.record(before: before, after: engine.stereoEQConfiguration, coalesceKey: nil)
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
        let sampleRate: Double
        let view: EQGraphView
        let zoom: EQGraphXZoom
    }

    private var analysisKey: AnalysisKey {
        AnalysisKey(bands: shownBands, phaseMode: configuration.phaseMode, sampleRate: sampleRate, view: graphView, zoom: xZoom)
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
            let analysis = EQFilterAnalysis(bands: key.bands, phaseMode: key.phaseMode, sampleRate: key.sampleRate)
            let grid = EQFilterAnalysis.frequencyGrid(lower: key.zoom.minimumFrequency, upper: upper, count: 360)
            return analysis.series(for: key.view, frequencies: grid)
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard let result else { return }
        guard !Task.isCancelled else { return }
        series = result
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
            ensureSelection()
            configureHistory()
        }
        .onChange(of: undoManager.map(ObjectIdentifier.init)) { _, _ in configureHistory() }
        .onChange(of: engine.stereoEQConfiguration) { _, _ in history.observeLiveChange() }
        .onReceive(autoPreamp.$lastError.compactMap { $0 }) { actionError = $0 }
        .onReceive(comparisonErrors) { actionError = $0 }
        .onChange(of: configuration.channelMode) { _, _ in resetSelectionForBank() }
        .onChange(of: configuration.editChannel) { _, _ in resetSelectionForBank() }
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

            responseGraph

            if enhanced {
                enhancedBandArea
            } else {
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

    /// E33 S1 (design 7): band list about one third of the width, editor beside it in two columns (static left,
    /// dynamic right), or one scrolling column below the breakpoint. Panels size to content.
    @ViewBuilder
    private var enhancedBandArea: some View {
        let columns = EQEditorLayout.columns(pageWidth: pageWidth)
        HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
            bandsPanel
                .frame(width: EQEditorLayout.listWidth(pageWidth: pageWidth))
                .frame(height: EQEditorLayout.listHeight(bandCount: bands.count))
            bandEditorPane(columns: columns)
                .frame(maxWidth: .infinity)
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

    private var activeBandCount: Int { configuration.activeBandCount(sampleRate: sampleRate) }
    private var inactiveBandCount: Int { configuration.aboveNyquistBandCount(sampleRate: sampleRate) }

    private var modeBar: some View {
        GlassEffectContainer(spacing: DesignSpacing.m.pt) {
            HStack(alignment: .bottom, spacing: DesignSpacing.l.pt) {
                VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                    Text("CHANNELS")
                        .font(DesignType.caption.font.bold())
                        .tracking(1.2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: DesignSpacing.s.pt) {
                        Picker("Channels", selection: Binding(
                            get: { configuration.channelMode },
                            set: { mode in recorded { try engine.setEQChannelMode(mode) } }
                        )) {
                            ForEach(EQChannelMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()

                        if configuration.channelMode != .linked {
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

                    if let note = engine.unpairedEQLaneNote {
                        Text(note)
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                    Text("PHASE")
                        .font(DesignType.caption.font.bold())
                        .tracking(1.2)
                        .foregroundStyle(.secondary)

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

                Spacer(minLength: 8)

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
                .layoutPriority(1)
            }
            .padding(.horizontal, DesignSpacing.m.pt)
            .padding(.vertical, DesignSpacing.s.pt)
            .designSurface(.medium)
        }
    }

    private var responseGraph: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            HStack {
                Text("RESPONSE").font(DesignType.caption.font.bold()).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                Text("\(configuration.phaseMode.displayName) · \(activeLaneLabel) · \(sampleRate / 1_000, specifier: "%.1f") kHz")
                    .font(DesignType.caption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            graphControls

            let shown = shownBands
            let program = responseCache.program(bands: shown, sampleRate: sampleRate)
            let geometry = graphGeometry(program: program)
            ProductionEQResponseGraph(
                geometry: geometry,
                graphView: graphView,
                series: series,
                curvesMode: bandCurvesMode,
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
                    perform { try engine.updateEQBand(sanitized) }
                    history.endGesture(after: engine.stereoEQConfiguration)
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
            .frame(minHeight: 200, idealHeight: 280, maxHeight: 340)

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

    private var graphControls: some View {
        HStack(spacing: DesignSpacing.m.pt) {
            Picker("View", selection: $graphView) {
                ForEach(EQGraphView.allCases) { view in Text(view.displayName).tag(view) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel("Graph view")

            Spacer(minLength: 8)

            if let programAnalyser {
                EQProgramAnalyserSwitch(analyser: programAnalyser)
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

            Picker("Frequencies", selection: $xZoomRaw) {
                ForEach(EQGraphXZoom.allCases.filter { enhanced || $0 != .subsonic }) { zoom in Text(zoom.displayName).tag(zoom.rawValue) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(!graphView.isFrequencyDomain)
            .accessibilityLabel("Frequency range")
        }
    }

    /// The graph's coordinate maps for the chosen zoom and gain range. Auto widens during a
    /// drag but only narrows once the drag ends.
    private func graphGeometry(program: [N60BiquadCoefficients]) -> EQGraphGeometry {
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
                if enhanced && columns == .two {
                    VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                        editorHeader(number: index + 1, band: band, binding: binding)
                        HStack(alignment: .top, spacing: DesignSpacing.l.pt) {
                            staticControls(band: band, binding: binding)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            Divider()
                            dynamicColumn(band: band, binding: binding)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .padding(DesignSpacing.l.pt)
                    .accessibilityIdentifier("eq.bands.editor.twoColumn")
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
        .frame(maxHeight: enhanced && columns == .two ? nil : .infinity)
        .designSurface(.large)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("eq.bands.editor")
    }

    @ViewBuilder
    private func dynamicColumn(band: EQBand, binding: Binding<EQBand>) -> some View {
        if band.type.supportsDynamicEQ {
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

    @ViewBuilder
    private func staticControls(band: EQBand, binding: Binding<EQBand>) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            LabeledContent("Filter") {
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

            LabeledContent("Frequency") {
                HStack(spacing: DesignSpacing.s.pt) {
                    EQNumberField(
                        title: "Frequency",
                        field: .frequency,
                        value: band.frequencyHz,
                        band: band,
                        maximumFrequency: maximumFrequency,
                        width: 110,
                        identifier: "eq.bands.editor.frequency"
                    ) { newValue, isStep in
                        commitField(band, key: isStep ? "field.frequency" : nil) { $0.frequencyHz = newValue }
                    }
                    .disabled(band.type == .fir)
                    Text("Hz").foregroundStyle(.secondary)
                }
            }

            LabeledContent("Gain") {
                HStack(spacing: DesignSpacing.s.pt) {
                    EQNumberField(
                        title: "Gain",
                        field: .gain,
                        value: band.gainDB,
                        band: band,
                        maximumFrequency: maximumFrequency,
                        identifier: "eq.bands.editor.gain"
                    ) { newValue, isStep in
                        commitField(band, key: isStep ? "field.gain" : nil) { $0.gainDB = newValue }
                    }
                    .disabled(!band.type.productionHasGainControl)
                    Text("dB").foregroundStyle(.secondary)
                }
            }

            LabeledContent {
                EQNumberField(
                    title: "Q",
                    field: .q,
                    value: band.q,
                    band: band,
                    maximumFrequency: maximumFrequency,
                    identifier: "eq.bands.editor.q"
                ) { newValue, isStep in
                    commitField(band, key: isStep ? "field.q" : nil) { $0.q = newValue }
                }
                .disabled(!band.type.productionHasQControl)
            } label: {
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
            }

            if band.type.supportsSlope {
                LabeledContent("Slope") {
                    Picker("Slope", selection: binding.slope) {
                        ForEach(EQFilterSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                    }
                    .labelsHidden()
                    .frame(minWidth: 150)
                }
            }

            if band.type == .peaking {
                Toggle("Constant-Q peak", isOn: binding.constantQ).toggleStyle(.switch)
            }

            if band.type == .linkwitzTransform {
                LabeledContent("Target Frequency") {
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
                        Text("Hz").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Target Q") {
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
                (type == .fir && band.firKernel == nil)
                    || (type == .allPass && configuration.phaseMode != .minimumPhase)
            )
    }

    @ViewBuilder
    private func dynamicControls(band: EQBand, binding: Binding<EQBand>) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
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
                LabeledContent("Direction") {
                    Picker("Direction", selection: binding.dynamic.direction) {
                        ForEach(DynamicEQDirection.allCases) { direction in Text(direction.displayName).tag(direction) }
                    }
                    .labelsHidden().frame(minWidth: 150)
                    .disabled(band.type == .notch)
                }

                metricField("Threshold", .threshold, value: binding.dynamic.thresholdDB, suffix: "dB")
                metricField("Ratio", .ratio, value: binding.dynamic.ratio, suffix: ":1")
                metricField("Max Cut", .maxCut, value: binding.dynamic.rangeDB, suffix: "dB")
                metricField("Attack", .attack, value: binding.dynamic.attackMs, suffix: "ms")
                metricField("Release", .release, value: binding.dynamic.releaseMs, suffix: "ms")

                LabeledContent("Detector") {
                    Picker("Detector", selection: binding.dynamic.detectorMode) {
                        ForEach(DynamicEQDetectorMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                    }
                    .labelsHidden().frame(minWidth: 120)
                }

                if band.dynamic.detectorMode == .rms {
                    metricField("RMS Window", .rmsWindow, value: binding.dynamic.rmsWindowMs, suffix: "ms")
                }

                if band.dynamic.direction != .cutOnly {
                    Text("Boost").font(.subheadline.bold()).padding(.top, DesignSpacing.xs.pt)
                    metricField("Boost Threshold", .boostThreshold, value: binding.dynamic.boostThresholdDB, suffix: "dB")
                    metricField("Boost Ratio", .boostRatio, value: binding.dynamic.boostRatio, suffix: ":1")
                    metricField("Max Boost", .maxBoost, value: binding.dynamic.maxBoostDB, suffix: "dB")
                }
            } else {
                Text("Enable Dynamic to add level-dependent correction to this ordinary EQ band. Static gain remains owned by the band itself.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metricField(_ label: String, _ metric: EQDynamicMetric, value: Binding<Double>, suffix: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: DesignSpacing.s.pt) {
                EQDynamicMetricField(title: label, metric: metric, value: value)
                Text(suffix).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
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
                recorded { try engine.updateEQBand(fitted(updated)) }
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
        recorded(coalesceKey: key.map { "\($0).\(band.id)" }) { try engine.updateEQBand(fitted(updated)) }
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
        let band = EQBand(frequencyHz: suggestedFrequency(), q: 1.0)
        let before = engine.stereoEQConfiguration
        do {
            try engine.addEQBand(band)
            selectedBandID = band.id
            history.record(before: before, after: engine.stereoEQConfiguration)
        } catch {
            actionError = "Could not add the band: \(error.localizedDescription)"
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
        let band = sanitize(EQBand(
            type: .peaking,
            frequencyHz: min(max(frequency, EQBandRules.editFloor(for: .peaking)), maximumFrequency),
            gainDB: gain,
            q: EQNudge.addedBandQ
        ))
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
                perform { try engine.updateEQBand(next) }
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
    let program: [N60BiquadCoefficients]
    /// Cached compile of any band set (band curves, dynamic envelopes, ghost lane).
    let programFor: ([EQBand]) -> [N60BiquadCoefficients]

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

    private func drawResponse(context: inout GraphicsContext, size: CGSize, program: [N60BiquadCoefficients]) {
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

enum ProductionEQResponseMath {
    static func compile(bands: [EQBand], sampleRate: Double) -> [N60BiquadCoefficients] {
        var program: [N60BiquadCoefficients] = []
        for band in bands where band.enabled && band.type != .fir {
            guard let sections = try? band.compiledSections(sampleRate: sampleRate) else { continue }
            program.append(contentsOf: sections.map(\.coefficients))
        }
        return program
    }

    static func responseDB(
        program: [N60BiquadCoefficients],
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
        _ coefficients: N60BiquadCoefficients,
        sampleRate: Double,
        frequencyHz: Double
    ) -> Double {
        let omega = 2 * Double.pi * frequencyHz / sampleRate
        let cos1 = cos(omega)
        let sin1 = sin(omega)
        let cos2 = cos(2 * omega)
        let sin2 = sin(2 * omega)

        let b0 = Double(coefficients.b0)
        let b1 = Double(coefficients.b1)
        let b2 = Double(coefficients.b2)
        let a1 = Double(coefficients.a1)
        let a2 = Double(coefficients.a2)

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
