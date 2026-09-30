from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


# 1. ProductProfileController: narrow transactional Playback System crossover ownership.
profiles_path = Path("NotchSixty/State/ProductProfiles.swift")
profiles = profiles_path.read_text()
anchor = '''    func replaceSelectedSystemRoomCorrection(
        _ configuration: RoomCorrectionConfiguration,
        calibrationSummary summary: RoomCorrectionCalibrationSummary?
    ) throws {
'''
insert = '''    func replaceSelectedSystemBassManagement(
        _ configuration: BassManagementConfiguration
    ) throws {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else {
            throw ProductProfileError.selectedSystemProfileRequired
        }

        let previousEngineConfiguration = engine.bassManagementConfiguration
        let previousState = systemProfiles[index].state
        do {
            try engine.replaceBassManagementConfiguration(configuration)
            systemProfiles[index].state.bassManagement = configuration
            try persistThrowing()
            lastErrorDescription = nil
        } catch {
            systemProfiles[index].state = previousState
            try? engine.replaceBassManagementConfiguration(previousEngineConfiguration)
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func setSelectedSystemBassManagementEnabled(_ enabled: Bool) throws {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else {
            throw ProductProfileError.selectedSystemProfileRequired
        }
        var configuration = systemProfiles[index].state.bassManagement
        configuration.enabled = enabled
        try replaceSelectedSystemBassManagement(configuration)
    }

''' + anchor
profiles = replace_once(profiles, anchor, insert, "ProductProfileController bass-management insertion")
profiles_path.write_text(profiles)


# 2. Production UI: route all crossover edits through the selected Playback System
# and expose the already-supported sub gain/phase/verification controls.
root_path = Path("NotchSixty/UI/ProductionRootView.swift")
root = root_path.read_text()
root = replace_once(
    root,
    '''        case .activeCrossover:\n            ProductionActiveCrossoverView(engine: engine)\n''',
    '''        case .activeCrossover:\n            ProductionActiveCrossoverView(engine: engine, profiles: product.profiles)\n''',
    "ProductionRootView crossover injection",
)
start_marker = "private struct ProductionActiveCrossoverView: View {"
end_marker = "private struct ProductionRoomCorrectionView: View {"
start = root.find(start_marker)
end = root.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit("Could not locate ProductionActiveCrossoverView replacement bounds")
new_view = '''private struct ProductionActiveCrossoverView: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var profiles: ProductProfileController
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader(
                    "Active Crossover",
                    "Speaker/sub integration belongs to the selected Playback System and remains independent from Content Presets."
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text("Playback System").font(.caption).foregroundStyle(.secondary)
                    Text(profiles.selectedSystemProfileName).font(.headline)
                    Text("These controls are persisted with this physical playback system. Content Preset EQ, dynamics, preamp, and headroom are not modified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 18) {
                    Toggle("Enable Active Crossover", isOn: Binding(
                        get: { engine.bassManagementConfiguration.enabled },
                        set: { value in updateCrossover { $0.enabled = value } }
                    ))
                    .toggleStyle(.switch)

                    LabeledContent("Crossover Frequency") {
                        HStack {
                            Slider(value: Binding(
                                get: { engine.bassManagementConfiguration.frequencyHz },
                                set: { value in updateCrossover { $0.frequencyHz = value } }
                            ), in: BassManagementConfiguration.frequencyRange, step: 1)
                            .frame(width: 300)
                            Text("\\(engine.bassManagementConfiguration.frequencyHz, specifier: \"%.0f\") Hz")
                                .monospacedDigit()
                                .frame(width: 62, alignment: .trailing)
                        }
                    }

                    LabeledContent("Topology") {
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

                    LabeledContent("Sub Gain") {
                        HStack(spacing: 12) {
                            Slider(value: Binding(
                                get: { engine.bassManagementConfiguration.subGainDB },
                                set: { value in updateCrossover { $0.subGainDB = value } }
                            ), in: BassManagementConfiguration.subGainRange, step: 0.5)
                            .frame(width: 260)
                            Text("\\(engine.bassManagementConfiguration.subGainDB, specifier: \"%.1f\") dB")
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
                .padding(20)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Sub Phase Alignment").font(.headline)
                            Text("A bounded all-pass alignment network on the logical sub path. Use measurement evidence when available rather than tuning blindly.")
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
                            Text("\\(engine.bassManagementConfiguration.subPhaseAlignmentFrequencyHz, specifier: \"%.0f\") Hz")
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
                            Text("\\(engine.bassManagementConfiguration.subPhaseAlignmentQ, specifier: \"%.2f\")")
                                .monospacedDigit()
                                .frame(width: 62, alignment: .trailing)
                        }
                    }
                    .disabled(!engine.bassManagementConfiguration.subPhaseAlignmentEnabled)
                }
                .padding(20)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))

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

                        Text("This is a logical validation monitor inside the stereo render path. It does not create or route a separate physical subwoofer output.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                }
                .padding(20)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))

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
            .frame(maxWidth: 900, alignment: .topLeading)
        }
        .navigationTitle("Active Crossover")
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
root = root[:start] + new_view + root[end:]
root_path.write_text(root)


# 3. Profile ownership / persistence / rollback tests.
project_tests_path = Path("NotchSixtyTests/RoomCorrectionProjectControllerTests.swift")
project_tests = project_tests_path.read_text()
if not project_tests.endswith("\n}\n"):
    raise SystemExit("Unexpected RoomCorrectionProjectControllerTests.swift ending")
profile_tests = r'''
    func testProfileBassManagementChangesOnlyPlaybackSystemAndRestoresWithRoomCorrectionIntact() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profiles = fixture.profiles
        let beforeContent = profiles.captureContentState()

        let roomFilter = RoomCorrectionFilter(
            name: "PR41 Room Fixture",
            sampleRate: nil,
            leftTaps: [0.5, 0.5],
            rightTaps: [0.4, 0.6],
            declaredLatencyFrames: 0
        )
        let room = RoomCorrectionConfiguration(enabled: true, filter: roomFilter)
        let summary = RoomCorrectionCalibrationSummary(
            projectID: UUID(),
            activeDesignID: UUID(),
            designDate: Date(timeIntervalSince1970: 410),
            positionCount: 3,
            correctionLowHz: 80,
            correctionHighHz: 12_000,
            targetName: "PR41 Fixture Target",
            smoothingOctaves: 1.0 / 6.0,
            maximumBoostDB: 4,
            maximumCutDB: 8,
            recommendedHeadroomDB: 2,
            algorithmVersion: "pr41-fixture"
        )
        try profiles.replaceSelectedSystemRoomCorrection(room, calibrationSummary: summary)

        var crossover = BassManagementConfiguration()
        crossover.enabled = true
        crossover.frequencyHz = 92
        crossover.topology = .linkwitzRiley48
        crossover.monitorMode = .mainsOnly
        crossover.subGainDB = 2.5
        crossover.subPolarityInverted = true
        crossover.subPhaseAlignmentEnabled = true
        crossover.subPhaseAlignmentFrequencyHz = 88
        crossover.subPhaseAlignmentQ = 0.9

        try profiles.replaceSelectedSystemBassManagement(crossover)
        XCTAssertEqual(profiles.engine.bassManagementConfiguration, crossover)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.bassManagement, crossover)
        XCTAssertEqual(profiles.engine.roomCorrectionConfiguration, room)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrection, room)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        try profiles.setSelectedSystemBassManagementEnabled(false)
        XCTAssertFalse(profiles.engine.bassManagementConfiguration.enabled)
        XCTAssertEqual(profiles.engine.bassManagementConfiguration.frequencyHz, 92, accuracy: 0.000_001)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        try profiles.setSelectedSystemBassManagementEnabled(true)
        XCTAssertEqual(profiles.engine.bassManagementConfiguration, crossover)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        let restoredEngine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let restoredProfiles = ProductProfileController(
            engine: restoredEngine,
            storageURL: fixture.root.appendingPathComponent("profiles-v1.json")
        )
        restoredProfiles.restoreSelectedLayers()
        XCTAssertEqual(restoredEngine.bassManagementConfiguration, crossover)
        XCTAssertEqual(restoredProfiles.selectedSystemProfile?.state.bassManagement, crossover)
        XCTAssertEqual(restoredEngine.roomCorrectionConfiguration, room)
        XCTAssertEqual(restoredProfiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
    }

    func testProfileBassManagementPersistenceFailureRollsBackEngineAndProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-PR41-Crossover-Rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storageDirectory = root.appendingPathComponent("profiles", isDirectory: true)
        let storageURL = storageDirectory.appendingPathComponent("profiles-v1.json")
        let engine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let profiles = ProductProfileController(engine: engine, storageURL: storageURL)
        let beforeEngine = engine.bassManagementConfiguration
        let beforeProfile = try XCTUnwrap(profiles.selectedSystemProfile).state

        try FileManager.default.removeItem(at: storageDirectory)
        try Data("not-a-directory".utf8).write(to: storageDirectory)

        var crossover = BassManagementConfiguration()
        crossover.enabled = true
        crossover.frequencyHz = 110
        crossover.subGainDB = 1.5

        XCTAssertThrowsError(try profiles.replaceSelectedSystemBassManagement(crossover))
        XCTAssertEqual(engine.bassManagementConfiguration, beforeEngine)
        XCTAssertEqual(profiles.selectedSystemProfile?.state, beforeProfile)
    }
'''
project_tests = project_tests[:-3] + "\n" + profile_tests + "}\n"
project_tests_path.write_text(project_tests)


# 4. Realtime structural contract: crossover stays zero-latency and preserves the
# room-correction program identity/latency; raw global bypass still wins.
stereo_tests_path = Path("NotchSixtyTests/StereoPlaybackControlTests.swift")
stereo_tests = stereo_tests_path.read_text()
insert_before = '''    func testStereoGraphCompilesUpToSixtyFourBandsPerChannelAt384k() throws {
'''
realtime_test = r'''    func testCrossoverPreservesRoomCorrectionProgramIdentityLatencyAndRawBypass() throws {
        for sampleRate in [44_100.0, 48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            guard let kernel = N60RenderKernelCreate() else {
                return XCTFail("Unable to create render kernel")
            }
            defer { N60RenderKernelDestroy(kernel) }

            let taps: [Float] = [1]
            var roomProgram = N60ConvolutionProgramInfo()
            XCTAssertTrue(taps.withUnsafeBufferPointer { buffer in
                N60RenderKernelPrepareRoomCorrectionProgram(
                    kernel,
                    1,
                    buffer.baseAddress!,
                    nil,
                    UInt32(buffer.count),
                    0,
                    &roomProgram
                )
            })

            var crossover = BassManagementConfiguration()
            crossover.enabled = true
            crossover.frequencyHz = 80
            crossover.topology = .linkwitzRiley24
            crossover.subGainDB = 1.5
            crossover.subPhaseAlignmentEnabled = true
            crossover.subPhaseAlignmentFrequencyHz = 80
            crossover.subPhaseAlignmentQ = 0.8

            var graph = try StereoEQConfiguration().makeGraphSnapshot(
                sampleRate: sampleRate,
                gainConfiguration: DSPGainConfiguration(),
                bassManagementConfiguration: crossover,
                playbackConfiguration: PlaybackControlConfiguration(auditionMode: .processed)
            )
            XCTAssertEqual(graph.latencyFrames, 0)
            XCTAssertTrue(N60DSPGraphSnapshotSetRoomCorrectionProgram(&graph, 1, roomProgram, true))
            let roomLatency = roomProgram.engineLatencyFrames + roomProgram.declaredLatencyFrames
            XCTAssertEqual(graph.latencyFrames, roomLatency)
            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

            var diagnostics = N60RenderKernelGetDiagnostics(kernel)
            XCTAssertTrue(diagnostics.crossoverEnabled)
            XCTAssertEqual(diagnostics.crossoverFrequencyHz, 80, accuracy: 0.000_001)
            XCTAssertTrue(diagnostics.roomCorrectionEnabled)
            XCTAssertEqual(diagnostics.roomCorrectionProgramGeneration, roomProgram.generation)
            XCTAssertEqual(diagnostics.latencyFrames, roomLatency)

            crossover.frequencyHz = 120
            crossover.topology = .linkwitzRiley48
            crossover.monitorMode = .subOnly
            var changed = try StereoEQConfiguration().makeGraphSnapshot(
                sampleRate: sampleRate,
                gainConfiguration: DSPGainConfiguration(),
                bassManagementConfiguration: crossover,
                playbackConfiguration: PlaybackControlConfiguration(auditionMode: .reference)
            )
            XCTAssertEqual(changed.latencyFrames, 0)
            XCTAssertTrue(N60DSPGraphSnapshotSetRoomCorrectionProgram(&changed, 1, roomProgram, true))
            XCTAssertEqual(changed.latencyFrames, roomLatency)
            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, changed))

            diagnostics = N60RenderKernelGetDiagnostics(kernel)
            XCTAssertEqual(diagnostics.crossoverFrequencyHz, 120, accuracy: 0.000_001)
            XCTAssertEqual(diagnostics.crossoverTopology, N60CrossoverTopologyLinkwitzRiley48)
            XCTAssertEqual(diagnostics.crossoverMonitorMode, N60CrossoverMonitorModeSubOnly)
            XCTAssertEqual(diagnostics.roomCorrectionProgramGeneration, roomProgram.generation)
            XCTAssertEqual(diagnostics.latencyFrames, roomLatency)

            changed.bypassed = true
            changed.auditionMode = N60AuditionModeDelta
            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, changed))
            for frame in 0..<1_024 {
                let leftInput = Float(sin(Double(frame) * 0.019) * 0.55)
                let rightInput = Float(cos(Double(frame) * 0.023) * 0.45)
                var left: Float = 0
                var right: Float = 0
                N60RenderKernelProcessStereoFrame(kernel, leftInput, rightInput, &left, &right)
                XCTAssertEqual(left, leftInput, accuracy: 0.000_001)
                XCTAssertEqual(right, rightInput, accuracy: 0.000_001)
            }
        }
    }

'''
stereo_tests = replace_once(stereo_tests, insert_before, realtime_test + insert_before, "Stereo crossover/room regression insertion")
stereo_tests_path.write_text(stereo_tests)

print("PR41 Slice A/B source patch applied")
