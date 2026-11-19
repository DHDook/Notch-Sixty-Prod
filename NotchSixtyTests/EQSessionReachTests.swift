import XCTest
@testable import NotchSixty

/// E33 S18 (G35): the Equalizer's reach on stereo, 2.1, 5.1, 7.1, 7.1.4 and Virtual Speakers (binaural) sessions, per channel
/// mode, row by row at the eight rates, through the graph the translator publishes.
@MainActor
final class EQSessionReachTests: XCTestCase {
    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_434, uid: "reach-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "reach-out")
        return engine
    }

    private func eqConfiguration(_ mode: EQChannelMode) -> StereoEQConfiguration {
        func band(_ gain: Double) -> [EQBand] { [EQBand(type: .peaking, frequencyHz: 1_000, gainDB: gain, q: 1)] }
        var c = StereoEQConfiguration()
        c.channelMode = mode
        c.linkedBands = band(3)
        c.leftBands = band(3)
        c.rightBands = band(-3)
        c.midBands = band(3)
        c.sideBands = band(-3)
        return c
    }

    private func lanes(_ spec: UnifiedGraphSpec, kind: n60_stage_kind) -> [Int] {
        var found = Set<Int>()
        for stage in spec.stages where stage.kind == kind.rawValue {
            if stage.laneMask != 0 {
                for lane in 0..<64 where stage.laneMask & (UInt64(1) << UInt64(lane)) != 0 { found.insert(lane) }
            } else {
                found.insert(Int(stage.laneA))
                if stage.kind == N60_STAGE_MS_ENCODE.rawValue || stage.kind == N60_STAGE_MS_DECODE.rawValue { found.insert(Int(stage.laneB)) }
            }
        }
        return found.sorted()
    }

    private let layouts: [(OutputProgramLayout, Bool)] = [
        (.stereo, false), (.threeOne, false), (.fiveOne, false), (.sevenOne, false), (.sevenOneFour, false),
        (.fiveOne, true), (.sevenOneFour, true),
    ]
    private let modes: [(EQChannelMode, UnifiedGraphProgramDSP.EQMode)] = [
        (.linked, .linked), (.independent, .independent), (.midSide, .midSide),
    ]

    func testEveryRowReachesTheTableLanesAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            for (mode, graphMode) in modes {
                let engine = try engine(rate: rate)
                try engine.replaceStereoEQConfiguration(eqConfiguration(mode))
                var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
                let stereo = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
                for (layout, virtual) in layouts {
                    let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
                    var configuration = UnifiedGraphTranslator.multichannelConfiguration(
                        sampleRate: rate, programChannels: layout.roles.count, subwoofers: [])
                    configuration.orderPolicy = .canonical
                    configuration.programDSP = UnifiedGraphProgramDSP(
                        stereo: stereo, shape: shape, eqMode: graphMode, virtualSpeakers: virtual)
                    let spec = try configuration.makeSpec()
                    let reach = EQSessionReach.reach(shape: shape, mode: graphMode)
                    let context = "\(layout.roles.count) lanes, virtual \(virtual), \(graphMode), \(rate)"
                    XCTAssertEqual(lanes(spec, kind: N60_STAGE_PEQ), reach.covered, "PEQ lanes \(context)")
                    XCTAssertEqual(lanes(spec, kind: N60_STAGE_MS_ENCODE), reach.midSideLanes, "encode \(context)")
                    XCTAssertEqual(lanes(spec, kind: N60_STAGE_MS_DECODE), reach.midSideLanes, "decode \(context)")
                    // The LFE never runs a curve, in any mode.
                    if let lfe = shape.lfeLane { XCTAssertTrue(reach.passThrough.contains(lfe), context) }
                    XCTAssertEqual(Set(reach.covered).union(reach.passThrough), Set(0..<shape.laneCount), context)
                    XCTAssertTrue(Set(reach.covered).isDisjoint(with: reach.passThrough), context)
                    XCTAssertEqual((reach.firstCurveLanes + reach.secondCurveLanes).sorted(), reach.covered, context)
                    // Independent: pairs only. Linked and Mid/Side: the centre and surrounds are covered.
                    if let centre = shape.centerLane {
                        XCTAssertEqual(reach.covered.contains(centre), graphMode != .independent, "centre \(context)")
                    }
                }
            }
        }
    }

    func testPageLineNamesTheReachOfEachRow() throws {
        func shape(_ layout: OutputProgramLayout) throws -> UnifiedGraphLayoutShape {
            try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
        }
        let five = try shape(.fiveOne)
        XCTAssertEqual(EQSessionReach.pageText(shape: five, mode: .linked, virtualSpeakers: false),
                       "Applies to all speakers except the LFE")
        XCTAssertEqual(EQSessionReach.pageText(shape: five, mode: .independent, virtualSpeakers: false),
                       "Applies to the left and right pairs; centre, LFE pass through")
        XCTAssertTrue(EQSessionReach.pageText(shape: five, mode: .midSide, virtualSpeakers: false)
            .contains("the centre takes the mid bands"))
        XCTAssertTrue(EQSessionReach.pageText(shape: five, mode: .linked, virtualSpeakers: true)
            .hasSuffix("before binaural rendering)"))
        XCTAssertEqual(EQSessionReach.pageText(shape: try shape(.stereo), mode: .linked, virtualSpeakers: false),
                       "Applies to left and right")
        // The page reads the engine's session: with no wide session running it is the stereo pair.
        let engine = try engine(rate: 48_000)
        XCTAssertEqual(engine.eqReachText, "Applies to left and right")
    }
}
