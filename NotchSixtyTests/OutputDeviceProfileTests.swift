import XCTest
@testable import NotchSixty

/// Output Device Profile semantics: structural validation, live route plans,
/// realtime output maps, physical-system nomenclature and archive compatibility.
final class OutputDeviceProfileTests: XCTestCase {
    private let avr = AudioOutputDevice(
        deviceID: 1,
        uid: "avr",
        name: "AVR",
        nominalSampleRate: 96_000,
        availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 192_000)],
        outputChannelCount: 16
    )

    private func endpoint(_ channel: UInt32, device: String = "avr") -> PhysicalOutputEndpoint {
        PhysicalOutputEndpoint(deviceUID: device, channelIndex: channel)
    }

    private func sevenOneFourProfile(calibrated: Bool = false) -> OutputDeviceProfileConfiguration {
        let speakers = OutputProgramLayout.sevenOneFour.roles
            .filter { $0 != .lowFrequencyEffects }
            .enumerated()
            .map { offset, role in
                SemanticSpeakerOutputAssignment(
                    role: role,
                    destination: endpoint(UInt32(offset)),
                    calibration: calibrated ? SemanticSpeakerCalibration(
                        trimDB: offset == 0 ? -2.5 : 0,
                        delayMilliseconds: offset == 0 ? 1.25 : 0,
                        polarityInverted: false,
                        eqBands: offset == 0
                            ? [OutputCalibrationEQBand(frequencyHz: 1_000, gainDB: -2, q: 1)]
                            : []
                    ) : nil
                )
            }
        let subs = [
            PhysicalSubwooferOutputAssignment(
                index: 0, destination: endpoint(11),
                calibration: calibrated ? PhysicalSubwooferCalibration(
                    gainDB: -1.5, delayMilliseconds: 2.0, polarityInverted: false,
                    eqBands: [OutputCalibrationEQBand(frequencyHz: 55, gainDB: -3, q: 1.2)]
                ) : nil
            ),
            PhysicalSubwooferOutputAssignment(
                index: 1, destination: endpoint(12),
                calibration: calibrated
                    ? PhysicalSubwooferCalibration(gainDB: -3.0, delayMilliseconds: 4.0)
                    : nil
            ),
        ]
        return OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .sevenOneFour,
            speakerAssignments: speakers,
            subwooferAssignments: subs,
            synchronizationMode: .automatic,
            referenceDeviceUID: "avr"
        )
    }

    private func assertProfileError(
        _ expected: OutputDeviceProfileError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? OutputDeviceProfileError, expected, file: file, line: line)
        }
    }

    func testBassManagedSevenOneFourPlanLeavesNativeLFEUnmappedAndRoutesSubs() throws {
        let profile = sevenOneFourProfile()
        try profile.validateStructure(bassManagementEnabled: true)
        let plan = try profile.makeLivePlan(
            availableDevices: [avr], sampleRate: 96_000,
            selectedOutputUID: "avr", bassManagementEnabled: true
        )
        XCTAssertEqual(plan.programLayout, .sevenOneFour)
        XCTAssertEqual(plan.physicalChannelCount, 16)
        XCTAssertEqual(plan.subwooferCount, 2)
        XCTAssertFalse(plan.usesMultiplePhysicalDevices)

        var map = try plan.makeRealtimeOutputMap()
        XCTAssertTrue(map.valid)
        XCTAssertTrue(map.bassManagementEnabled)
        XCTAssertEqual(map.subwooferCount, 2)
        XCTAssertEqual(map.physicalChannelCount, 16)
        let program = withUnsafePointer(to: &map.physicalChannelForProgram) {
            $0.withMemoryRebound(to: UInt32.self, capacity: Int(N60_MAX_PROGRAM_CHANNELS)) {
                Array(UnsafeBufferPointer(start: $0, count: 12))
            }
        }
        XCTAssertEqual(program[3], UInt32.max, "native LFE stays unmapped under bass management")
        let subs = withUnsafePointer(to: &map.physicalChannelForSubwoofer) {
            $0.withMemoryRebound(to: UInt32.self, capacity: Int(N60_MAX_SUBWOOFER_OUTPUTS)) {
                Array(UnsafeBufferPointer(start: $0, count: 2))
            }
        }
        XCTAssertEqual(subs, [11, 12])
    }

    func testStructuralRulesFailClosed() throws {
        var disabled = sevenOneFourProfile()
        disabled.enabled = false
        assertProfileError(.profileDisabled) {
            _ = try disabled.makeLivePlan(
                availableDevices: [avr], sampleRate: 96_000,
                selectedOutputUID: "avr", bassManagementEnabled: true
            )
        }

        var directLFE = sevenOneFourProfile()
        directLFE.speakerAssignments.append(
            SemanticSpeakerOutputAssignment(role: .lowFrequencyEffects, destination: endpoint(13))
        )
        assertProfileError(.lfeMustBeUnmappedWhenBassManaged) {
            try directLFE.validateStructure(bassManagementEnabled: true)
        }

        let fiveOne = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .fiveOne,
            speakerAssignments: OutputProgramLayout.fiveOne.roles.enumerated().map {
                SemanticSpeakerOutputAssignment(role: $0.element, destination: endpoint(UInt32($0.offset)))
            }
        )
        try fiveOne.validateStructure(bassManagementEnabled: false)
        var missingLFE = fiveOne
        missingLFE.speakerAssignments.removeAll { $0.role == .lowFrequencyEffects }
        assertProfileError(.lfePhysicalOutputRequired) {
            try missingLFE.validateStructure(bassManagementEnabled: false)
        }
        var subsWithoutBass = fiveOne
        subsWithoutBass.subwooferAssignments = [
            PhysicalSubwooferOutputAssignment(index: 0, destination: endpoint(6))
        ]
        assertProfileError(.physicalSubwoofersRequireBassManagement) {
            try subsWithoutBass.validateStructure(bassManagementEnabled: false)
        }

        var sparseSubs = sevenOneFourProfile()
        sparseSubs.subwooferAssignments[1].index = 2
        assertProfileError(.invalidPhysicalSubwooferIndex(2)) {
            try sparseSubs.validateStructure(bassManagementEnabled: true)
        }
    }

    func testDeviceCapabilitiesAreCheckedBeforeAPlanGoesLive() {
        let profile = sevenOneFourProfile()
        assertProfileError(.sampleRateUnsupported(deviceUID: "avr", sampleRate: 384_000)) {
            _ = try profile.makeLivePlan(
                availableDevices: [avr], sampleRate: 384_000,
                selectedOutputUID: "avr", bassManagementEnabled: true
            )
        }
        var badChannel = profile
        badChannel.subwooferAssignments[1].destination.channelIndex = 16
        assertProfileError(.outputChannelUnavailable(deviceUID: "avr", channelIndex: 16, channelCount: 16)) {
            _ = try badChannel.makeLivePlan(
                availableDevices: [avr], sampleRate: 96_000,
                selectedOutputUID: "avr", bassManagementEnabled: true
            )
        }
    }

    func testMultipleDevicesFlattenInReferenceDeviceOrder() throws {
        func box(_ uid: String, _ id: AudioDeviceID) -> AudioOutputDevice {
            AudioOutputDevice(
                deviceID: id, uid: uid, name: uid, nominalSampleRate: 48_000,
                availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 192_000)],
                outputChannelCount: 2
            )
        }
        let profile = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(role: .frontLeft, destination: endpoint(0, device: "left-box")),
                SemanticSpeakerOutputAssignment(role: .frontRight, destination: endpoint(1, device: "right-box")),
            ],
            referenceDeviceUID: "left-box"
        )
        let plan = try profile.makeLivePlan(
            availableDevices: [box("left-box", 1), box("right-box", 2)], sampleRate: 48_000,
            selectedOutputUID: "left-box", bassManagementEnabled: false
        )
        XCTAssertEqual(plan.orderedDeviceUIDs, ["left-box", "right-box"])
        XCTAssertEqual(plan.physicalChannelCount, 4)
        XCTAssertTrue(plan.usesMultiplePhysicalDevices)
        XCTAssertEqual(Array(plan.programPhysicalChannels.prefix(2)), [0, 3])
        XCTAssertTrue(try plan.makeRealtimeOutputMap().valid)
    }

    func testEveryProgramLayoutHasAConsistentRealtimeLayout() {
        for layout in OutputProgramLayout.allCases {
            var realtime = layout.realtimeLayout
            XCTAssertTrue(N60ProgramChannelLayoutIsValid(&realtime), layout.displayName)
            XCTAssertEqual(Int(realtime.channelCount), layout.roles.count, layout.displayName)
            XCTAssertLessThanOrEqual(layout.roles.count, Int(N60_MAX_PROGRAM_CHANNELS), layout.displayName)
            let lfe = layout.roles.contains(.lowFrequencyEffects) ? 1 : 0
            XCTAssertEqual(
                layout.bedChannelCount + lfe + layout.heightChannelCount,
                layout.roles.count,
                layout.displayName
            )
        }
        XCTAssertEqual(OutputProgramLayout.threeOne.realtimeLayout.identifier, N60ProgramLayoutCustom)
    }

    func testPhysicalSystemNameCountsAssignedSubwoofers() {
        func label(_ layout: OutputProgramLayout, _ subCount: Int) -> String {
            OutputDeviceProfileConfiguration(
                programLayout: layout,
                subwooferAssignments: (0..<subCount).map {
                    PhysicalSubwooferOutputAssignment(index: UInt32($0), destination: endpoint(UInt32($0)))
                }
            ).systemDisplayName
        }
        XCTAssertEqual(label(.stereo, 0), "2.0")
        XCTAssertEqual(label(.stereo, 1), "2.1")
        XCTAssertEqual(label(.stereo, 2), "2.2")
        XCTAssertEqual(label(.fiveOne, 0), "5.1")
        XCTAssertEqual(label(.fiveOne, 2), "5.2")
        XCTAssertEqual(label(.sevenOneFour, 2), "7.2.4")
        XCTAssertEqual(label(.sevenOneFour, 4), "7.4.4")
        XCTAssertEqual(label(.nineOneSix, 0), "9.1.6")
        XCTAssertEqual(label(.nineOneSix, 2), "9.2.6")
        XCTAssertEqual(label(.nineOneSix, 4), "9.4.6")
    }

    func testCalibrationReachesThePlanAndLegacyArchivesDecodeWithout() throws {
        let profile = sevenOneFourProfile(calibrated: true)
        try profile.validateStructure(bassManagementEnabled: true)
        let plan = try profile.makeLivePlan(
            availableDevices: [avr], sampleRate: 96_000,
            selectedOutputUID: "avr", bassManagementEnabled: true
        )
        XCTAssertEqual(plan.speakerCalibrations[.frontLeft]?.trimDB, -2.5)
        XCTAssertEqual(plan.speakerCalibrations[.frontLeft]?.eqBands.count, 1)
        XCTAssertEqual(plan.subwooferCalibrations[0]?.gainDB, -1.5)
        XCTAssertEqual(plan.subwooferCalibrations[1]?.delayMilliseconds, 4.0)
        XCTAssertTrue(try plan.makeRealtimeOutputMap().valid)

        // Archives written before calibration existed have no calibration keys.
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
        )
        root.removeValue(forKey: "calibrationSummary")
        for key in ["speakerAssignments", "subwooferAssignments"] {
            if var objects = root[key] as? [[String: Any]] {
                for index in objects.indices { objects[index].removeValue(forKey: "calibration") }
                root[key] = objects
            }
        }
        let legacy = try JSONDecoder().decode(
            OutputDeviceProfileConfiguration.self,
            from: JSONSerialization.data(withJSONObject: root)
        )
        XCTAssertNil(legacy.calibrationSummary)
        XCTAssertTrue(legacy.speakerAssignments.allSatisfy { $0.calibration == nil })
        XCTAssertTrue(legacy.subwooferAssignments.allSatisfy { $0.calibration == nil })
        XCTAssertNoThrow(try legacy.validateStructure(bassManagementEnabled: true))
    }

    // MARK: Cross-feature ownership

    private func stereoProfile(subwoofers: Int = 0) -> OutputDeviceProfileConfiguration {
        OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(role: .frontLeft, destination: endpoint(0)),
                SemanticSpeakerOutputAssignment(role: .frontRight, destination: endpoint(1)),
            ],
            subwooferAssignments: (0..<subwoofers).map {
                PhysicalSubwooferOutputAssignment(index: UInt32($0), destination: endpoint(UInt32(2 + $0)))
            }
        )
    }

    private func optimizerPEQ(for profile: OutputDeviceProfileConfiguration) -> SpeakerOptimizerPEQDeploymentConfiguration {
        SpeakerOptimizerPEQDeploymentConfiguration(
            proposalID: UUID(),
            baselineMeasurementSetID: UUID(),
            characterizationMeasurementSetID: UUID(),
            routingSignature: profile.multichannelCalibrationRoutingSignature,
            sampleRate: 48_000,
            aggregateCandidateFingerprint: "peq",
            approvedAt: Date(timeIntervalSince1970: 1_760_000_000),
            sources: [
                SpeakerOptimizerPEQSourceDeployment(
                    role: .frontLeft,
                    bands: [SpeakerOptimizerDeployedPEQBand(frequencyHz: 220, gainDB: -3, q: 2)]
                )
            ]
        )
    }

    private func optimizerFIR(for profile: OutputDeviceProfileConfiguration) -> SpeakerOptimizerFIRDeploymentConfiguration {
        var taps = [Float](repeating: 0, count: 257)
        taps[128] = 1
        return SpeakerOptimizerFIRDeploymentConfiguration(
            proposalID: UUID(),
            baselineMeasurementSetID: UUID(),
            characterizationMeasurementSetID: UUID(),
            routingSignature: profile.multichannelCalibrationRoutingSignature,
            sampleRate: 48_000,
            aggregateCandidateFingerprint: "fir",
            approvedAt: Date(timeIntervalSince1970: 1_760_000_000),
            tapCount: 257,
            declaredGroupDelayFrames: 128,
            requiredHeadroomDB: 1,
            sources: [
                SpeakerOptimizerFIRSourceDeployment(
                    role: .frontLeft,
                    candidateFingerprint: "fir-left",
                    taps: taps,
                    maximumPositiveGainDB: 0.5,
                    recommendedHeadroomDB: 1
                )
            ]
        )
    }

    func testSpeakerOptimizerPEQAndFIRAreMutuallyExclusive() throws {
        let base = stereoProfile()

        var peqOnly = base
        peqOnly.speakerOptimizerPEQ = optimizerPEQ(for: base)
        XCTAssertNoThrow(try peqOnly.validateStructure(bassManagementEnabled: false))

        var firOnly = base
        firOnly.speakerOptimizerFIR = optimizerFIR(for: base)
        XCTAssertNoThrow(try firOnly.validateStructure(bassManagementEnabled: false))

        var both = base
        both.speakerOptimizerPEQ = optimizerPEQ(for: base)
        both.speakerOptimizerFIR = optimizerFIR(for: base)
        XCTAssertThrowsError(try both.validateStructure(bassManagementEnabled: false))
        XCTAssertThrowsError(try both.speakerOptimizerPEQ?.validate(profile: both))
        XCTAssertThrowsError(try both.speakerOptimizerFIR?.validate(profile: both))
    }

    private func speakerDelays(_ profile: OutputDeviceProfileConfiguration) -> [CoherentSubwooferAlignmentSpeakerDelayRecord] {
        profile.speakerAssignments.map {
            CoherentSubwooferAlignmentSpeakerDelayRecord(role: $0.role, delayMilliseconds: 0)
        }
    }

    private func singleSubAlignment(for profile: OutputDeviceProfileConfiguration) -> CoherentSubwooferAlignmentDeploymentRecord {
        CoherentSubwooferAlignmentDeploymentRecord(
            applyReceiptID: UUID(),
            proposalID: UUID(),
            playbackSystemID: UUID(),
            routingSignature: profile.multichannelCalibrationRoutingSignature,
            sampleRate: 48_000,
            crossoverFrequencyHz: 80,
            subwooferIndex: 0,
            mainRoles: [.frontLeft, .frontRight],
            evidenceFingerprint: "evidence",
            candidateFingerprint: "candidate",
            appliedAt: Date(timeIntervalSince1970: 1_760_000_000),
            signedRelativeDelayAdjustmentMilliseconds: 0,
            speakerCommonDelayAdjustmentMilliseconds: 0,
            subwooferDelayAdjustmentMilliseconds: 0,
            resultingSubwooferPolarityInverted: false,
            expectedSpeakerDelays: speakerDelays(profile),
            expectedSubwooferDelayMilliseconds: 0,
            expectedSubwooferPolarityInverted: false
        )
    }

    private func multiSubAlignment(for profile: OutputDeviceProfileConfiguration) -> CoherentMultiSubwooferAlignmentDeploymentRecord {
        CoherentMultiSubwooferAlignmentDeploymentRecord(
            applyReceiptID: UUID(),
            proposalID: UUID(),
            playbackSystemID: UUID(),
            routingSignature: profile.multichannelCalibrationRoutingSignature,
            sampleRate: 48_000,
            crossoverFrequencyHz: 80,
            mainRoles: [.frontLeft, .frontRight],
            evidenceFingerprint: "evidence",
            candidateFingerprint: "candidate",
            appliedAt: Date(timeIntervalSince1970: 1_760_000_000),
            speakerCommonDelayAdjustmentMilliseconds: 0,
            expectedSpeakerDelays: speakerDelays(profile),
            subwoofers: profile.subwooferAssignments.map {
                CoherentMultiSubwooferAlignmentSubDeploymentRecord(
                    subwooferIndex: $0.index,
                    signedRelativeDelayAdjustmentMilliseconds: 0,
                    subwooferDelayAdjustmentMilliseconds: 0,
                    resultingSubwooferPolarityInverted: false,
                    expectedSubwooferDelayMilliseconds: 0,
                    expectedSubwooferPolarityInverted: false
                )
            }
        )
    }

    func testSingleAndMultiSubAlignmentRecordsAreMutuallyExclusive() throws {
        let base = stereoProfile(subwoofers: 2)

        var single = base
        single.coherentSubwooferAlignment = singleSubAlignment(for: base)
        XCTAssertNoThrow(try single.validateStructure(bassManagementEnabled: true))

        var multi = base
        multi.coherentMultiSubwooferAlignment = multiSubAlignment(for: base)
        XCTAssertNoThrow(try multi.validateStructure(bassManagementEnabled: true))

        var both = base
        both.coherentSubwooferAlignment = singleSubAlignment(for: base)
        both.coherentMultiSubwooferAlignment = multiSubAlignment(for: base)
        XCTAssertThrowsError(try both.validateStructure(bassManagementEnabled: true)) { error in
            XCTAssertEqual(error as? CoherentMultiSubwooferAlignmentDeploymentError, .invalidRecord)
        }
    }

    // MARK: Live N-channel stage order

    /// The live render must run program FIR -> speaker lanes -> bass management.
    /// The output of N60LiveNChannelRenderProcessFrame is compared bit for bit
    /// with the three stages chained by hand in that order. The Sub feed is
    /// also compared with bass management run first, which proves the check
    /// can tell that order apart. FIR and lanes are both linear and
    /// time-invariant, so swapping just those two is caught only by the
    /// bit-exact comparison, not by a distinct output.
    func testLiveRenderRunsProgramFIRBeforeLanesBeforeBassManagement() throws {
        for rate in [48_000.0, 96_000, 384_000] {
            try assertLiveStageOrder(sampleRate: rate)
        }
    }

    private func assertLiveStageOrder(sampleRate: Double) throws {
        let routePlan = LiveNChannelOutputRoutePlan(
            programLayout: .stereo,
            orderedDeviceUIDs: ["avr"],
            referenceDeviceUID: "avr",
            physicalChannelCount: 3,
            programPhysicalChannels: [0, 1],
            subwooferPhysicalChannels: [2],
            subwooferCount: 1,
            bassManagementEnabled: true,
            speakerCalibrations: [
                .frontLeft: SemanticSpeakerCalibration(
                    trimDB: -3,
                    eqBands: [OutputCalibrationEQBand(frequencyHz: 60, gainDB: -6, q: 1.5)]
                ),
                .frontRight: SemanticSpeakerCalibration(delayMilliseconds: 1),
            ],
            subwooferCalibrations: [nil]
        )
        var graph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: routePlan,
            sampleRate: sampleRate,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(enabled: true, frequencyHz: 100)
        )

        // Left-only FIR: a -6 dB, 128-frame linear-phase delay.
        let tapCount: UInt32 = 257
        var taps = [Float](repeating: 0, count: Int(tapCount))
        taps[128] = 0.5
        let activeMask: UInt32 = 0b01
        let probe = try XCTUnwrap(N60ProgramFIRProgramCreate(2, activeMask, taps, tapCount, 128))
        let info = N60ProgramFIRProgramGetInfo(probe)
        N60ProgramFIRProgramDestroy(probe)
        XCTAssertTrue(N60LiveNChannelRenderGraphSetProgramFIRInfo(&graph, info, true))

        let live = try XCTUnwrap(N60LiveNChannelRenderRuntimeCreate())
        defer { N60LiveNChannelRenderRuntimeDestroy(live) }
        XCTAssertTrue(N60LiveNChannelRenderRuntimeConfigureProgramFIR(live, &graph, taps))
        XCTAssertTrue(N60LiveNChannelRenderRuntimePrepare(live, &graph))

        // Independent stage runtimes for the reference chains.
        let firProgram = try XCTUnwrap(N60ProgramFIRProgramCreate(2, activeMask, taps, tapCount, 128))
        defer { N60ProgramFIRProgramDestroy(firProgram) }
        let firA = try XCTUnwrap(N60ProgramFIRRuntimeCreate(firProgram))
        defer { N60ProgramFIRRuntimeDestroy(firA) }
        let firB = try XCTUnwrap(N60ProgramFIRRuntimeCreate(firProgram))
        defer { N60ProgramFIRRuntimeDestroy(firB) }
        let laneA = try XCTUnwrap(N60ProgramLaneRuntimeCreate())
        defer { N60ProgramLaneRuntimeDestroy(laneA) }
        let laneB = try XCTUnwrap(N60ProgramLaneRuntimeCreate())
        defer { N60ProgramLaneRuntimeDestroy(laneB) }
        let bassA = try XCTUnwrap(N60MultichannelBassManagementRuntimeCreate())
        defer { N60MultichannelBassManagementRuntimeDestroy(bassA) }
        let bassB = try XCTUnwrap(N60MultichannelBassManagementRuntimeCreate())
        defer { N60MultichannelBassManagementRuntimeDestroy(bassB) }
        XCTAssertEqual(
            MemoryLayout.size(ofValue: N60ProgramTransportFrame().channels),
            Int(N60_MAX_PROGRAM_CHANNELS) * MemoryLayout<Float>.size
        )
        N60ProgramFIRRuntimeReset(firA)
        N60ProgramFIRRuntimeReset(firB)
        XCTAssertTrue(N60ProgramLaneRuntimePrepare(laneA, &graph.laneGraph))
        XCTAssertTrue(N60ProgramLaneRuntimePrepare(laneB, &graph.laneGraph))
        XCTAssertTrue(N60MultichannelBassManagementRuntimePrepare(bassA, &graph.bassManagement))
        XCTAssertTrue(N60MultichannelBassManagementRuntimePrepare(bassB, &graph.bassManagement))

        var mismatches = 0
        var subOrderDifference: Float = 0
        var subEnergy: Float = 0
        for frame in 0..<16_384 {
            var input = N60ProgramTransportFrame()
            var program = [Float](repeating: 0, count: Int(N60_MAX_PROGRAM_CHANNELS))
            if frame == 0 { program[0] = 0.8 }
            if frame == 37 { program[1] = -0.6 }
            withUnsafeMutableBytes(of: &input.channels) { raw in
                program.withUnsafeBytes { raw.copyMemory(from: $0) }
            }

            var physical = N60LiveNChannelPhysicalFrame()
            XCTAssertTrue(N60LiveNChannelRenderProcessFrame(live, &graph, &input, &physical, nil))
            let liveValues = withUnsafeBytes(of: physical.values) { Array($0.bindMemory(to: Float.self).prefix(3)) }

            // Reference: FIR -> lanes -> bass management.
            var fir = [Float](repeating: 0, count: program.count)
            var lane = [Float](repeating: 0, count: program.count)
            var speakers = [Float](repeating: 0, count: program.count)
            var subs = [Float](repeating: 0, count: Int(N60_MAX_SUBWOOFER_OUTPUTS))
            XCTAssertTrue(N60ProgramFIRRuntimeProcessFrame(firA, program, &fir))
            XCTAssertTrue(N60ProgramLaneProcessFrame(laneA, &graph.laneGraph, fir, &lane, nil))
            XCTAssertTrue(N60MultichannelBassManagementProcessFrame(bassA, &graph.bassManagement, lane, &speakers, &subs))
            let reference = [speakers[0], speakers[1], subs[0]]
            if liveValues.map(\.bitPattern) != reference.map(\.bitPattern) { mismatches += 1 }

            // Wrong order: bass management first.
            var wrongSpeakers = [Float](repeating: 0, count: program.count)
            var wrongSubs = [Float](repeating: 0, count: Int(N60_MAX_SUBWOOFER_OUTPUTS))
            var wrongFIR = [Float](repeating: 0, count: program.count)
            var wrongLane = [Float](repeating: 0, count: program.count)
            XCTAssertTrue(N60MultichannelBassManagementProcessFrame(bassB, &graph.bassManagement, program, &wrongSpeakers, &wrongSubs))
            XCTAssertTrue(N60ProgramFIRRuntimeProcessFrame(firB, wrongSpeakers, &wrongFIR))
            XCTAssertTrue(N60ProgramLaneProcessFrame(laneB, &graph.laneGraph, wrongFIR, &wrongLane, nil))
            subOrderDifference = max(subOrderDifference, abs(wrongSubs[0] - subs[0]))
            subEnergy = max(subEnergy, abs(subs[0]))
        }
        XCTAssertEqual(mismatches, 0, "\(sampleRate) Hz: live render differs from FIR -> lanes -> bass management")
        XCTAssertGreaterThan(subEnergy, 1.0e-4, "\(sampleRate) Hz: the Sub received no redirected bass")
        XCTAssertGreaterThan(
            subOrderDifference, subEnergy * 0.1,
            "\(sampleRate) Hz: the Sub feed cannot distinguish stage order"
        )
    }
}
