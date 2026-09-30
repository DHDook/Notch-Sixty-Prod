from pathlib import Path

stereo_path = Path("NotchSixtyTests/StereoPlaybackControlTests.swift")
stereo = stereo_path.read_text()

stereo_anchor = '''    func testStereoGraphCompilesUpToSixtyFourBandsPerChannelAt384k() throws {
'''

stereo_insert = r'''    func testRoomCorrectionAuditionModesMatchLatencyAlignedContract() {
        let cases = [
            (N60AuditionModeProcessed, Float(0.5)),
            (N60AuditionModeReference, Float(1.0)),
            (N60AuditionModeDelta, Float(-0.5)),
        ]

        for (mode, expectedScale) in cases {
            guard let kernel = N60RenderKernelCreate() else {
                return XCTFail("Unable to create render kernel")
            }
            defer { N60RenderKernelDestroy(kernel) }

            let taps: [Float] = [0.5]
            var program = N60ConvolutionProgramInfo()
            XCTAssertTrue(taps.withUnsafeBufferPointer { buffer in
                N60RenderKernelPrepareRoomCorrectionProgram(
                    kernel,
                    1,
                    buffer.baseAddress!,
                    nil,
                    UInt32(buffer.count),
                    0,
                    &program
                )
            })

            var graph = N60DSPGraphSnapshotMakeUnity(96_000)
            XCTAssertTrue(
                N60DSPGraphSnapshotSetRoomCorrectionProgram(
                    &graph,
                    1,
                    program,
                    true
                )
            )
            graph.auditionMode = mode
            XCTAssertEqual(
                graph.latencyFrames,
                program.engineLatencyFrames + program.declaredLatencyFrames
            )
            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

            let latency = Int(graph.latencyFrames)
            var maximumError: Float = 0
            for frame in 0..<(latency + 4_096) {
                let leftInput = Float(sin(Double(frame) * 0.017) * 0.4)
                let rightInput = Float(cos(Double(frame) * 0.013) * 0.3)
                var left: Float = 0
                var right: Float = 0
                N60RenderKernelProcessStereoFrame(
                    kernel,
                    leftInput,
                    rightInput,
                    &left,
                    &right
                )

                if frame > latency + 32 {
                    let delayedFrame = frame - latency
                    let expectedLeft = Float(sin(Double(delayedFrame) * 0.017) * 0.4) * expectedScale
                    let expectedRight = Float(cos(Double(delayedFrame) * 0.013) * 0.3) * expectedScale
                    maximumError = max(
                        maximumError,
                        max(abs(left - expectedLeft), abs(right - expectedRight))
                    )
                }
            }
            XCTAssertLessThan(maximumError, 0.000_2)
        }
    }

    func testRawGlobalBypassOverridesAttachedRoomCorrectionAndDeltaAudition() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        let taps: [Float] = [0.5]
        var program = N60ConvolutionProgramInfo()
        XCTAssertTrue(taps.withUnsafeBufferPointer { buffer in
            N60RenderKernelPrepareRoomCorrectionProgram(
                kernel,
                1,
                buffer.baseAddress!,
                nil,
                UInt32(buffer.count),
                0,
                &program
            )
        })

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(
            N60DSPGraphSnapshotSetRoomCorrectionProgram(
                &graph,
                1,
                program,
                true
            )
        )
        graph.auditionMode = N60AuditionModeDelta
        graph.bypassed = true
        graph.masterGainLinear = 0.5
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertTrue(diagnostics.bypassed)
        XCTAssertTrue(diagnostics.roomCorrectionEnabled)

        for frame in 0..<2_000 {
            let leftInput = Float(sin(Double(frame) * 0.019) * 0.6)
            let rightInput = Float(cos(Double(frame) * 0.023) * 0.4)
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(
                kernel,
                leftInput,
                rightInput,
                &left,
                &right
            )
            XCTAssertEqual(left, leftInput * 0.5, accuracy: 0.000_001)
            XCTAssertEqual(right, rightInput * 0.5, accuracy: 0.000_001)
        }
    }

    func testRoomCorrectionPreparationPolicyParksAndRestoresOnlyForRawBypass() {
        let room = RoomCorrectionConfiguration(enabled: true, filter: .validation)
        let sequence: [(PlaybackControlConfiguration, Bool)] = [
            (PlaybackControlConfiguration(auditionMode: .processed), true),
            (PlaybackControlConfiguration(auditionMode: .reference), true),
            (PlaybackControlConfiguration(auditionMode: .delta), true),
            (PlaybackControlConfiguration(globalBypassed: true, auditionMode: .delta), false),
            (PlaybackControlConfiguration(globalBypassed: true, auditionMode: .reference), false),
            (PlaybackControlConfiguration(auditionMode: .processed), true),
        ]

        for (playback, shouldPrepare) in sequence {
            XCTAssertEqual(
                FIRUpdatePolicy.shouldPrepareRoomCorrection(
                    roomCorrection: room,
                    playback: playback
                ),
                shouldPrepare
            )
        }
    }

'''

if stereo_anchor not in stereo:
    raise SystemExit("stereo regression anchor not found")
stereo = stereo.replace(stereo_anchor, stereo_insert + stereo_anchor, 1)
stereo_path.write_text(stereo)

project_path = Path("NotchSixtyTests/RoomCorrectionProjectControllerTests.swift")
project = project_path.read_text()

project_anchor = '''    func testProfileDeploymentPersistenceFailureRollsBackEngineAndProfile() throws {
'''
project_insert = r'''    func testPersistentRoomCorrectionEnableTogglePreservesDeploymentAndContentPreset() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profiles = fixture.profiles
        let beforeContent = profiles.captureContentState()
        let filter = RoomCorrectionFilter(
            name: "Persistent Toggle Fixture",
            sampleRate: nil,
            leftTaps: [0.5, 0.5],
            rightTaps: [0.4, 0.6],
            declaredLatencyFrames: 0
        )
        let summary = RoomCorrectionCalibrationSummary(
            projectID: UUID(),
            activeDesignID: UUID(),
            designDate: Date(timeIntervalSince1970: 300),
            positionCount: 3,
            correctionLowHz: 80,
            correctionHighHz: 12_000,
            targetName: "Gentle Tilt",
            smoothingOctaves: 1.0 / 6.0,
            maximumBoostDB: 4,
            maximumCutDB: 8,
            recommendedHeadroomDB: 2.5,
            algorithmVersion: "fixture"
        )
        let deployed = RoomCorrectionConfiguration(enabled: true, filter: filter)
        try profiles.replaceSelectedSystemRoomCorrection(
            deployed,
            calibrationSummary: summary
        )

        try profiles.setSelectedSystemRoomCorrectionEnabled(false)
        XCTAssertFalse(profiles.engine.roomCorrectionConfiguration.enabled)
        XCTAssertEqual(profiles.engine.roomCorrectionConfiguration.filter, filter)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrection.filter, filter)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        try profiles.setSelectedSystemRoomCorrectionEnabled(true)
        XCTAssertTrue(profiles.engine.roomCorrectionConfiguration.enabled)
        XCTAssertEqual(profiles.engine.roomCorrectionConfiguration.filter, filter)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrection, deployed)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        let restoredEngine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let restoredProfiles = ProductProfileController(
            engine: restoredEngine,
            storageURL: fixture.root.appendingPathComponent("profiles-v1.json")
        )
        restoredProfiles.restoreSelectedLayers()
        XCTAssertEqual(restoredEngine.roomCorrectionConfiguration, deployed)
        XCTAssertEqual(restoredProfiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
    }

'''

if project_anchor not in project:
    raise SystemExit("profile regression anchor not found")
project = project.replace(project_anchor, project_insert + project_anchor, 1)
project_path.write_text(project)
