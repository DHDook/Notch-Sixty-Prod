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
}
