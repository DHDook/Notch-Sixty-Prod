import Foundation
import SwiftUI

struct ProductionDynamicsView: View {
    var engine: AudioIOEngine
    var reference: ProductionReferenceNavigator? = nil
    /// E33 S15: read for the "Start from" unsaved-edits check; nil hides nothing, it only skips the ask.
    var profiles: ProductProfileController? = nil
    @State private var selectedModule: ProductionDynamicsModule
    @State private var grAttachment: UUID?
    @State private var expandedMoreGroups: Set<String> = []
    @State private var mainsDetectInFlight = false
    @State private var mainsDetectionMessage: String?
    @State private var actionError: String?
    @Environment(\.undoManager) private var undoManager
    @State private var history = EditHistory<DynamicsConfiguration>()
    /// E33 S4: numbered groups, the dynamic EQ link row and navigator accessibility. Off keeps today's page.
    private let enhanced = FeatureFlags().isEnabled(.eqPageEnhancements)
    /// E33 S4: switches to the Equalizer page; the band is passed through `EQBandFocusRequest`.
    var openEqualizer: (() -> Void)? = nil

    /// `initialModule` is the processor the page opens on (the compressor by default); the page harness opens the others.
    init(engine: AudioIOEngine, reference: ProductionReferenceNavigator? = nil, profiles: ProductProfileController? = nil,
         openEqualizer: (() -> Void)? = nil, initialModule: ProductionDynamicsModule = .compressor) {
        self.engine = engine
        self.reference = reference
        self.profiles = profiles
        self.openEqualizer = openEqualizer
        _selectedModule = State(initialValue: initialModule)
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var configuration: DynamicsConfiguration { engine.dynamicsConfiguration }

    var body: some View {
        ProductionPageContainer(scrolls: false) {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            header
            ProductionActionErrorBanner(message: $actionError)
            listeningBanner
            if FeatureFlags().isEnabled(.eqPageEnhancements) {
                TotalGainReductionRow(engine: engine, monitor: GainReductionMonitor.shared(for: engine))
            }

            HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
                moduleNavigator
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)

                ScrollView {
                    moduleEditor
                        .padding(.horizontal, DesignSpacing.xs.pt)
                }
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        }
        .onAppear {
            configureHistory()
            grAttachment = GainReductionMonitor.shared(for: engine).attach(hertz: GainReductionMonitor.rowHertz)
        }
        .onChange(of: undoManager.map(ObjectIdentifier.init)) { _, _ in configureHistory() }
        .onChange(of: engine.dynamicsConfiguration) { _, _ in history.observeLiveChange() }
        .onDisappear {
            history.clear()
            if let grAttachment { GainReductionMonitor.shared(for: engine).detach(grAttachment) }
            grAttachment = nil
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                Text("Level control, restoration, protection, and program-aware processing. Select a processor to expose its complete configuration.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if enhanced {
                DynamicsStartFromMenu(
                    hasUnsavedDynamicsEdits: {
                        guard let preset = profiles?.selectedContentPreset else { return false }
                        return preset.state.dynamics != engine.dynamicsConfiguration
                    },
                    apply: { point in update(name: "Start from \(point.title)") { $0 = point.applying(to: $0) } })
            }
            Text("\(activeModuleCount) ACTIVE")
                .font(DesignType.caption.font.bold())
                .tracking(1.1)
                .foregroundStyle(.secondary)
        }
    }

    private var moduleNavigator: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                ForEach(ProductionDynamicsLayout.groups) { group in
                    if enhanced, ProductionDynamicsLayout.eqRowIndex() < ProductionDynamicsLayout.groups.count,
                       group.id == ProductionDynamicsLayout.groups[ProductionDynamicsLayout.eqRowIndex()].id {
                        dynamicEQRow
                    }
                    Text((enhanced ? ProductionDynamicsLayout.numberedTitle(of: group) : group.title).uppercased())
                        .font(DesignType.caption.font.bold())
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, DesignSpacing.s.pt)
                        .padding(.top, DesignSpacing.s.pt)
                        .padding(.bottom, group.note == nil ? 2 : 0)

                    if let note = group.note {
                        Text(note)
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, DesignSpacing.s.pt)
                            .padding(.bottom, DesignSpacing.xs.pt)
                    }

                    ForEach(moreIsExpanded(group) ? group.modules : group.shown) { module in
                        moduleRow(module)
                    }

                    if !group.more.isEmpty {
                        moreRow(for: group)
                    }
                }
                if ProductionDynamicsLayout.eqRowIndex() >= ProductionDynamicsLayout.groups.count, enhanced {
                    dynamicEQRow
                }
            }
            .padding(DesignSpacing.s.pt)
        }
        .scrollIndicators(.visible)
        .background(.clear)
        .designGlass(.large)
    }

    /// "More" stays open while one of its processors is selected, so the
    /// selection never disappears from the list.
    private func moreIsExpanded(_ group: ProductionDynamicsLayout.Group) -> Bool {
        expandedMoreGroups.contains(group.id) || group.more.contains(selectedModule)
    }

    private func moreRow(for group: ProductionDynamicsLayout.Group) -> some View {
        let expanded = moreIsExpanded(group)
        return Button {
            if expanded {
                expandedMoreGroups.remove(group.id)
            } else {
                expandedMoreGroups.insert(group.id)
            }
        } label: {
            HStack(spacing: DesignSpacing.s.pt) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(expanded ? "Fewer" : "More (\(group.more.count))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !expanded, group.moreHasActiveModule(isActive: moduleIsActive) {
                    Text("ON")
                        .font(DesignType.caption.font.bold())
                        .foregroundStyle(StatusLevel.good.color)
                        .accessibilityLabel("A processor under More is on")
                }
            }
            .contentShape(.rect)
            .padding(.horizontal, DesignSpacing.s.pt)
            .padding(.vertical, DesignSpacing.xs.pt)
        }
        .buttonStyle(.plain)
    }

    private func moduleRow(_ module: ProductionDynamicsModule) -> some View {
        Button {
            selectedModule = module
        } label: {
            HStack(spacing: DesignSpacing.s.pt) {
                Image(systemName: module.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(selectedModule == module ? .primary : .secondary)
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text(module.title)
                        .foregroundStyle(.primary)
                    Text(module.subtitle)
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if FeatureFlags().isEnabled(.eqPageEnhancements), let actsOn = engine.dynamicsActsOnText(for: module) {
                        Text("Acts on: \(actsOn)")
                            .font(DesignType.caption.font)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                if let source = module.gainReductionSource {
                    GainReductionBar(monitor: GainReductionMonitor.shared(for: engine), source: source, compact: true)
                        .frame(width: 36)
                }
                Circle()
                    .fill(moduleIsActive(module) ? StatusLevel.good.color : Color.secondary.opacity(0.28))
                    .frame(width: 7, height: 7)
            }
            .contentShape(.rect)
            .padding(.horizontal, DesignSpacing.s.pt)
            .padding(.vertical, DesignSpacing.xs.pt)
            .background {
                if selectedModule == module {
                    RoundedRectangle(cornerRadius: DesignRadius.small.pt, style: .continuous)
                        .fill(.primary.opacity(0.09))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(enhanced ? DynamicsNavigatorAccessibility.label(title: module.title, subtitle: module.subtitle) : module.title)
        .accessibilityValue(enhanced ? DynamicsNavigatorAccessibility.value(isOn: moduleIsActive(module)) : "")
        .accessibilityAddTraits(enhanced && selectedModule == module ? .isSelected : [])
    }

    /// E33 S4 (design 10): not a processor, so it has no number. Lists the dynamic EQ bands that are on; each opens the band.
    private var dynamicEQRow: some View {
        let entries = DynamicsEQLink.activeBands(engine.stereoEQConfiguration.editableBands)
        return VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            HStack(spacing: DesignSpacing.s.pt) {
                Image(systemName: "slider.horizontal.3").frame(width: 18).foregroundStyle(.secondary)
                Text(DynamicsEQLink.summary(count: entries.count)).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                Button(entry.title) {
                    EQBandFocusRequest.shared.request(entry.id)
                    openEqualizer?()
                }
                .buttonStyle(.link)
                .font(DesignType.caption.font)
                .accessibilityLabel("Open \(entry.title) in the Equalizer")
                .padding(.leading, 18 + DesignSpacing.s.pt)
            }
        }
        .padding(.horizontal, DesignSpacing.s.pt)
        .padding(.vertical, DesignSpacing.xs.pt)
        .accessibilityIdentifier("dynamics.eqLinkRow")
    }

    @ViewBuilder
    private var moduleEditor: some View {
        switch selectedModule {
        case .compressor: compressorEditor
        case .multiband: multibandEditor
        case .expander: expanderEditor
        case .pauseGate: pauseGateEditor
        case .gainRider: gainRiderEditor
        case .denoiser: denoiserEditor
        case .deEsser: deEsserEditor
        case .mainsHum: mainsHumEditor
        case .infrasonic: infrasonicEditor
        case .loudnessMatch: loudnessMatchEditor
        case .loudnessContour: loudnessContourEditor
        case .dialogueLeveler: dialogueLevelerEditor
        case .limiter: limiterEditor
        case .softClipper: softClipperEditor
        case .automaticHeadroom: automaticHeadroomEditor
        case .oversampling: oversamplingEditor
        case .deHarsh: deHarshEditor
        case .stereoWidener: stereoWidenerEditor
        case .stereoMode: stereoModeEditor
        case .dcOffset: dcOffsetEditor
        }
    }

    // MARK: - Dynamics

    private var compressorEditor: some View {
        moduleCard(
            module: .compressor,
            enabled: boolBinding({ $0.compressor.enabled }, { $0.compressor.enabled = $1 }),
            reset: { preserveEnabledReset(\.compressor, defaultValue: CompressorConfiguration()) }
        ) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .compressor)
            row(.compressorThresholdDB)
            row(.compressorRatio)
            row(.compressorKneeWidthDB)
            row(.compressorAttackMs)
            row(.compressorReleaseMs)
            row(.compressorMakeupGainDB, enabled: configuration.compressor.autoMakeupGain != true)
            Toggle("Auto Makeup", isOn: binding(
                { $0.compressor.autoMakeupGain == true },
                { $0.compressor.autoMakeupGain = $1 }
            ))
            .help(Self.autoMakeupHelp)
            .accessibilityIdentifier("dynamics.compressor.autoMakeup")

            Divider()
            HStack(spacing: DesignSpacing.m.pt) {
                Text("Topology")
                Picker("Topology", selection: binding({ $0.compressor.topology }, { $0.compressor.topology = $1 })) {
                    ForEach(CompressorTopology.allCases) { topology in
                        Text(topology.displayName).tag(topology)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            Toggle("Program-Dependent Release", isOn: boolBinding({ $0.compressor.programDependentRelease }, { $0.compressor.programDependentRelease = $1 }))
                .help("Release starts at half the set time for light gain reduction and lengthens to twice the set time as the reduction deepens toward 12 dB, so brief peaks recover quickly and sustained material does not pump.")
            row(.compressorSidechainHighPassHz)
                .help("0 Hz disables the sidechain high-pass filter.")
            compressorExtras
        }
    }

    // MARK: - Extras (E28 S7d)

    private var extrasAvailability: DynamicsExtrasAvailability {
        DynamicsExtrasAvailability(
            flagOn: FeatureFlags().isEnabled(.dynamicsExtras),
            running: engine.dynamicsListenHost != nil
        )
    }

    private func reasonNote(_ reason: String?) -> some View {
        Group {
            if let reason {
                Text(reason).font(DesignType.caption.font).foregroundStyle(.secondary)
                    .accessibilityLabel("Unavailable: \(reason)")
            }
        }
    }

    private func extraToggle(
        _ title: String, id: String, enabled: Bool, help: String? = nil,
        get: @escaping (DynamicsConfiguration) -> Bool, set: @escaping (inout DynamicsConfiguration, Bool) -> Void
    ) -> some View {
        Toggle(title, isOn: binding(get, set))
            .disabled(!enabled)
            .help(help ?? title)
            .accessibilityIdentifier(id)
    }

    /// Listen (sidechain) and Delta buttons for one stage; one listener in the whole graph.
    private func listenButtons(_ stage: DynamicsListenStage, id: String) -> some View {
        let av = extrasAvailability
        func isOn(_ mode: DynamicsListenMode) -> Bool { engine.dynamicsListener == DynamicsListener(stage: stage, mode: mode) }
        func toggle(_ mode: DynamicsListenMode, _ title: String, _ help: String) -> some View {
            Toggle(title, isOn: Binding(
                get: { isOn(mode) },
                set: { on in perform { try engine.setDynamicsListener(on ? DynamicsListener(stage: stage, mode: mode) : nil) } }
            ))
            .toggleStyle(.button)
            .disabled(!av.listenEnabled)
            .help(av.listenDisabledReason ?? help)
            .accessibilityIdentifier("\(id).\(mode == .sidechain ? "listen" : "delta")")
            .accessibilityValue(isOn(mode) ? "Listening" : "Off")
        }
        return HStack(spacing: DesignSpacing.s.pt) {
            toggle(.sidechain, "Listen", "Plays the detector input after the sidechain filter and before any gain. Session only; one listener at a time.")
            toggle(.delta, "Delta", "Plays what this stage removes (dry minus processed, before make-up). Session only; one listener at a time.")
        }
    }

    @ViewBuilder
    private var listeningBanner: some View {
        if let listener = engine.dynamicsListener {
            HStack {
                Label(listener.bannerText, systemImage: "ear")
                Spacer()
                Button("Stop Listening") { perform { try engine.setDynamicsListener(nil) } }
                    .accessibilityIdentifier("dynamics.listen.stop")
            }
            .padding(DesignSpacing.s.pt)
            .designTint(StatusLevel.attention.color, opacity: 0.18)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dynamics.listen.banner")
        }
        if !engine.dynamicsSoloBands.isEmpty {
            HStack {
                let names = engine.dynamicsSoloBands.sorted().map { ["low", "mid", "high", "band 4", "band 5"][$0] }.joined(separator: ", ")
                Label("Soloing the multiband \(names) band\(engine.dynamicsSoloBands.count == 1 ? "" : "s"). Downstream protection still applies.", systemImage: "speaker.wave.2")
                Spacer()
                Button("Clear Solo") { perform { try engine.setDynamicsSoloBands([]) } }
                    .accessibilityIdentifier("dynamics.solo.clear")
            }
            .padding(DesignSpacing.s.pt)
            .designTint(StatusLevel.attention.color, opacity: 0.18)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dynamics.solo.banner")
        }
    }

    @ViewBuilder
    private var compressorExtras: some View {
        if extrasAvailability.flagOn {
            let av = extrasAvailability
            let c = configuration.compressor
            Divider()
            Text("Extras").font(DesignType.sectionTitle.font)
            reasonNote(av.extrasDisabledReason)
            row(.compressorMixPercent, enabled: av.extrasEnabled)
            row(.compressorLinkPercent, enabled: av.extrasEnabled)
            extraToggle("RMS Detector", id: "dynamics.compressor.rms", enabled: av.extrasEnabled,
                        help: "Off reads peaks; on reads a one-pole RMS over the detector window.",
                        get: { $0.compressor.rmsDetectorOn }, set: { $0.compressor.rmsDetectorOn = $1 })
            row(.compressorRMSWindowMs, enabled: av.extrasEnabled && c.rmsDetectorOn)
            extraToggle("Lookahead", id: "dynamics.compressor.lookahead", enabled: av.extrasEnabled,
                        help: "Delays the audio so the compressor can react before a peak. It adds latency.",
                        get: { $0.compressor.lookaheadOn }, set: { $0.compressor.lookaheadOn = $1 })
            row(.compressorLookaheadMs, enabled: av.extrasEnabled && c.lookaheadOn)
            if c.lookaheadOn {
                Text(DynamicsExtrasAvailability.addsText(ms: c.lookaheadTimeMs, sampleRate: engine.liveTreatmentSampleRate))
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
                    .accessibilityIdentifier("dynamics.compressor.lookahead.adds")
            }
            reasonNote(av.listenDisabledReason)
            listenButtons(.compressor, id: "dynamics.compressor")
        }
    }

    @ViewBuilder
    private var expanderExtras: some View {
        if extrasAvailability.flagOn {
            let av = extrasAvailability
            Divider()
            Text("Extras").font(DesignType.sectionTitle.font)
            reasonNote(av.extrasDisabledReason)
            row(.expanderHoldMs, enabled: av.extrasEnabled)
            row(.expanderKneeDB, enabled: av.extrasEnabled)
            extraToggle("RMS Detector", id: "dynamics.expander.rms", enabled: av.extrasEnabled,
                        help: "Off reads peaks; on reads a one-pole RMS over the detector window.",
                        get: { $0.expander.rmsDetectorOn }, set: { $0.expander.rmsDetectorOn = $1 })
            row(.expanderRMSWindowMs, enabled: av.extrasEnabled && configuration.expander.rmsDetectorOn)
            row(.expanderSidechainHighPassHz, enabled: av.extrasEnabled)
                .help("0 Hz disables the sidechain high-pass filter.")
            row(.expanderLinkPercent, enabled: av.extrasEnabled)
            if FeatureFlags().isEnabled(.eqPageEnhancements) {
                // E33 S5a: the detector reads the undelayed signal; the audio is delayed so the gate is open for the first transient.
                extraToggle("Lookahead", id: "dynamics.expander.lookahead", enabled: av.extrasEnabled,
                            help: "Delays the audio so the expander opens before a transient arrives. It adds latency.",
                            get: { $0.expander.lookaheadOn }, set: { $0.expander.lookaheadOn = $1 })
                row(.expanderLookaheadMs, enabled: av.extrasEnabled && configuration.expander.lookaheadOn)
                if configuration.expander.lookaheadOn {
                    Text(DynamicsExtrasAvailability.addsText(ms: configuration.expander.lookaheadTimeMs, sampleRate: engine.liveTreatmentSampleRate))
                        .font(DesignType.caption.font).foregroundStyle(.secondary)
                        .accessibilityIdentifier("dynamics.expander.lookahead.adds")
                }
            }
            reasonNote(av.listenDisabledReason)
            listenButtons(.expander, id: "dynamics.expander")
        }
    }

    @ViewBuilder
    private var multibandExtras: some View {
        if extrasAvailability.flagOn {
            let av = extrasAvailability
            let m = configuration.multibandCompressor
            GroupBox("Extras") {
                VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                    reasonNote(av.extrasDisabledReason)
                    row(.multibandRMSWindowMs, enabled: av.extrasEnabled)
                    extraToggle("Lookahead (all bands)", id: "dynamics.multiband.lookahead", enabled: av.extrasEnabled,
                                help: "One delay for the whole stage so the bands stay aligned. It adds latency.",
                                get: { $0.multibandCompressor.lookaheadOn }, set: { $0.multibandCompressor.lookaheadOn = $1 })
                    row(.multibandLookaheadMs, enabled: av.extrasEnabled && m.lookaheadOn)
                    if m.lookaheadOn {
                        Text(DynamicsExtrasAvailability.addsText(ms: m.lookaheadTimeMs, sampleRate: engine.liveTreatmentSampleRate))
                            .font(DesignType.caption.font).foregroundStyle(.secondary)
                            .accessibilityIdentifier("dynamics.multiband.lookahead.adds")
                    }
                }
                .padding(.vertical, DesignSpacing.s.pt)
            }
        }
    }

    @ViewBuilder
    private func multibandBandExtras(band: Int) -> some View {
        if extrasAvailability.flagOn {
            let av = extrasAvailability
            let id = "dynamics.multiband.\(band)"
            Divider()
            reasonNote(av.extrasDisabledReason)
            extraToggle("Bypass", id: "\(id).bypass", enabled: av.bypassEnabled,
                        help: "Passes this band at unity. Works on the legacy kernel too.",
                        get: { MultibandCompressorConfiguration.contains($0.multibandCompressor.bypassedBands, band) },
                        set: { $0.multibandCompressor.bypassedBands = MultibandCompressorConfiguration.toggled($0.multibandCompressor.bypassedBands, band: band, on: $1) })
            extraToggle("RMS Detector", id: "\(id).rms", enabled: av.extrasEnabled,
                        get: { MultibandCompressorConfiguration.contains($0.multibandCompressor.rmsDetectorBands, band) },
                        set: { $0.multibandCompressor.rmsDetectorBands = MultibandCompressorConfiguration.toggled($0.multibandCompressor.rmsDetectorBands, band: band, on: $1) })
            extraToggle("Auto Release", id: "\(id).autoRelease", enabled: av.extrasEnabled,
                        help: "Program-dependent release for this band.",
                        get: { MultibandCompressorConfiguration.contains($0.multibandCompressor.autoReleaseBands, band) },
                        set: { $0.multibandCompressor.autoReleaseBands = MultibandCompressorConfiguration.toggled($0.multibandCompressor.autoReleaseBands, band: band, on: $1) })
            reasonNote(av.listenDisabledReason)
            HStack(spacing: DesignSpacing.s.pt) {
                Toggle("Solo", isOn: Binding(
                    get: { engine.dynamicsSoloBands.contains(band) },
                    set: { on in
                        var bands = engine.dynamicsSoloBands
                        if on { bands.insert(band) } else { bands.remove(band) }
                        perform { try engine.setDynamicsSoloBands(bands) }
                    }
                ))
                .toggleStyle(.button)
                .disabled(!av.listenEnabled)
                .help(av.listenDisabledReason ?? "Plays only this band. Session only.")
                .accessibilityIdentifier("\(id).solo")
                listenButtons([DynamicsListenStage.multibandLow, .multibandMid, .multibandHigh, .multibandBand4, .multibandBand5][band], id: id)
            }
        }
    }

    private var multibandEditor: some View {
        moduleCard(
            module: .multiband,
            enabled: boolBinding({ $0.multibandCompressor.enabled }, { $0.multibandCompressor.enabled = $1 }),
            reset: { preserveEnabledReset(\.multibandCompressor, defaultValue: MultibandCompressorConfiguration()) }
        ) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .multiband)
            GroupBox("Crossovers") {
                VStack(spacing: DesignSpacing.m.pt) {
                    // E33 S5b: 2 to 5 bands behind `e33.page-enhancements`; the three-band page is unchanged with the flag off.
                    let count = bandsEnabled ? configuration.multibandCompressor.bandCountValue : 3
                    if bandsEnabled {
                        Picker("Bands", selection: binding({ $0.multibandCompressor.bandCountValue }, { $0.multibandCompressor.setBandCount($1) })) {
                            ForEach(Array(MultibandCompressorConfiguration.bandCountRange), id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("dynamics.multiband.bandCount")
                        Text("Changing the band count rebuilds the stage and resets its filters; the crossovers move to a sensible spread.")
                            .font(DesignType.caption.font).foregroundStyle(.secondary)
                    }
                    row(.multibandCompressorLowMidFrequencyHz, title: count == 3 || !bandsEnabled ? nil : "Crossover 1")
                    Picker("Crossover 1 Slope", selection: binding({ $0.multibandCompressor.lowMidSlope }, { $0.multibandCompressor.lowMidSlope = $1 })) {
                        ForEach(MultibandSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                    }
                    if count >= 3 {
                        row(.multibandCompressorMidHighFrequencyHz, title: bandsEnabled ? "Crossover 2" : nil)
                        Picker("Crossover 2 Slope", selection: binding({ $0.multibandCompressor.midHighSlope }, { $0.multibandCompressor.midHighSlope = $1 })) {
                            ForEach(MultibandSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                        }
                    }
                    if count >= 4 {
                        row(.multibandCompressorCorner2Hz)
                        Picker("Crossover 3 Slope", selection: binding({ $0.multibandCompressor.slope2Value }, { $0.multibandCompressor.slope2Value = $1 })) {
                            ForEach(MultibandSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                        }
                    }
                    if count >= 5 {
                        row(.multibandCompressorCorner3Hz)
                        Picker("Crossover 4 Slope", selection: binding({ $0.multibandCompressor.slope3Value }, { $0.multibandCompressor.slope3Value = $1 })) {
                            ForEach(MultibandSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                        }
                    }
                    if bandsEnabled, !configuration.multibandCompressor.corners.isEmpty,
                       zip(configuration.multibandCompressor.corners, configuration.multibandCompressor.corners.dropFirst()).contains(where: { $0 >= $1 }) {
                        Text("Crossovers must rise in order; the engine keeps the last valid setting until they do.")
                            .font(DesignType.caption.font).foregroundStyle(StatusLevel.problem.color)
                            .accessibilityIdentifier("dynamics.multiband.cornerOrder")
                    }
                }
                .padding(.vertical, DesignSpacing.s.pt)
            }

            multibandExtras
            let bands = bandsEnabled ? configuration.multibandCompressor.bandCountValue : 3
            ForEach(0..<bands, id: \.self) { band in
                multibandBandEditor(band: band, title: Self.multibandBandTitle(band, of: bands))
            }
        }
    }

    private var bandsEnabled: Bool { FeatureFlags().isEnabled(.eqPageEnhancements) }

    /// "Low Band", "Mid Band", "High Band" for three bands (as before); numbered for 2, 4 and 5.
    static func multibandBandTitle(_ band: Int, of count: Int) -> String {
        if count == 3 { return ["Low Band", "Mid Band", "High Band"][band] }
        if band == 0 { return "Low Band" }
        if band == count - 1 { return "High Band" }
        return "Band \(band + 1)"
    }

    private var expanderEditor: some View {
        moduleCard(module: .expander, enabled: boolBinding({ $0.expander.enabled }, { $0.expander.enabled = $1 }), reset: { preserveEnabledReset(\.expander, defaultValue: ExpanderConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .expander)
            row(.expanderThresholdDB)
            row(.expanderRatio)
            row(.expanderRangeDB)
            row(.expanderAttackMs)
            row(.expanderReleaseMs)
            if DynamicsSoundFixes.isEnabled {  // E32 S5: the core swaps the timing behind `e32.dynamics-sound`
                Text("Attack sets how fast the expander opens; Release sets how fast it closes.")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
                    .accessibilityIdentifier("dynamics.expander.timing.help")
            }
            expanderExtras
        }
    }

    private var pauseGateEditor: some View {
        moduleCard(module: .pauseGate, enabled: boolBinding({ $0.pauseGate.enabled }, { $0.pauseGate.enabled = $1 }), reset: { preserveEnabledReset(\.pauseGate, defaultValue: PauseGateConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .pauseGate)
            Picker("Preset", selection: binding({ $0.pauseGate.preset }, { config, value in config.pauseGate.applyPreset(value) })) {
                ForEach(PauseGatePreset.allCases) { preset in Text(preset.displayName).tag(preset) }
            }
            .pickerStyle(.menu)

            row(.pauseGateThresholdDBFS)
            row(.pauseGateHoldMs)
            row(.pauseGateAttackMs)
                .help("Attack is the fade-out / gate-close time.")
            row(.pauseGateReleaseMs)
                .help("Release is the fade-in / gate-open time.")
            row(.pauseGateHysteresisDB)

            Label("Product convention: Attack = fade-out, Release = fade-in.", systemImage: "info.circle")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
    }

    private var gainRiderEditor: some View {
        moduleCard(module: .gainRider, enabled: boolBinding({ $0.gainRider.enabled }, { $0.gainRider.enabled = $1 }), reset: { preserveEnabledReset(\.gainRider, defaultValue: GainRiderConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .gainRider)
            row(.gainRiderTargetGainReductionDB)
            row(.gainRiderMaxReductionDB)
            Picker("Response", selection: binding({ $0.gainRider.speed }, { $0.gainRider.speed = $1 })) {
                ForEach(GainRiderSpeed.allCases) { speed in Text(speed.displayName).tag(speed) }
            }
            .pickerStyle(.segmented)
            Text("The live readout above is derived from existing Gain Rider runtime state and does not activate unrelated metering or analysis.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Restoration

    private var denoiserEditor: some View {
        moduleCard(module: .denoiser, enabled: boolBinding({ $0.spectralDenoiser.enabled }, { $0.spectralDenoiser.enabled = $1 }), reset: resetDenoiser) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .denoiser)
            Picker("Preset", selection: Binding(
                get: { configuration.spectralDenoiser.preset },
                set: { preset in perform { try engine.applySpectralDenoiserPreset(preset) } }
            )) {
                ForEach(SpectralDenoiserPreset.allCases) { preset in Text(preset.displayName).tag(preset) }
            }
            .pickerStyle(.menu)

            Picker("Quality", selection: denoiserBinding({ $0.quality }, { $0.quality = $1; $0.markCustom() })) {
                ForEach(SpectralDenoiserQuality.allCases) { quality in Text(quality.displayName).tag(quality) }
            }
            .pickerStyle(.segmented)

            row(.spectralDenoiserThresholdDBFS)
            row(.spectralDenoiserReductionAmount)

            Toggle("Protect Frequency Range", isOn: denoiserBinding({ $0.protectedRangeEnabled }, { $0.protectedRangeEnabled = $1; $0.markCustom() }))
            if configuration.spectralDenoiser.protectedRangeEnabled {
                row(.spectralDenoiserProtectedLowHz)
                row(.spectralDenoiserProtectedHighHz)
            }

            DisclosureGroup("Advanced Suppression") {
                VStack(spacing: DesignSpacing.m.pt) {
                    Toggle("Override Preset Smoothing", isOn: denoiserBinding({ $0.advancedTuningEnabled }, { $0.advancedTuningEnabled = $1; $0.markCustom() }))
                    row(.spectralDenoiserMinimumGain)
                        .disabled(!configuration.spectralDenoiser.advancedTuningEnabled)
                    row(.spectralDenoiserAttackMs)
                        .disabled(!configuration.spectralDenoiser.advancedTuningEnabled)
                    row(.spectralDenoiserReleaseMs)
                        .disabled(!configuration.spectralDenoiser.advancedTuningEnabled)
                    Text("Named presets retain their accepted internal suppression behavior. These values take effect only when the explicit override is enabled.")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, DesignSpacing.s.pt)
            }

            Divider()
            HStack {
                Button("Capture Noise Profile") { perform { try engine.captureSpectralNoiseProfile() } }
                    .buttonStyle(.glassProminent)
                Button("Reset Profile") { perform { try engine.resetSpectralNoiseProfile() } }
                    .buttonStyle(.glass)
                Spacer()
            }
        }
    }

    private var deEsserEditor: some View {
        moduleCard(module: .deEsser, enabled: boolBinding({ $0.deEsser.enabled }, { $0.deEsser.enabled = $1 }), reset: { preserveEnabledReset(\.deEsser, defaultValue: DeEsserConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .deEsser)
            row(.deEsserFrequencyHz)
            row(.deEsserDetectionQ)
            row(.deEsserThresholdDB)
            row(.deEsserRatio)
            row(.deEsserRangeDB)
            row(.deEsserAttackMs)
            row(.deEsserReleaseMs)
            DisclosureGroup("Advanced") {
                Toggle("Dynamic-EQ Processing Mode", isOn: boolBinding({ $0.deEsser.dynamicEQMode }, { $0.deEsser.dynamicEQMode = $1 }))
                    .padding(.top, DesignSpacing.s.pt)
            }
        }
    }

    private var mainsHumEditor: some View {
        moduleCard(module: .mainsHum, enabled: boolBinding({ $0.mainsNotch.enabled }, { $0.mainsNotch.enabled = $1 }), reset: resetMainsHum) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .mainsHum)
            Picker("Mains Region", selection: binding({ $0.mainsNotch.region }, { config, region in config.mainsNotch.selectRegion(region) })) {
                ForEach(MainsRegion.allCases) { region in Text(region.displayName).tag(region) }
            }
            .pickerStyle(.segmented)

            HStack {
                Toggle("Continuous Tracking", isOn: boolBinding({ $0.mainsNotch.continuousTracking }, { $0.mainsNotch.continuousTracking = $1 }))
                Spacer()
                Button(mainsDetectInFlight ? "Detecting…" : "Detect") {
                    guard !mainsDetectInFlight else { return }
                    mainsDetectInFlight = true
                    mainsDetectionMessage = nil
                    Task { @MainActor in
                        do {
                            let applied = try await engine.detectMainsHumOnce()
                            mainsDetectionMessage = applied ? "Detected frequency applied." : "No stable mains tone detected."
                        } catch {
                            mainsDetectionMessage = error.localizedDescription
                        }
                        mainsDetectInFlight = false
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(mainsDetectInFlight || engine.lifecycleState != .running)
            }
            if let mainsDetectionMessage {
                Text(mainsDetectionMessage).font(DesignType.caption.font).foregroundStyle(.secondary)
            }
            Text("Current fundamental: \(configuration.mainsNotch.fundamentalHz, specifier: "%.2f") Hz")
                .font(DesignType.caption.font.monospacedDigit())
                .foregroundStyle(.secondary)

            Stepper("Harmonics: \(configuration.mainsNotch.harmonicCount)", value: binding({ $0.mainsNotch.harmonicCount }, { $0.mainsNotch.harmonicCount = $1 }), in: MainsNotchConfiguration.harmonicCountRange)
            row(.mainsNotchQ)

            DisclosureGroup("Harmonic Depths") {
                VStack(spacing: DesignSpacing.s.pt) {
                    ForEach(0..<configuration.mainsNotch.harmonicCount, id: \.self) { index in
                        row(
                            DynamicsParameterSpec.harmonicDepth(index),
                            title: "H\(index + 1) · \(Int(configuration.mainsNotch.fundamentalHz * Double(index + 1))) Hz"
                        )
                    }
                }
                .padding(.top, DesignSpacing.s.pt)
            }
        }
    }

    private var infrasonicEditor: some View {
        moduleCard(module: .infrasonic, enabled: boolBinding({ $0.infrasonicFilter.enabled }, { $0.infrasonicFilter.enabled = $1 }), reset: { preserveEnabledReset(\.infrasonicFilter, defaultValue: InfrasonicFilterConfiguration()) }) {
            row(.infrasonicFilterCutoffHz)
            Picker("Slope", selection: binding({ $0.infrasonicFilter.slope }, { $0.infrasonicFilter.slope = $1 })) {
                ForEach(InfrasonicSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
            }
            .pickerStyle(.segmented)
            Label("Legacy application-target routing is tracked as a parity gap. Main/sub target selection will live with crossover/output routing rather than be duplicated here.", systemImage: "arrow.triangle.branch")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Level & Dialogue

    private var loudnessMatchEditor: some View {
        moduleCard(module: .loudnessMatch, enabled: boolBinding({ $0.loudnessMatch.enabled }, { $0.loudnessMatch.enabled = $1 }), reset: { preserveEnabledReset(\.loudnessMatch, defaultValue: LoudnessMatchConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .loudnessMatch)
            row(.loudnessMatchTargetLUFS)
            row(.loudnessMatchMaxCorrectionDB)
            row(.loudnessMatchAttackSeconds)
            row(.loudnessMatchReleaseSeconds)
            Toggle("Dialogue Gate", isOn: boolBinding({ $0.loudnessMatch.dialogueGateEnabled }, { $0.loudnessMatch.dialogueGateEnabled = $1 }))
        }
    }

    private var loudnessContourEditor: some View {
        moduleCard(module: .loudnessContour, enabled: boolBinding({ $0.loudnessContour.enabled }, { $0.loudnessContour.enabled = $1 }), reset: { preserveEnabledReset(\.loudnessContour, defaultValue: LoudnessContourConfiguration()) }) {
            if FeatureFlags().isEnabled(.dynamicsExtras) {  // E28 S7d part 3 (G21)
                ProductionDynamicsTelemetryView(engine: engine, kind: .loudnessContour)
            }
            row(.loudnessContourStrength)
            row(.loudnessContourReferencePhons)
            row(.loudnessContourMaxBoostDB)
            row(.loudnessContourMaxCutDB)
            Picker("Level Source", selection: binding({ $0.loudnessContour.levelSource }, { $0.loudnessContour.levelSource = $1 })) {
                ForEach(LoudnessLevelSource.allCases) { source in Text(source.displayName).tag(source) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var dialogueLevelerEditor: some View {
        moduleCard(module: .dialogueLeveler, enabled: boolBinding({ $0.dialogueRelativeLeveler.enabled }, { $0.dialogueRelativeLeveler.enabled = $1 }), reset: { preserveEnabledReset(\.dialogueRelativeLeveler, defaultValue: DialogueRelativeLevelerConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .dialogue)
            row(.dialogueRelativeLevelerBandLowHz)
            row(.dialogueRelativeLevelerBandHighHz)
            row(.dialogueRelativeLevelerTargetGapDB)
            row(.dialogueRelativeLevelerBoostRatio)
            row(.dialogueRelativeLevelerMaxBoostDB)
            row(.dialogueRelativeLevelerAttackMs)
            row(.dialogueRelativeLevelerReleaseMs)
            row(.dialogueRelativeLevelerProgramGateThresholdDB)

            Divider()
            Toggle("Voice Gate", isOn: boolBinding({ $0.dialogueRelativeLeveler.voiceGate.enabled }, { $0.dialogueRelativeLeveler.voiceGate.enabled = $1 }))
            if configuration.dialogueRelativeLeveler.voiceGate.enabled {
                row(.dialogueRelativeLevelerVoiceGateSensitivity)
                row(.dialogueRelativeLevelerVoiceGateMinConfidence)
            }

            DisclosureGroup("Advanced Detection") {
                VStack(spacing: DesignSpacing.m.pt) {
                    row(.dialogueRelativeLevelerDetectorWindowMs)
                    row(.dialogueRelativeLevelerVoiceGateModulationCenterHz)
                    row(.dialogueRelativeLevelerVoiceGateModulationBandwidthHz)
                    row(.dialogueRelativeLevelerVoiceGateEnvelopeWindowMs)
                    row(.dialogueRelativeLevelerVoiceGateMeasurementWindowMs)
                    row(.dialogueRelativeLevelerVoiceGateConfidenceFloorIndex)
                    row(.dialogueRelativeLevelerVoiceGateConfidenceCeilingIndex)
                }
                .padding(.top, DesignSpacing.s.pt)
            }
        }
    }

    // MARK: - Protection

    private var limiterEditor: some View {
        moduleCard(module: .limiter, enabled: boolBinding({ $0.limiter.enabled }, { $0.limiter.enabled = $1 }), reset: { preserveEnabledReset(\.limiter, defaultValue: LimiterConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .limiter)
            if enhanced {
                LimiterProtectionLineView(
                    engine: engine, limiterOn: configuration.limiter.enabled, monitor: GainReductionMonitor.shared(for: engine))
            }
            row(.limiterCeilingDB)
            row(.limiterAttackMs)
            if LimiterAutoRelease.isAvailable, configuration.limiter.isAutoRelease {
                // E33 S14: the fixed value is kept (and shown when Auto is switched off) but not used while Auto is on.
                ProductionLimiterReleaseReadout(engine: engine)
            } else {
                row(.limiterReleaseMs)
            }
            row(.limiterLookAheadMs)
            if LimiterAutoRelease.isAvailable {
                Toggle("Auto Release", isOn: boolBinding({ $0.limiter.isAutoRelease }, { $0.limiter.autoRelease = $1 ? true : nil }))
                    .help("Release follows how long the limiter has been holding gain reduction: fast after a single peak, slower under sustained limiting. Off keeps the fixed Release time.")
                    .accessibilityIdentifier("dynamics.limiter.autoRelease")
            }
            // E32 S5 (`e32.dynamics-sound`): the core caps the attack at the look-ahead; the stored value is kept.
            if DynamicsSoundFixes.isEnabled, configuration.limiter.enabled,
               DynamicsSoundFixes.attackIsLimited(attackMs: configuration.limiter.attackMs, lookAheadMs: configuration.limiter.lookAheadMs) {
                Text("Attack limited to the lookahead")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
                    .accessibilityIdentifier("dynamics.limiter.attack.limited")
            }
            Toggle("True-Peak Guard", isOn: boolBinding({ $0.limiter.truePeakGuardEnabled }, { $0.limiter.truePeakGuardEnabled = $1 }))
            // E9 S5b: per-output protection (empty unless `e9.output-protection` is on).
            ProductionOutputProtectionSection(
                engine: engine, settings: configuration.outputProtection ?? OutputProtectionSettings(),
                apply: { next in update { $0.outputProtection = next == OutputProtectionSettings() ? nil : next } },
                programLimiterOn: configuration.limiter.enabled)
        }
    }

    private var softClipperEditor: some View {
        moduleCard(module: .softClipper, enabled: boolBinding({ $0.softClipper.enabled }, { $0.softClipper.enabled = $1 }), reset: { preserveEnabledReset(\.softClipper, defaultValue: SoftClipperConfiguration()) }) {
            row(.softClipperDriveDB)
            row(.softClipperThresholdDB)
            row(.softClipperKneeSmooth)
            Picker("Curve", selection: binding({ $0.softClipper.curve }, { $0.softClipper.curve = $1 })) {
                ForEach(SoftClipperCurve.allCases) { curve in Text(curve.displayName).tag(curve) }
            }
            .pickerStyle(.menu)
            Toggle("Automatic Gain Compensation", isOn: boolBinding({ $0.softClipper.autoCompensateGain }, { $0.softClipper.autoCompensateGain = $1 }))
            row(.softClipperAsymmetryTrimDB)
        }
    }

    private var automaticHeadroomEditor: some View {
        moduleCard(module: .automaticHeadroom, enabled: boolBinding({ $0.automaticHeadroom.enabled }, { $0.automaticHeadroom.enabled = $1 }), reset: { preserveEnabledReset(\.automaticHeadroom, defaultValue: AutomaticHeadroomConfiguration()) }) {
            row(.automaticHeadroomMaxAttenuationDB)
            Text("Predictive headroom is distinct from the Dynamic Gain Rider: it reserves known filter/EQ headroom before clipping can occur, rather than reacting to limiter activity.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
    }

    private var oversamplingEditor: some View {
        moduleCard(module: .oversampling, enabled: nil, reset: { update { $0.oversampling = .one } }) {
            Picker("Protection Oversampling", selection: binding({ $0.oversampling }, { $0.oversampling = $1 })) {
                ForEach(OversamplingFactor.allCases) { factor in Text(factor.displayName).tag(factor) }
            }
            .pickerStyle(.segmented)
            Text("Use higher factors when nonlinear protection stages need additional anti-aliasing margin. CPU cost rises with factor.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Conditioning

    private var deHarshEditor: some View {
        moduleCard(module: .deHarsh, enabled: boolBinding({ $0.deHarsh.enabled }, { $0.deHarsh.enabled = $1 }), reset: { preserveEnabledReset(\.deHarsh, defaultValue: DeHarshConfiguration()) }) {
            row(.deHarshAmountDB)
            row(.deHarshFrequencyHz)
        }
    }

    private var stereoWidenerEditor: some View {
        moduleCard(module: .stereoWidener, enabled: boolBinding({ $0.stereoWidener.enabled }, { $0.stereoWidener.enabled = $1 }), reset: { preserveEnabledReset(\.stereoWidener, defaultValue: StereoWidenerConfiguration()) }) {
            Toggle("Mono Low Band", isOn: boolBinding({ $0.stereoWidener.monoLowBand }, { $0.stereoWidener.monoLowBand = $1 }))
            row(.stereoWidenerLowWidth)
            row(.stereoWidenerLowMidFrequencyHz)
            row(.stereoWidenerMidWidth)
            row(.stereoWidenerMidHighFrequencyHz)
            row(.stereoWidenerHighWidth)
        }
    }

    private var stereoModeEditor: some View {
        moduleCard(module: .stereoMode, enabled: nil, reset: { update { $0.stereoMode = .stereo } }) {
            Picker("Stereo Processing Mode", selection: binding({ $0.stereoMode }, { $0.stereoMode = $1 })) {
                ForEach(StereoProcessingMode.allCases) { mode in Text(mode.displayName).tag(mode) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var dcOffsetEditor: some View {
        moduleCard(module: .dcOffset, enabled: boolBinding({ $0.dcOffsetFilter.enabled }, { $0.dcOffsetFilter.enabled = $1 }), reset: { preserveEnabledReset(\.dcOffsetFilter, defaultValue: DCOffsetFilterConfiguration()) }) {
            Text("Removes DC bias with the production 0.5 Hz high-pass stage. There are intentionally no tone-shaping controls because this is a utility filter.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Shared UI

    private func moduleCard<Content: View>(
        module: ProductionDynamicsModule,
        enabled: Binding<Bool>?,
        reset: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: DesignSpacing.l.pt) {
                Image(systemName: module.systemImage)
                    .font(.title2)
                    .frame(width: 32, height: 32)
                    .glassEffect(.regular, in: .circle)
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text(module.title).font(DesignType.sectionTitle.font)
                    Text(module.longDescription).foregroundStyle(.secondary)
                }
                Spacer()
                if let enabled {
                    Toggle(module.title, isOn: enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("\(module.title) enabled")
                        .accessibilityIdentifier("dynamics.\(module.rawValue).enabled")
                }
                Button("Reset", action: reset)
                    .buttonStyle(.glass)
                    .accessibilityLabel("Reset \(module.title)")
                    .accessibilityIdentifier("dynamics.\(module.rawValue).reset")
            }
            .padding(.horizontal, DesignSpacing.xl.pt)
            .padding(.vertical, DesignSpacing.l.pt)

            Divider()

            AdaptiveColumnsLayout(minColumnWidth: 400, spacing: DesignSpacing.l.pt) {
                content()
            }
            .padding(DesignSpacing.xl.pt)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .designPanel()
        .padding(.bottom, DesignSpacing.xl.pt)
    }

    private func multibandBandEditor(band: Int, title: String) -> some View {
        let rows = DynamicsParameterSpec.multibandBand(band)
        let auto = configuration.multibandCompressor.autoMakeupBands?.contains(band) == true
        return DisclosureGroup(title) {
            VStack(spacing: DesignSpacing.m.pt) {
                ForEach(rows) { spec in
                    row(spec, enabled: !(auto && spec.title == "Makeup Gain"))
                    if spec.title == "Makeup Gain" {
                        Toggle("Auto Makeup", isOn: binding(
                            { $0.multibandCompressor.autoMakeupBands?.contains(band) == true },
                            { config, on in
                                var bands = config.multibandCompressor.autoMakeupBands ?? []
                                if on { bands.insert(band) } else { bands.remove(band) }
                                config.multibandCompressor.autoMakeupBands = bands.isEmpty ? nil : bands
                            }
                        ))
                        .help(Self.autoMakeupHelp)
                        .accessibilityIdentifier("dynamics.multiband.\(band).autoMakeup")
                    }
                }
                multibandBandExtras(band: band)
            }
            .padding(.top, DesignSpacing.s.pt)
        }
    }

    // MARK: - Bindings / mutation

    private func binding<Value>(
        _ get: @escaping (DynamicsConfiguration) -> Value,
        _ set: @escaping (inout DynamicsConfiguration, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { get(engine.dynamicsConfiguration) },
            set: { value in update { set(&$0, value) } }
        )
    }

    private func boolBinding(
        _ get: @escaping (DynamicsConfiguration) -> Bool,
        _ set: @escaping (inout DynamicsConfiguration, Bool) -> Void
    ) -> Binding<Bool> { binding(get, set) }

    private func doubleBinding(
        _ get: @escaping (DynamicsConfiguration) -> Double,
        _ set: @escaping (inout DynamicsConfiguration, Double) -> Void
    ) -> Binding<Double> { binding(get, set) }

    private func denoiserBinding<Value>(
        _ get: @escaping (SpectralDenoiserConfiguration) -> Value,
        _ set: @escaping (inout SpectralDenoiserConfiguration, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { get(engine.dynamicsConfiguration.spectralDenoiser) },
            set: { value in
                update { config in
                    set(&config.spectralDenoiser, value)
                }
            }
        )
    }

    /// Applies an edit and records it as one undo step. A refused edit leaves the stored configuration (so
    /// every row shows the live value) and shows `failure(reason)` or the engine's reason (E28 S4, G1).
    @discardableResult
    private func update(
        name: String = "Edit Dynamics",
        coalesceKey: String? = nil,
        failure: ((String) -> String)? = nil,
        _ mutation: (inout DynamicsConfiguration) -> Void
    ) -> Bool {
        let before = engine.dynamicsConfiguration
        var updated = before
        mutation(&updated)
        updated.applyAutoMakeup()
        do {
            try engine.replaceDynamicsConfiguration(updated)
            actionError = nil
            history.record(before: before, after: engine.dynamicsConfiguration, name: name, coalesceKey: coalesceKey)
            return true
        } catch {
            let reason = error.localizedDescription
            actionError = failure?(reason) ?? reason
            return false
        }
    }

    private func row(_ spec: DynamicsParameterSpec, enabled: Bool = true, title: String? = nil) -> some View {
        DynamicsParameterRow(
            spec: spec,
            title: title ?? spec.title,
            value: configuration[keyPath: spec.keyPath],
            isEnabled: enabled,
            reference: reference,
            commit: { value, isStep in
                update(
                    name: "Edit \(spec.stage) \(spec.title)",
                    coalesceKey: isStep ? spec.id : nil,
                    failure: { spec.rejectionMessage(value: value, reason: $0) }
                ) { spec.apply(value, to: &$0) }
            },
            beginGesture: {
                history.beginGesture(before: engine.dynamicsConfiguration, name: "Edit \(spec.stage) \(spec.title)")
            },
            endGesture: { history.endGesture(after: engine.dynamicsConfiguration) }
        )
    }

    private func configureHistory() {
        history.configure(
            undoManager: undoManager,
            live: { engine.dynamicsConfiguration },
            apply: { try engine.replaceDynamicsConfiguration($0) }
        )
    }

    static let autoMakeupHelp = "Sets makeup gain to restore the level this stage removes at a typical programme level of -18 dBFS, from the threshold, ratio and knee. Turning it off keeps the current value."

    private func preserveEnabledReset<Value>(_ keyPath: WritableKeyPath<DynamicsConfiguration, Value>, defaultValue: Value) {
        update { $0[keyPath: keyPath] = defaultValue }
    }

    private func resetDenoiser() {
        update { config in
            let enabled = config.spectralDenoiser.enabled
            config.spectralDenoiser = SpectralDenoiserConfiguration()
            config.spectralDenoiser.enabled = enabled
        }
    }

    private func resetMainsHum() {
        update { config in
            let enabled = config.mainsNotch.enabled
            config.mainsNotch = MainsNotchConfiguration()
            config.mainsNotch.enabled = enabled
        }
    }

    private var activeModuleCount: Int {
        ProductionDynamicsModule.allCases.reduce(0) { $0 + (moduleIsActive($1) ? 1 : 0) }
    }

    private func moduleIsActive(_ module: ProductionDynamicsModule) -> Bool {
        module.isActive(in: configuration)
    }
}

extension ProductionDynamicsModule {
    /// The stage whose gain reduction the navigator row shows (E28 S5).
    var gainReductionSource: GainReductionSource? {
        switch self {
        case .compressor: return .compressor
        case .expander: return .expander
        case .deEsser: return .deEsser
        case .limiter: return .limiter
        default: return nil
        }
    }
}

enum ProductionDynamicsModule: String, CaseIterable, Identifiable, Hashable {
    case compressor
    case multiband
    case expander
    case pauseGate
    case gainRider
    case denoiser
    case deEsser
    case mainsHum
    case infrasonic
    case loudnessMatch
    case loudnessContour
    case dialogueLeveler
    case limiter
    case softClipper
    case automaticHeadroom
    case oversampling
    case deHarsh
    case stereoWidener
    case stereoMode
    case dcOffset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compressor: return "Compressor"
        case .multiband: return "Multiband Compressor"
        case .expander: return "Expander"
        case .pauseGate: return "Pause Gate"
        case .gainRider: return "Dynamic Gain Rider"
        case .denoiser: return "Spectral Denoiser"
        case .deEsser: return "De-Esser"
        case .mainsHum: return "Mains Hum"
        case .infrasonic: return "Infrasonic Filter"
        case .loudnessMatch: return "LUFS Match"
        case .loudnessContour: return "Loudness Compensation"
        case .dialogueLeveler: return "Dialogue Leveler"
        case .limiter: return "Limiter"
        case .softClipper: return "Soft Clipper"
        case .automaticHeadroom: return "Automatic Headroom"
        case .oversampling: return "Oversampling"
        case .deHarsh: return "De-Harsh"
        case .stereoWidener: return "Stereo Widener"
        case .stereoMode: return "Stereo Mode"
        case .dcOffset: return "DC Offset Filter"
        }
    }

    var subtitle: String {
        switch self {
        case .compressor: return "Wideband level control"
        case .multiband: return "Three-band dynamics"
        case .expander: return "Downward expansion"
        case .pauseGate: return "Silence / amplifier-hiss gate"
        case .gainRider: return "Limiter-aware slow gain control"
        case .denoiser: return "Spectral noise reduction"
        case .deEsser: return "Sibilance control"
        case .mainsHum: return "50 / 60 Hz harmonic removal"
        case .infrasonic: return "Subsonic protection"
        case .loudnessMatch: return "Program loudness normalization"
        case .loudnessContour: return "Low-level listening compensation"
        case .dialogueLeveler: return "Masking-aware dialogue lift"
        case .limiter: return "Lookahead peak protection"
        case .softClipper: return "Pre-limiter peak shaping"
        case .automaticHeadroom: return "Predictive filter headroom"
        case .oversampling: return "Protection-stage sample rate"
        case .deHarsh: return "High-frequency conditioning"
        case .stereoWidener: return "Three-band width control"
        case .stereoMode: return "Stereo / mono fold-down"
        case .dcOffset: return "DC removal utility"
        }
    }

    var longDescription: String {
        switch self {
        case .compressor: return "Primary wideband compressor with topology, program-dependent release, and sidechain filtering."
        case .multiband: return "Independent Low, Mid, and High dynamics with production-accessible crossover slopes and per-band timing."
        case .expander: return "Downward expander for increasing low-level contrast without using a hard gate."
        case .pauseGate: return "Silences near-zero program material with explicit hold and click-free close/open fades."
        case .gainRider: return "Slowly manages sustained limiter activity before the final protection stages."
        case .denoiser: return "FFT-domain noise reduction with named tuning, profile capture, protected frequency ranges, and expert smoothing overrides."
        case .deEsser: return "Frequency-selective dynamics for sibilance and high-frequency harshness."
        case .mainsHum: return "Tracks and removes mains fundamentals and harmonics with independently adjustable notch depths."
        case .infrasonic: return "Steep subsonic high-pass protection. Output-target routing is deliberately owned by crossover/routing."
        case .loudnessMatch: return "Program-level LUFS matching with bounded correction and asymmetric timing."
        case .loudnessContour: return "Equal-loudness compensation for lower playback levels with bounded bass/treble correction."
        case .dialogueLeveler: return "Compares dialogue-band energy against the full program and lifts speech only when masking warrants it."
        case .limiter: return "Final lookahead limiter with optional true-peak reconstruction guard."
        case .softClipper: return "Nonlinear peak shaping before limiting, including selectable curve and asymmetric character."
        case .automaticHeadroom: return "Predictive attenuation budget that reserves headroom for known filter/EQ boosts."
        case .oversampling: return "Controls nonlinear protection oversampling independently from ordinary linear DSP."
        case .deHarsh: return "Broad high-frequency conditioning for fatiguing or aggressively mastered material."
        case .stereoWidener: return "Frequency-dependent Mid/Side width control with mono-bass protection."
        case .stereoMode: return "Global stereo, wide-mono, or true-mono processing mode."
        case .dcOffset: return "Removes DC bias before downstream dynamics processing."
        }
    }

    var systemImage: String {
        switch self {
        case .compressor: return "arrow.down.right.and.arrow.up.left"
        case .multiband: return "waveform.path"
        case .expander: return "arrow.up.left.and.arrow.down.right"
        case .pauseGate: return "pause.circle"
        case .gainRider: return "dial.medium"
        case .denoiser: return "waveform.badge.minus"
        case .deEsser: return "mouth"
        case .mainsHum: return "bolt.slash"
        case .infrasonic: return "speaker.wave.1"
        case .loudnessMatch: return "waveform.and.magnifyingglass"
        case .loudnessContour: return "ear"
        case .dialogueLeveler: return "quote.bubble"
        case .limiter: return "shield.lefthalf.filled"
        case .softClipper: return "waveform.path.badge.plus"
        case .automaticHeadroom: return "gauge.with.dots.needle.33percent"
        case .oversampling: return "4.circle"
        case .deHarsh: return "sparkles"
        case .stereoWidener: return "arrow.left.and.right"
        case .stereoMode: return "speaker.2"
        case .dcOffset: return "waveform.path.ecg.rectangle"
        }
    }
}

/// The dynamics navigator's groups, in the order the engine runs the
/// processors (`docs/DSP_KERNEL.md`). Niche processors fold under "More" in
/// their own group, so the list still reads as the signal path.
enum ProductionDynamicsLayout {
    struct Group: Identifiable, Equatable {
        let id: String
        let title: String
        let note: String?
        /// Every processor in the group, in signal-chain order.
        let modules: [ProductionDynamicsModule]
        /// The niche processors folded under "More" until it is expanded.
        let folded: Set<ProductionDynamicsModule>
        /// E33 S4: the group runs after the EQ stage, so the dynamic EQ link row sits before it.
        let runsAfterEQ: Bool

        init(
            id: String,
            title: String,
            note: String? = nil,
            modules: [ProductionDynamicsModule],
            folded: Set<ProductionDynamicsModule> = [],
            runsAfterEQ: Bool = false
        ) {
            self.id = id
            self.title = title
            self.note = note
            self.modules = modules
            self.folded = folded
            self.runsAfterEQ = runsAfterEQ
        }

        var shown: [ProductionDynamicsModule] { modules.filter { !folded.contains($0) } }
        var more: [ProductionDynamicsModule] { modules.filter { folded.contains($0) } }

        /// Drives the badge on a folded "More" row, so processing that is on
        /// is never hidden.
        func moreHasActiveModule(isActive: (ProductionDynamicsModule) -> Bool) -> Bool {
            more.contains(where: isActive)
        }
    }

    static let groups: [Group] = [
        Group(
            id: "input",
            title: "Input & Clean-up",
            note: "Runs before EQ and room correction.",
            modules: [.automaticHeadroom, .dcOffset, .infrasonic, .mainsHum, .denoiser],
            folded: [.dcOffset, .denoiser]
        ),
        Group(
            id: "stereo",
            title: "Stereo",
            note: "Runs after EQ and room correction.",
            modules: [.stereoMode, .stereoWidener],
            runsAfterEQ: true
        ),
        Group(
            id: "level",
            title: "Level & Dialogue",
            modules: [.loudnessMatch, .loudnessContour, .dialogueLeveler]
        ),
        Group(id: "tone", title: "Tone", modules: [.deHarsh, .deEsser], folded: [.deEsser]),
        Group(
            id: "dynamics",
            title: "Dynamics",
            modules: [.multiband, .compressor, .expander],
            folded: [.expander]
        ),
        Group(
            id: "output",
            title: "Output",
            // Oversampling sets the rate the protection stage runs at, so it
            // closes the list.
            modules: [.pauseGate, .gainRider, .softClipper, .limiter, .oversampling],
            folded: [.oversampling]
        ),
    ]
}

// MARK: - E9 S5b output protection

/// E9 S5b: the Protection card's "Outputs" list (`e9.output-protection`). One row per output with its own on/off and ceiling
/// (live: a ceiling edit is a parameter post, not a rebuild) and the live gain reduction and true peak of that output, plus
/// the Advanced "Independent per output" switch. Shows nothing while the flag is off.
struct ProductionOutputProtectionSection: View {
    var engine: AudioIOEngine
    let settings: OutputProtectionSettings
    let apply: (OutputProtectionSettings) -> Void
    /// E9 S5c (G19): per-output ceilings ride on the program limiter's stages, so they do nothing while it is off.
    var programLimiterOn = true

    @State private var readings: [Int: UnifiedGraphOutputProtectionReading] = [:]
    /// E9 S7: the assistant's latest estimate per output, and the settings to restore on Undo.
    @State private var headroom: [Int: OutputHeadroom] = [:]
    @State private var undoSettings: OutputProtectionSettings?

    var body: some View {
        let lanes = engine.outputProtectionLanes
        if lanes.isEmpty {
            EmptyView()
        } else {
            GroupBox("Outputs") {
                VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                    Text("Every output also has an always-on hard limit at \(Int(UnifiedGraphOutputProtection.hardLimitCeilingDB)) dBFS that these settings cannot lower. Turning an output off parks its own ceiling at the hard limit.")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                    DisclosureGroup("Advanced") {
                        Toggle("Independent per output", isOn: Binding(
                            get: { settings.independent },
                            set: { value in var next = settings; next.independent = value; apply(next) }
                        ))
                        Text("Off keeps the program outputs as one linked group so the stereo image is preserved. On gives every program output its own limiter. Switching rebuilds the graph with a short fade.")
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                    }
                    headroomControls
                    if !programLimiterOn {
                        Text("The program Limiter is off, so these ceilings have no effect. The \(Int(UnifiedGraphOutputProtection.hardLimitCeilingDB)) dBFS hard limit still holds every output.")
                            .font(DesignType.caption.font)
                            .foregroundStyle(StatusLevel.attention.color)
                    }
                    ForEach(lanes) { lane in row(lane) }
                }
                .padding(.vertical, DesignSpacing.xs.pt)
            }
            .task { await poll() }
            .task(id: HeadroomKey(settings: settings, running: engine.lifecycleState == .running)) { await refreshHeadroom() }
        }
    }

    private struct HeadroomKey: Equatable {
        let settings: OutputProtectionSettings
        let running: Bool
    }

    private var headroomControls: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            HStack {
                Text("Headroom").font(.subheadline.weight(.medium))
                Spacer()
                Button("Apply") {
                    undoSettings = settings
                    apply(HeadroomAssistant.applying(headroom.values.sorted { $0.lane < $1.lane }, to: settings))
                }
                .disabled(!headroom.values.contains { $0.isComplete && !$0.isSatisfied })
                .accessibilityLabel("Apply headroom trims")
                Button("Undo") {
                    if let previous = undoSettings { apply(previous); undoSettings = nil }
                }
                .disabled(undoSettings == nil)
                .accessibilityLabel("Undo headroom trims")
            }
            Toggle("Strict (assume redirected bass adds coherently)", isOn: Binding(
                get: { settings.headroomStrict },
                set: { value in var next = settings; next.headroomStrict = value; apply(next) }
            ))
            .font(DesignType.caption.font)
            Text("Apply trims each output just enough that a full-scale input stays under its ceiling, using the EQ, room correction, crossover and bass management in the graph. A trim never boosts. Outputs the estimate cannot cover are skipped.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func refreshHeadroom() async {
        guard engine.lifecycleState == .running, let snapshot = engine.headroomSpecSnapshot() else {
            headroom = [:]
            return
        }
        var trims: [Int: Double] = [:]
        for (index, lane) in settings.lanes { trims[index] = lane.trimDB }
        let results = await HeadroomRecompute.run(spec: snapshot.spec, laneCount: snapshot.lanes, strict: settings.headroomStrict, trimsDB: trims)
        guard !Task.isCancelled else { return }
        headroom = Dictionary(uniqueKeysWithValues: results.map { ($0.lane, $0) })
    }

    static func headroomText(_ result: OutputHeadroom) -> String {
        if !result.isComplete { return "headroom: estimate incomplete (\(result.incomplete.joined(separator: ", ")))" }
        var text = String(format: "peak gain %+.1f dB at %.0f Hz", result.peakGainDB, result.peakHz)
        if result.neededDB > 0.05 { text += String(format: "  ·  needs %.1f dB", result.neededDB) }
        if result.currentTrimDB < 0 { text += String(format: "  ·  trim %.1f dB", result.currentTrimDB) }
        if result.limiterPredicted { text += "  ·  limiter will engage" }
        return text
    }

    private func row(_ lane: AudioIOEngine.OutputProtectionLane) -> some View {
        let own = lane.isSub || settings.independent
        let setting = settings.lane(lane.index)
        return VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            HStack {
                Text(lane.label).font(.subheadline.weight(.medium))
                Spacer()
                if own {
                    Toggle("On", isOn: Binding(
                        get: { setting.enabled },
                        set: { value in
                            var next = settings
                            var updated = setting
                            updated.enabled = value
                            next.set(updated, at: lane.index)
                            apply(next)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("\(lane.label) protection")
                } else {
                    Text("Linked").font(DesignType.caption.font).foregroundStyle(.secondary)
                }
            }
            if own {
                OutputCeilingSlider(value: setting.ceilingDB ?? Double(UnifiedGraphOutputProtection.hardLimitCeilingDB), isEnabled: setting.enabled) { value in
                    var next = settings
                    var updated = setting
                    updated.ceilingDB = value
                    next.set(updated, at: lane.index)
                    apply(next)
                }
            }
            if let result = headroom[lane.index] {
                Text(Self.headroomText(result))
                    .font(DesignType.caption.font.monospaced())
                    .foregroundStyle(result.limiterPredicted || !result.isComplete ? StatusLevel.attention.color : Color.secondary)
            }
            if let reading = readings[lane.index] {
                Text(readoutText(reading, own: own))
                    .font(DesignType.caption.font.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func peakDB(_ linear: Float) -> String {
        linear > 0 ? String(format: "%.1f dBTP", Double(20 * log10(linear))) : "-inf dBTP"
    }

    private func readoutText(_ reading: UnifiedGraphOutputProtectionReading, own: Bool) -> String {
        var parts: [String] = []
        if own, let gr = reading.userGainReductionDB { parts.append(String(format: "limiter %.1f dB", Double(gr))) }
        parts.append(String(format: "hard limit %.1f dB", Double(reading.hardLimitGainReductionDB)))
        parts.append("peak " + Self.peakDB(reading.outputTruePeakLinear))
        return parts.joined(separator: "  ·  ")
    }

    /// E28 S6 (E9 G21): reads through the shared meter hub, the only reader of the read-and-reset protection values.
    @MainActor
    private func poll() async {
        let hub = ProductionMeterHub.shared(for: engine)
        let token = hub.subscribe(hertz: 8)
        defer { hub.unsubscribe(token) }
        while !Task.isCancelled {
            let taken = hub.take(token)
            if engine.lifecycleState == .running {
                readings = MultichannelMeterChannels.protectionReadings(
                    from: taken, lanes: engine.outputProtectionLanes.map(\.index))
            } else {
                readings = [:]
            }
            try? await Task.sleep(nanoseconds: 125_000_000)
        }
    }
}

/// E28 S5 (G20): VoiceOver wording and stepping for the output-protection ceiling slider, kept out of the view so
/// a test can pin them.
enum OutputCeilingAccessibility {
    static let label = "Output protection ceiling"
    static let identifier = "output-protection-ceiling"
    static let step = 0.1

    static func value(_ db: Double) -> String { String(format: "%.1f decibels", db) }

    static func adjusted(_ db: Double, up: Bool) -> Double {
        let range = OutputProtectionSettings.ceilingRangeDB
        let next = ((db + (up ? step : -step)) * 10).rounded() / 10
        return min(range.upperBound, max(range.lowerBound, next))
    }
}

/// E9 S5c (G20): the per-output ceiling slider. The label follows the drag at once; the edit reaches the engine once the drag
/// pauses (`OutputProtectionEditDebouncer`) or ends, instead of publishing the whole graph on every tick.
private struct OutputCeilingSlider: View {
    let value: Double
    let isEnabled: Bool
    let commit: (Double) -> Void

    @State private var draft: Double?
    @State private var holder = Holder()

    @MainActor final class Holder {
        var commit: ((Double) -> Void)?
        lazy var debouncer = OutputProtectionEditDebouncer<Double> { [unowned self] in self.commit?($0) }
    }

    var body: some View {
        let _ = holder.commit = { [commit] value in commit(value) }
        HStack {
            Text("Ceiling").font(DesignType.caption.font).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { draft ?? value },
                set: { next in
                    draft = next
                    holder.debouncer.submit(next)
                }
            ), in: OutputProtectionSettings.ceilingRangeDB, step: 0.1) { editing in
                if !editing {
                    holder.debouncer.flush()
                    draft = nil
                }
            }
            .disabled(!isEnabled)
            .onDisappear { holder.debouncer.flush() }
            .accessibilityLabel(OutputCeilingAccessibility.label)
            .accessibilityValue(OutputCeilingAccessibility.value(draft ?? value))
            .accessibilityIdentifier(OutputCeilingAccessibility.identifier)
            .accessibilityAdjustableAction { direction in
                let current = draft ?? value
                let next = OutputCeilingAccessibility.adjusted(current, up: direction == .increment)
                draft = next
                holder.debouncer.submit(next)
                holder.debouncer.flush()
                draft = nil
            }
            Text(DesignFormat.db(Double(draft ?? value)))
                .font(DesignType.caption.font.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
        }
    }
}
