import XCTest
@testable import NotchSixty

/// E8 A5: routing editor completion: live context, revert, free outputs, add speaker and subwoofers, output
/// reassignment, linear-phase choice, and the profile subwoofer edits. View-model and pure logic only.
@MainActor
final class RoutingEditorCompletionTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func ep(_ i: UInt32, _ uid: String = "dev") -> PhysicalOutputEndpoint {
        PhysicalOutputEndpoint(deviceUID: uid, channelIndex: i)
    }

    private func device(_ uid: String = "dev", channels: UInt32 = 8, rate: Double = 48_000) -> AudioOutputDevice {
        AudioOutputDevice(deviceID: 1, uid: uid, name: "Dev \(uid)", nominalSampleRate: rate,
                          availableSampleRateRanges: [], outputChannelCount: channels)
    }

    private func model(rate: Double = 48_000, lanes: Int = 2, subs: Int = 0, enabled: Bool = true,
                       bass: Bool? = nil) -> SpeakerRoutingEditorModel {
        let m = SpeakerRoutingEditorModel(
            configuration: SpeakerRoutingConfiguration(enabled: enabled),
            context: SpeakerRoutingContext(programLanes: lanes, subwoofers: subs, sampleRate: rate))
        m.updateContext(programLanes: lanes, profileSubwoofers: subs, sampleRate: rate, bassManagementEnabled: bass)
        return m
    }

    private func twoWayPair(_ m: SpeakerRoutingEditorModel, family: CrossoverCore.Family = .linkwitzRiley, order: Int = 4) {
        let spec = { (hz: Double) in CrossoverCore.FilterSpec(family: family, order: order, cornerHz: hz) }
        m.replace(SpeakerRoutingConfiguration(speakers: [
            RoutedSpeaker(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Left",
                          source: .program(0), ways: [
                RoutedWay(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "Low",
                          endpoint: ep(0), lowPass: spec(2_000)),
                RoutedWay(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, name: "High",
                          endpoint: ep(1), highPass: spec(2_000))]),
        ]))
    }

    // MARK: Live context and revert

    func testContextFollowsProfileLayoutAndRateWithoutCommit() {
        let m = model(subs: 2)
        var commits = 0
        m.onCommit = { _ in commits += 1 }
        XCTAssertEqual(m.matrixSources.count, 4)
        m.updateContext(programLanes: 6, profileSubwoofers: 6, sampleRate: 96_000)
        XCTAssertEqual(m.matrixSources.count, 12)
        XCTAssertEqual(m.context.sampleRate, 96_000)
        XCTAssertEqual(m.plotFrequencies().last ?? 0, 20_000, accuracy: 1)
        m.updateContext(programLanes: 2, profileSubwoofers: 0, sampleRate: 44_100)
        XCTAssertEqual(m.matrixSources.count, 2)
        XCTAssertEqual(m.plotFrequencies().last ?? 0, 0.45 * 44_100, accuracy: 1)
        XCTAssertEqual(commits, 0)
    }

    func testSubwooferContextIsMaxOfProfileAndRouting() {
        let m = model()
        XCTAssertEqual(m.addSubwooferOnFreeOutput(selected: device()), .done)
        XCTAssertEqual(m.context.subwoofers, 1)
        m.updateContext(programLanes: 2, profileSubwoofers: 3, sampleRate: 48_000)
        XCTAssertEqual(m.context.subwoofers, 3)
        m.updateContext(programLanes: 2, profileSubwoofers: 0, sampleRate: 48_000)
        XCTAssertEqual(m.context.subwoofers, 1)
    }

    func testRevertRestoresWithoutCommitAndDropsBypassedLinearisationOfGoneWays() {
        let m = model()
        twoWayPair(m)
        let kept = m.configuration
        let lowID = kept.speakers[0].ways[0].id
        let capture = CrossoverCore.ResponseCapture(
            frequenciesHz: (1...16).map { Double($0) * 100 }, levelsDB: Array(repeating: 0, count: 16))
        m.applyLinearisation(RoutedWayLinearisation(nearField: capture), way: lowID)
        m.setLinearisationBypassed(true, way: lowID)
        XCTAssertEqual(m.linearisationState(lowID), .bypassed)
        var commits = 0
        m.onCommit = { _ in commits += 1 }
        var other = kept
        other.speakers[0].ways.removeAll { $0.id == lowID }
        m.revert(to: other)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(m.configuration, other)
        XCTAssertEqual(m.linearisationState(lowID), .none)
    }

    // MARK: Free outputs

    func testNextFreeEndpointHonoursChannelCountDeviceAndRawEntries() {
        let m = model()
        XCTAssertEqual(m.nextFreeEndpoint(deviceUID: "dev", channelCount: 2), ep(0))
        m.replace(SpeakerRoutingConfiguration(
            speakers: [RoutedSpeaker(name: "L", source: .program(0), ways: [
                RoutedWay(name: "L", endpoint: ep(0)), RoutedWay(name: "L2", endpoint: ep(1, "other"))])],
            matrix: [RoutingMatrixEntry(source: .program(1), output: ep(1))]))
        XCTAssertEqual(m.nextFreeEndpoint(deviceUID: "dev", channelCount: 4), ep(2))
        XCTAssertEqual(m.nextFreeEndpoint(deviceUID: "other", channelCount: 4), ep(0, "other"))
        XCTAssertNil(m.nextFreeEndpoint(deviceUID: "dev", channelCount: 2))
    }

    func testAddWayUsesNextFreeOutputOfTheSpeakersDevice() {
        let m = model()
        m.addSpeaker(name: "L", source: .program(0), endpoint: ep(0))
        let id = m.configuration.speakers[0].id
        XCTAssertEqual(m.addWayOnFreeOutput(speaker: id, devices: [device(channels: 2)], selected: nil), .done)
        XCTAssertEqual(m.configuration.speakers[0].ways.last?.endpoint, ep(1))
        XCTAssertEqual(m.addWayOnFreeOutput(speaker: id, devices: [device(channels: 2)], selected: nil),
                       .refused("All 2 outputs of Dev dev are in use."))
        XCTAssertEqual(m.configuration.speakers[0].ways.count, 2)
    }

    // MARK: Speakers

    func testAddSpeakerSourceNameAndEndpointForStereoAnd51() {
        let stereo = model()
        XCTAssertEqual(stereo.addSpeakerOnFreeOutput(selected: device()), .done)
        XCTAssertEqual(stereo.addSpeakerOnFreeOutput(selected: device()), .done)
        XCTAssertEqual(stereo.addSpeakerOnFreeOutput(selected: device()), .done)
        let s = stereo.configuration.speakers
        XCTAssertEqual(s.map(\.name), ["Left", "Right", "Speaker 3"])
        XCTAssertEqual(s.map(\.source), [.program(0), .program(1), .program(0)])
        XCTAssertEqual(s.map { $0.ways[0].endpoint }, [ep(0), ep(1), ep(2)])
        XCTAssertNil(s[0].ways[0].highPass)

        let surround = model(lanes: 6)
        surround.updateContext(programLanes: 6, profileSubwoofers: 0, sampleRate: 48_000,
                               programLaneNames: OutputProgramLayout.fiveOne.roles.map(\.displayName))
        XCTAssertEqual(surround.addSpeakerOnFreeOutput(selected: device()), .done)
        XCTAssertEqual(surround.addSpeakerOnFreeOutput(selected: device()), .done)
        XCTAssertEqual(surround.configuration.speakers.map(\.name), ["Front Left", "Front Right"])
        XCTAssertEqual(surround.configuration.speakers.last?.source, .program(1))
        XCTAssertEqual(surround.addSpeakerOnFreeOutput(selected: nil), .refused("Select an output device first."))
    }

    func testSourcePickerChangesOnlySource() {
        let m = model(subs: 1)
        m.addSpeaker(name: "L", source: .program(0), endpoint: ep(0))
        let before = m.configuration.speakers[0]
        m.setSource(.sub(0), speaker: before.id)
        var expected = before
        expected.source = .sub(0)
        XCTAssertEqual(m.configuration.speakers[0], expected)
    }

    func testLastSpeakerRefusedWhileEnabledAllowedWhileDisabled() {
        let m = model()
        m.addSpeaker(name: "L", source: .program(0), endpoint: ep(0))
        var commits = 0
        m.onCommit = { _ in commits += 1 }
        let id = m.configuration.speakers[0].id
        XCTAssertEqual(m.removeSpeakerBlockReason(id), "Turn off the routing matrix to remove the last speaker.")
        XCTAssertFalse(m.removeSpeaker(id))
        XCTAssertEqual(commits, 0)
        m.setEnabled(false)
        XCTAssertTrue(m.removeSpeaker(id))
        XCTAssertEqual(commits, 2)
        XCTAssertTrue(m.configuration.speakers.isEmpty)
    }

    // MARK: Subwoofers

    func testAddSubsToEightAndRefuseTheNinthByName() {
        let m = model(bass: true)
        for n in 1...8 { XCTAssertEqual(m.addSubwooferOnFreeOutput(selected: device(channels: 16)), .done, "sub \(n)") }
        XCTAssertEqual(m.configuration.subwooferSourceCount, 8)
        XCTAssertEqual(m.subwooferSpeakers.map(\.name), (1...8).map { "Sub \($0)" })
        XCTAssertEqual(m.addSubwooferOnFreeOutput(selected: device(channels: 16)),
                       .refused("Sub 9 cannot be added: the limit is 8 subwoofers."))
        XCTAssertTrue(m.validation.isValid)
    }

    func testRemovingSub2Of4RenumbersSpeakersAndMatrix() {
        let m = model(bass: true)
        for _ in 1...4 { m.addSubwooferOnFreeOutput(selected: device()) }
        m.setMatrixGain(source: .sub(3), output: ep(7), gain: 0.5)
        m.setMatrixGain(source: .sub(1), output: ep(6), gain: 0.5)
        XCTAssertEqual(m.removeSubwoofer(index: 1), .done)
        XCTAssertEqual(m.subwooferSpeakers.map(\.source), [.sub(0), .sub(1), .sub(2)])
        XCTAssertEqual(m.subwooferSpeakers.map(\.name), ["Sub 1", "Sub 2", "Sub 3"])
        XCTAssertEqual(m.subwooferSpeakers.map { $0.ways[0].name }, ["Sub 1", "Sub 2", "Sub 3"])
        XCTAssertEqual(m.subwooferSpeakers.map { $0.ways[0].endpoint }, [ep(0), ep(2), ep(3)])
        XCTAssertEqual(m.configuration.matrix, [RoutingMatrixEntry(source: .sub(2), output: ep(7), gain: 0.5)])
        XCTAssertEqual(m.configuration.subwooferSourceCount, 3)
        XCTAssertEqual(m.context.subwoofers, 3)
    }

    func testBassManagementGuards() {
        let off = model(bass: false)
        XCTAssertEqual(off.subwooferAddBlockReason, "It reads subwoofer sources, so bass management must be on.")
        XCTAssertEqual(off.addSubwooferOnFreeOutput(selected: device()),
                       .refused("It reads subwoofer sources, so bass management must be on."))
        XCTAssertTrue(off.configuration.speakers.isEmpty)
        off.setEnabled(false)
        XCTAssertNil(off.subwooferAddBlockReason)

        let on = model(bass: true)
        on.addSubwooferOnFreeOutput(selected: device())
        XCTAssertNotNil(on.subwooferRemoveBlockReason(index: 0))
        XCTAssertNotEqual(on.removeSubwoofer(index: 0), .done)
        XCTAssertEqual(on.subwooferSpeakers.count, 1)
        on.addSubwooferOnFreeOutput(selected: device())
        XCTAssertEqual(on.removeSubwoofer(index: 0), .done)
    }

    func testMainsPlusSubTemplateStillDetectedAfterAddingAndRemovingASub() {
        let m = model(subs: 1, bass: true)
        XCTAssertTrue(m.applyTemplate(.mainsPlusSub, deviceUID: "dev"))
        XCTAssertEqual(m.currentTemplate, .mainsPlusSub)
        XCTAssertEqual(m.addSubwooferOnFreeOutput(selected: device()), .done)
        XCTAssertEqual(m.currentTemplate, .mainsPlusSub)
        XCTAssertEqual(m.removeSubwoofer(index: 1), .done)
        XCTAssertEqual(m.currentTemplate, .mainsPlusSub)
    }

    // MARK: Output reassignment

    func testMoveSwapAndUnchanged() {
        let m = model()
        twoWayPair(m)
        m.replace({ var c = m.configuration; c.matrix = [RoutingMatrixEntry(source: .program(0), output: ep(5))]; return c }())
        let speaker = m.configuration.speakers[0]
        let low = speaker.ways[0], high = speaker.ways[1]
        var commits = 0
        m.onCommit = { _ in commits += 1 }

        XCTAssertEqual(m.setEndpoint(ep(0), way: low.id, speaker: speaker.id), .unchanged)
        XCTAssertEqual(commits, 0)

        XCTAssertEqual(m.setEndpoint(ep(3), way: low.id, speaker: speaker.id), .moved)
        XCTAssertEqual(m.configuration.speakers[0].ways[0].endpoint, ep(3))
        XCTAssertEqual(commits, 1)

        XCTAssertEqual(m.setEndpoint(ep(1), way: low.id, speaker: speaker.id), .swapped(high.id))
        let ways = m.configuration.speakers[0].ways
        XCTAssertEqual(ways[0].endpoint, ep(1))
        XCTAssertEqual(ways[1].endpoint, ep(3))
        XCTAssertEqual(ways[0].lowPass, low.lowPass)
        XCTAssertEqual(ways[1].highPass, high.highPass)
        XCTAssertEqual(commits, 2)
        XCTAssertTrue(m.validation.isValid)
        XCTAssertEqual(m.configuration.matrix, [RoutingMatrixEntry(source: .program(0), output: ep(5))])
    }

    func testSwapKeepsEachWaysLinearisation() {
        let m = model()
        twoWayPair(m)
        let speaker = m.configuration.speakers[0]
        let capture = CrossoverCore.ResponseCapture(
            frequenciesHz: (1...16).map { Double($0) * 100 }, levelsDB: Array(repeating: 0, count: 16))
        let lin = RoutedWayLinearisation(nearField: capture)
        m.applyLinearisation(lin, way: speaker.ways[0].id)
        m.setEndpoint(ep(1), way: speaker.ways[0].id, speaker: speaker.id)
        XCTAssertEqual(m.configuration.speakers[0].ways[0].linearisation, lin)
        XCTAssertNil(m.configuration.speakers[0].ways[1].linearisation)
    }

    func testOutputChoicesListConnectedChannelsAndMissingDevice() {
        let current = ep(1, "gone")
        let choices = RoutingOutputChoice.choices(devices: [device("a", channels: 2), device("b", channels: 1)], current: current)
        XCTAssertEqual(choices.map(\.title), ["Dev a · Out 1", "Dev a · Out 2", "Dev b · Out 1", "gone · Out 2 (not connected)"])
        XCTAssertEqual(choices.map(\.connected), [true, true, true, false])
        XCTAssertEqual(RoutingOutputChoice.choices(devices: [device("a", channels: 2)], current: ep(1, "a")).count, 2)
    }

    // MARK: Linear phase

    func testMixedReportedAndOneChoiceUnifies() {
        let m = model()
        twoWayPair(m)
        let speaker = m.configuration.speakers[0]
        XCTAssertEqual(m.realisationChoice(speaker), .iir)
        m.editWay(speaker.ways[0].id, speaker: speaker.id) { $0.realisation = .fir }
        XCTAssertEqual(m.realisationChoice(m.configuration.speakers[0]), .mixed)
        m.setRealisation(.fir, speaker: speaker.id)
        XCTAssertEqual(m.realisationChoice(m.configuration.speakers[0]), .fir)
        m.setRealisation(.iir, speaker: speaker.id)
        XCTAssertEqual(m.realisationChoice(m.configuration.speakers[0]), .iir)
    }

    func testSubSpeakersOfferNoRealisationChoice() {
        let m = model(bass: true)
        m.addSubwooferOnFreeOutput(selected: device())
        XCTAssertNil(m.realisationChoice(m.subwooferSpeakers[0]))
        XCTAssertNil(m.linearPhaseLatency(m.subwooferSpeakers[0]))
    }

    func testIIRPlotIsUnchangedByTheRealisationField() throws {
        let m = model()
        twoWayPair(m)
        let speaker = m.configuration.speakers[0]
        let iir = m.plotFrequencies(points: 40).map { m.summedMagnitudeDB(speaker, atHz: $0) ?? 0 }
        let phase = try XCTUnwrap(m.wayResponse(speaker.ways[1], atHz: 1_000))
        XCTAssertNotEqual(phase.im, 0, accuracy: 1e-6)
        // Phase-coherent sum of an LR4 pair is flat.
        iir.forEach { XCTAssertEqual($0, 0, accuracy: 0.05) }
    }

    func testLinearPhasePlotSumIsFlatAndWaysMatchTheDesignedTapsAtEveryRate() throws {
        for rate in Self.rates {
            for (order, corners) in [(4, [2_000.0]), (8, [2_000.0]), (4, [400.0, 3_000.0]), (8, [400.0, 3_000.0])] {
                let m = model(rate: rate)
                let spec = { (hz: Double) in CrossoverCore.FilterSpec(family: .linkwitzRiley, order: order, cornerHz: hz) }
                var ways: [RoutedWay] = []
                for index in 0...corners.count {
                    ways.append(RoutedWay(
                        name: "w\(index)", endpoint: ep(UInt32(index)),
                        highPass: index == 0 ? nil : spec(corners[index - 1]),
                        lowPass: index == corners.count ? nil : spec(corners[index]), realisation: .fir))
                }
                m.replace(SpeakerRoutingConfiguration(speakers: [RoutedSpeaker(name: "S", source: .program(0), ways: ways)]))
                let speaker = m.configuration.speakers[0]
                XCTAssertEqual(m.realisationChoice(speaker), .fir)
                let label = "rate \(rate) LR\(order * 6 / 6 * 1) \(corners)"
                for hz in m.plotFrequencies(points: 40) {
                    let sum = try XCTUnwrap(m.summedMagnitudeDB(speaker, atHz: hz))
                    XCTAssertEqual(sum, 0, accuracy: 0.05, "\(label) sum at \(hz)")
                }
                for way in speaker.ways {
                    let design = try CrossoverCore.linearPhaseDesign(highPass: way.highPass, lowPass: way.lowPass, sampleRate: rate)
                    if design.plan.twoBand {
                        XCTAssertGreaterThan(design.plan.decimation, 1)
                        continue
                    }
                    for hz in m.plotFrequencies(points: 40) {
                        let plotted = try XCTUnwrap(m.wayMagnitudeDB(way, atHz: hz))
                        guard plotted > -6 else { continue }
                        XCTAssertEqual(plotted, Self.magnitudeDB(design.fullTaps, atHz: hz, rate: rate), accuracy: 0.35,
                                       "\(label) \(way.name) at \(hz)")
                    }
                }
            }
        }
    }

    func testShownLatencyEqualsTheSharedGroupDelayToOneSample() throws {
        for rate in Self.rates {
            let m = model(rate: rate)
            twoWayPair(m)
            let speaker = m.configuration.speakers[0]
            XCTAssertNil(m.linearPhaseLatency(speaker))
            m.setRealisation(.fir, speaker: speaker.id)
            let fir = m.configuration.speakers[0]
            let latency = try XCTUnwrap(m.linearPhaseLatency(fir))
            let plans = try fir.ways.map {
                try CrossoverCore.linearPhasePlan(highPass: $0.highPass, lowPass: $0.lowPass, sampleRate: rate)
            }
            let shared = plans.map(\.groupDelayFrames).max() ?? 0
            XCTAssertEqual(latency.frames, shared)
            XCTAssertGreaterThan(latency.frames, 0)
            for way in fir.ways {
                let design = try CrossoverCore.linearPhaseDesign(
                    highPass: way.highPass, lowPass: way.lowPass, sampleRate: rate, groupDelayFrames: shared)
                XCTAssertEqual(design.plan.groupDelayFrames, shared, "rate \(rate)")
            }
        }
    }

    private static func magnitudeDB(_ taps: [Float], atHz hz: Double, rate: Double) -> Double {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * hz / rate
        for (n, tap) in taps.enumerated() {
            re += Double(tap) * cos(w * Double(n))
            im -= Double(tap) * sin(w * Double(n))
        }
        return 20 * log10(max(1e-12, (re * re + im * im).squareRoot()))
    }

    // MARK: Profile subwoofers

    private func profile(subs: Int, summary: Bool = false) -> OutputDeviceProfileConfiguration {
        var p = OutputDeviceProfileConfiguration(
            enabled: true, programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(role: .frontLeft, destination: ep(0, "avr")),
                SemanticSpeakerOutputAssignment(role: .frontRight, destination: ep(1, "avr"))],
            subwooferAssignments: (0..<subs).map {
                PhysicalSubwooferOutputAssignment(
                    index: UInt32($0), destination: ep(UInt32(2 + $0), "avr"),
                    calibration: PhysicalSubwooferCalibration(gainDB: 0, delayMilliseconds: Double($0), polarityInverted: false))
            })
        if summary {
            p.calibrationSummary = MultichannelCalibrationDeploymentSummary(
                measuredAt: Date(timeIntervalSince1970: 1), deployedAt: Date(timeIntervalSince1970: 2), seatCount: 1,
                speakerCount: 2, subwooferCount: subs, targetName: "T", sampleRate: 48_000)
        }
        return p
    }

    func testProfileAddToEightRemoveKeepsContiguousIndicesAndCalibration() throws {
        var p = profile(subs: 1)
        for n in 2...8 {
            let dest = try XCTUnwrap(p.nextFreeDestination(deviceUID: "avr", channelCount: 16))
            p = try p.addingSubwoofer(destination: dest).profile
            XCTAssertEqual(p.subwooferAssignments.count, n)
        }
        try p.validateStructure(bassManagementEnabled: true)
        XCTAssertThrowsError(try p.addingSubwoofer(destination: ep(15, "avr"))) {
            XCTAssertEqual($0 as? OutputDeviceProfileSubwooferEditError, .limit)
        }
        p.subwooferAssignments[2].calibration = PhysicalSubwooferCalibration(
            gainDB: -1, delayMilliseconds: 3, polarityInverted: true)
        let removed = try p.removingSubwoofer(index: 1).profile
        XCTAssertEqual(removed.subwooferAssignments.map(\.index), Array(0..<7).map(UInt32.init))
        XCTAssertEqual(removed.subwooferAssignments[1].calibration, p.subwooferAssignments[2].calibration)
        XCTAssertEqual(removed.subwooferAssignments[1].destination, p.subwooferAssignments[2].destination)
        try removed.validateStructure(bassManagementEnabled: true)
        XCTAssertThrowsError(try p.removingSubwoofer(index: 9))
    }

    func testProfileEditClearsInvalidRecordsAndKeepsValidOnes() throws {
        // A summary that counts 2 subs is stale after adding a third and cleared; moving a sub keeps it.
        let p = profile(subs: 2, summary: true)
        let moved = try p.movingSubwoofer(index: 1, to: ep(9, "avr"))
        XCTAssertEqual(moved.clearedRecords, [])
        XCTAssertEqual(moved.profile.calibrationSummary, p.calibrationSummary)
        XCTAssertEqual(moved.profile.subwooferAssignments[1].destination, ep(9, "avr"))

        let added = try p.addingSubwoofer(destination: ep(9, "avr"))
        XCTAssertEqual(added.clearedRecords, ["Calibration summary"])
        XCTAssertNil(added.profile.calibrationSummary)

        // A coherent single-sub record is bound to the routing signature: moving a sub invalidates it.
        var withAlignment = profile(subs: 1)
        withAlignment.coherentSubwooferAlignment = CoherentSubwooferAlignmentDeploymentRecord(
            applyReceiptID: UUID(), proposalID: UUID(), playbackSystemID: UUID(),
            routingSignature: withAlignment.multichannelCalibrationRoutingSignature, sampleRate: 48_000,
            crossoverFrequencyHz: 80, subwooferIndex: 0, mainRoles: [.frontLeft, .frontRight],
            evidenceFingerprint: "e", candidateFingerprint: "c", appliedAt: Date(timeIntervalSince1970: 1),
            signedRelativeDelayAdjustmentMilliseconds: 0, speakerCommonDelayAdjustmentMilliseconds: 0,
            subwooferDelayAdjustmentMilliseconds: 0, resultingSubwooferPolarityInverted: false,
            expectedSpeakerDelays: withAlignment.speakerAssignments.map {
                CoherentSubwooferAlignmentSpeakerDelayRecord(role: $0.role, delayMilliseconds: 0) },
            expectedSubwooferDelayMilliseconds: 0, expectedSubwooferPolarityInverted: false)
        XCTAssertTrue(withAlignment.coherentSubwooferAlignment?.validate(profile: withAlignment) == true)
        let moved2 = try withAlignment.movingSubwoofer(index: 0, to: ep(9, "avr"))
        XCTAssertEqual(moved2.clearedRecords, ["Coherent subwoofer alignment"])
        XCTAssertNil(moved2.profile.coherentSubwooferAlignment)
    }

    func testProfileFreeDestinationHonoursChannelCount() {
        let p = profile(subs: 1)
        XCTAssertEqual(p.nextFreeDestination(deviceUID: "avr", channelCount: 8), ep(3, "avr"))
        XCTAssertNil(p.nextFreeDestination(deviceUID: "avr", channelCount: 3))
        XCTAssertEqual(p.nextFreeDestination(deviceUID: "other", channelCount: 2), ep(0, "other"))
    }
}
