from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


path = Path("NotchSixty/UI/ProductionRootView.swift")
text = path.read_text()
start_marker = "private struct ProductionActiveCrossoverView: View {"
end_marker = "private struct ProductionRoomCorrectionView: View {"
start = text.find(start_marker)
end = text.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit("Unable to locate Active Crossover view bounds")

replacement = r'''private struct ProductionActiveCrossoverView: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var profiles: ProductProfileController
    @State private var actionError: String?

    private var routing: MultiOutputRoutingConfiguration {
        profiles.selectedSystemOutputRouting
    }

    private var physicalRoutingLocked: Bool {
        engine.lifecycleState != .idle
    }

    private var routedDeviceUIDs: [String] {
        var result: [String] = []
        for route in routing.enabledRoutes {
            let uid = route.destination.deviceUID
            if !result.contains(uid) { result.append(uid) }
        }
        return result
    }

    private var supportedRouteBuses: [SpeakerOutputBus] {
        let fullRange: [SpeakerOutputBus] = [.leftFullRange, .rightFullRange]
        guard let mode = engine.bassManagementConfiguration.physicalOutputMode else {
            return fullRange
        }
        return fullRange + SpeakerOutputBus.allCases.filter { !fullRange.contains($0) && mode.supports(bus: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader(
                    "Active Crossover",
                    "Stereo program processing with persistent speaker-bus routing across one or more physical Core Audio devices."
                )

                playbackSystemCard
                crossoverCard
                if engine.bassManagementConfiguration.physicalOutputMode == .mainsSub {
                    subAlignmentCard
                }
                physicalRoutingCard
                verificationCard

                if let error = actionError ?? profiles.lastErrorDescription {
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
            .frame(maxWidth: 1_050, alignment: .topLeading)
        }
        .navigationTitle("Active Crossover")
    }

    private var playbackSystemCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playback System").font(.caption).foregroundStyle(.secondary)
                    Text(profiles.selectedSystemProfileName).font(.headline)
                }
                Spacer()
                if routing.enabled {
                    Label(
                        "\(routing.enabledRoutes.count) routes · \(routing.requiredDeviceUIDs.count) devices",
                        systemImage: routing.usesMultiplePhysicalDevices ? "square.stack.3d.up" : "rectangle.stack"
                    )
                    .font(.caption.bold())
                }
            }
            Text("Crossover and physical-output routing are stored with this Playback System. Content Preset EQ, dynamics, preamp, and headroom remain independent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var crossoverCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Crossover Design").font(.headline)
                    Text("Choose logical stereo bass management or a true physical Mains + Sub / Bi-Amp / Tri-Amp speaker topology.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { engine.bassManagementConfiguration.enabled },
                    set: { value in updateCrossover { $0.enabled = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            LabeledContent("Physical Speaker Mode") {
                Picker("Physical Speaker Mode", selection: Binding(
                    get: { engine.bassManagementConfiguration.physicalOutputMode },
                    set: { value in updateCrossover { configuration in
                        configuration.physicalOutputMode = value
                        if value == .triAmp {
                            if configuration.frequencyHz >= 20_000 { configuration.frequencyHz = 2_000 }
                            if configuration.upperFrequencyHz == nil
                                || configuration.upperFrequencyHz! <= configuration.frequencyHz {
                                configuration.upperFrequencyHz = min(20_000, max(configuration.frequencyHz + 1, 3_000))
                            }
                            if configuration.upperTopology == nil {
                                configuration.upperTopology = configuration.topology
                            }
                        }
                    } }
                )) {
                    Text("Stereo / logical only").tag(SpeakerCrossoverMode?.none)
                    ForEach(SpeakerCrossoverMode.allCases) { mode in
                        Text(mode.displayName).tag(Optional(mode))
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }
            .disabled(physicalRoutingLocked && routing.enabled)

            LabeledContent(engine.bassManagementConfiguration.physicalOutputMode == .triAmp ? "Lower Crossover" : "Crossover Frequency") {
                HStack {
                    Slider(value: Binding(
                        get: { engine.bassManagementConfiguration.frequencyHz },
                        set: { value in updateCrossover { $0.frequencyHz = value } }
                    ), in: lowerFrequencyRange, step: 1)
                    .frame(width: 330)
                    Text("\(engine.bassManagementConfiguration.frequencyHz, specifier: "%.0f") Hz")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
            }
            .disabled(physicalRoutingLocked && routing.enabled)

            LabeledContent(engine.bassManagementConfiguration.physicalOutputMode == .triAmp ? "Lower Topology" : "Topology") {
                Picker("Topology", selection: Binding(
                    get: { engine.bassManagementConfiguration.topology },
                    set: { value in updateCrossover { $0.topology = value } }
                )) {
                    ForEach(CrossoverTopology.allCases) { topology in
                        Text(topology.displayName).tag(topology)
                    }
                }
                .labelsHidden()
                .frame(width: 280)
            }
            .disabled(physicalRoutingLocked && routing.enabled)

            if engine.bassManagementConfiguration.physicalOutputMode == .triAmp {
                LabeledContent("Upper Crossover") {
                    HStack {
                        Slider(value: Binding(
                            get: {
                                engine.bassManagementConfiguration.upperFrequencyHz
                                    ?? max(engine.bassManagementConfiguration.frequencyHz + 1, 3_000)
                            },
                            set: { value in updateCrossover { $0.upperFrequencyHz = value } }
                        ), in: upperFrequencyRange, step: 1)
                        .frame(width: 330)
                        Text("\((engine.bassManagementConfiguration.upperFrequencyHz ?? 3_000), specifier: "%.0f") Hz")
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                }
                .disabled(physicalRoutingLocked && routing.enabled)

                LabeledContent("Upper Topology") {
                    Picker("Upper Topology", selection: Binding(
                        get: { engine.bassManagementConfiguration.upperTopology ?? engine.bassManagementConfiguration.topology },
                        set: { value in updateCrossover { $0.upperTopology = value } }
                    )) {
                        ForEach(CrossoverTopology.allCases) { topology in
                            Text(topology.displayName).tag(topology)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                }
                .disabled(physicalRoutingLocked && routing.enabled)
            }

            if engine.bassManagementConfiguration.physicalOutputMode == .mainsSub
                || engine.bassManagementConfiguration.physicalOutputMode == nil {
                LabeledContent("Sub Gain") {
                    HStack(spacing: 12) {
                        Slider(value: Binding(
                            get: { engine.bassManagementConfiguration.subGainDB },
                            set: { value in updateCrossover { $0.subGainDB = value } }
                        ), in: BassManagementConfiguration.subGainRange, step: 0.5)
                        .frame(width: 260)
                        Text("\(engine.bassManagementConfiguration.subGainDB, specifier: "%.1f") dB")
                            .monospacedDigit()
                            .frame(width: 68, alignment: .trailing)
                    }
                }

                Toggle("Invert Sub Polarity", isOn: Binding(
                    get: { engine.bassManagementConfiguration.subPolarityInverted },
                    set: { value in updateCrossover { $0.subPolarityInverted = value } }
                ))
                .toggleStyle(.switch)
            }

            if physicalRoutingLocked && routing.enabled {
                Label("Stop processing before changing physical crossover topology or route assignments.", systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var subAlignmentCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sub Phase Alignment").font(.headline)
                    Text("All-pass alignment on the physical Sub Mono bus. Use measurement evidence when available rather than tuning blindly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { engine.bassManagementConfiguration.subPhaseAlignmentEnabled },
                    set: { value in updateCrossover { $0.subPhaseAlignmentEnabled = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            LabeledContent("Alignment Frequency") {
                HStack {
                    Slider(value: Binding(
                        get: { engine.bassManagementConfiguration.subPhaseAlignmentFrequencyHz },
                        set: { value in updateCrossover { $0.subPhaseAlignmentFrequencyHz = value } }
                    ), in: BassManagementConfiguration.frequencyRange, step: 1)
                    .frame(width: 260)
                    Text("\(engine.bassManagementConfiguration.subPhaseAlignmentFrequencyHz, specifier: "%.0f") Hz")
                        .monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                }
            }
            .disabled(!engine.bassManagementConfiguration.subPhaseAlignmentEnabled)

            LabeledContent("Alignment Q") {
                HStack {
                    Slider(value: Binding(
                        get: { engine.bassManagementConfiguration.subPhaseAlignmentQ },
                        set: { value in updateCrossover { $0.subPhaseAlignmentQ = value } }
                    ), in: BassManagementConfiguration.subPhaseAlignmentQRange, step: 0.05)
                    .frame(width: 260)
                    Text("\(engine.bassManagementConfiguration.subPhaseAlignmentQ, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                }
            }
            .disabled(!engine.bassManagementConfiguration.subPhaseAlignmentEnabled)
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var physicalRoutingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Physical Output Matrix").font(.headline)
                    Text("Map up to eight logical speaker buses to Core Audio device channels. Multiple devices are synchronized with a private Aggregate Device and HAL drift compensation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { routing.enabled },
                    set: { value in updateRouting { $0.enabled = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(physicalRoutingLocked)
            }

            LabeledContent("Synchronization") {
                Picker("Synchronization", selection: Binding(
                    get: { routing.synchronizationMode },
                    set: { value in updateRouting { $0.synchronizationMode = value } }
                )) {
                    Text(MultiOutputSynchronizationMode.automatic.displayName).tag(MultiOutputSynchronizationMode.automatic)
                    Text(MultiOutputSynchronizationMode.aggregateDevice.displayName).tag(MultiOutputSynchronizationMode.aggregateDevice)
                    Text("Software PLL (superseded)")
                        .tag(MultiOutputSynchronizationMode.softwarePLL)
                        .disabled(true)
                }
                .labelsHidden()
                .frame(width: 240)
            }
            .disabled(physicalRoutingLocked)

            if routedDeviceUIDs.count > 1 {
                LabeledContent("Reference Device") {
                    Picker("Reference Device", selection: Binding(
                        get: { routing.referenceDeviceUID },
                        set: { value in updateRouting { $0.referenceDeviceUID = value } }
                    )) {
                        Text("Automatic").tag(String?.none)
                        ForEach(routedDeviceUIDs, id: \.self) { uid in
                            Text(deviceName(uid)).tag(Optional(uid))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 300)
                }
                .disabled(physicalRoutingLocked)
            }

            Divider()

            if routing.routes.isEmpty {
                ContentUnavailableView(
                    "No Physical Routes",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Add routes to assign speaker buses to physical device channels. Routing stays inactive until at least two routes are enabled.")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                VStack(spacing: 10) {
                    ForEach(routing.routes) { route in
                        routeRow(route)
                    }
                }
            }

            HStack {
                Button {
                    addRoute()
                } label: {
                    Label("Add Route", systemImage: "plus")
                }
                .disabled(physicalRoutingLocked || routing.routes.count >= MultiOutputRoutingConfiguration.maximumRouteCount || engine.outputDevices.isEmpty)

                Spacer()
                Text("\(routing.routes.count)/\(MultiOutputRoutingConfiguration.maximumRouteCount) routes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if routing.synchronizationMode == .softwarePLL {
                Label("Software PLL is retained only for archive compatibility. Select Automatic or Aggregate Device before activation.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func routeRow(_ route: SpeakerOutputRoute) -> some View {
        HStack(spacing: 10) {
            Toggle("Route enabled", isOn: Binding(
                get: { route.enabled },
                set: { value in updateRoute(route.id) { $0.enabled = value } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Picker("Bus", selection: Binding(
                get: { route.bus },
                set: { value in updateRoute(route.id) { $0.bus = value; $0.name = value.displayName } }
            )) {
                ForEach(supportedRouteBuses) { bus in
                    Text(bus.displayName).tag(bus)
                }
            }
            .labelsHidden()
            .frame(width: 180)

            Picker("Device", selection: Binding(
                get: { route.destination.deviceUID },
                set: { uid in
                    updateRoute(route.id) { updated in
                        updated.destination.deviceUID = uid
                        updated.destination.channelIndex = firstAvailableChannel(on: uid, excluding: route.id)
                    }
                }
            )) {
                ForEach(engine.outputDevices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()
            .frame(minWidth: 230)

            Picker("Channel", selection: Binding(
                get: { route.destination.channelIndex },
                set: { value in updateRoute(route.id) { $0.destination.channelIndex = value } }
            )) {
                ForEach(0..<Int(max(1, channelCount(for: route.destination.deviceUID))), id: \.self) { channel in
                    Text("Ch \(channel + 1)").tag(UInt32(channel))
                }
            }
            .labelsHidden()
            .frame(width: 80)

            Button(role: .destructive) {
                removeRoute(route.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .disabled(physicalRoutingLocked)
        .padding(10)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var verificationCard: some View {
        DisclosureGroup("Verification Monitor") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Monitor Path", selection: Binding(
                    get: { engine.bassManagementConfiguration.monitorMode },
                    set: { value in updateCrossover { $0.monitorMode = value } }
                )) {
                    ForEach(CrossoverMonitorMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("The verification monitor affects the ordinary logical stereo crossover preview. Physical split routes are generated independently after the shared stereo DSP chain and are protected by their mandatory crossover even when raw Global Bypass is used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var lowerFrequencyRange: ClosedRange<Double> {
        if engine.bassManagementConfiguration.physicalOutputMode == .triAmp {
            return 20...19_999
        }
        return engine.bassManagementConfiguration.lowerFrequencyRange
    }

    private var upperFrequencyRange: ClosedRange<Double> {
        let lower = min(19_999, max(20, engine.bassManagementConfiguration.frequencyHz + 1))
        return lower...20_000
    }

    private func deviceName(_ uid: String) -> String {
        engine.outputDevices.first(where: { $0.uid == uid })?.name ?? uid
    }

    private func channelCount(for uid: String) -> UInt32 {
        engine.outputDevices.first(where: { $0.uid == uid })?.outputChannelCount ?? 1
    }

    private func firstAvailableChannel(on uid: String, excluding routeID: UUID?) -> UInt32 {
        let used = Set(routing.routes.compactMap { route -> UInt32? in
            guard route.id != routeID, route.destination.deviceUID == uid else { return nil }
            return route.destination.channelIndex
        })
        let count = channelCount(for: uid)
        for channel in 0..<count where !used.contains(channel) {
            return channel
        }
        return 0
    }

    private func addRoute() {
        actionError = nil
        guard routing.routes.count < MultiOutputRoutingConfiguration.maximumRouteCount else { return }
        let used = Set(routing.routes.map(\.destination))
        var endpoint: PhysicalOutputEndpoint?
        outer: for device in engine.outputDevices {
            for channel in 0..<device.outputChannelCount {
                let candidate = PhysicalOutputEndpoint(deviceUID: device.uid, channelIndex: channel)
                if !used.contains(candidate) {
                    endpoint = candidate
                    break outer
                }
            }
        }
        guard let endpoint else {
            actionError = "No unused physical output channel is currently available."
            return
        }
        let usedBuses = Set(routing.routes.map(\.bus))
        let bus = supportedRouteBuses.first(where: { !usedBuses.contains($0) }) ?? supportedRouteBuses.first ?? .leftFullRange
        updateRouting { configuration in
            configuration.routes.append(
                SpeakerOutputRoute(name: bus.displayName, bus: bus, destination: endpoint)
            )
        }
    }

    private func removeRoute(_ id: UUID) {
        updateRouting { configuration in
            configuration.routes.removeAll { $0.id == id }
            if let reference = configuration.referenceDeviceUID,
               !configuration.enabledRoutes.contains(where: { $0.destination.deviceUID == reference }) {
                configuration.referenceDeviceUID = nil
            }
        }
    }

    private func updateRoute(_ id: UUID, _ mutation: (inout SpeakerOutputRoute) -> Void) {
        updateRouting { configuration in
            guard let index = configuration.routes.firstIndex(where: { $0.id == id }) else { return }
            mutation(&configuration.routes[index])
        }
    }

    private func updateRouting(_ mutation: (inout MultiOutputRoutingConfiguration) -> Void) {
        actionError = nil
        var updated = routing
        mutation(&updated)
        do {
            try profiles.replaceSelectedSystemOutputRouting(updated)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func updateCrossover(_ mutation: (inout BassManagementConfiguration) -> Void) {
        actionError = nil
        var updated = engine.bassManagementConfiguration
        mutation(&updated)
        do {
            try profiles.replaceSelectedSystemBassManagement(updated)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

'''
text = text[:start] + replacement + text[end:]
path.write_text(text)
print("PR41 Slice E production routing UI patch applied")
