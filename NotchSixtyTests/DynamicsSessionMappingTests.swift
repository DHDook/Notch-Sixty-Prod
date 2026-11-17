import XCTest
@testable import NotchSixty

/// E33 S12 (G22): every Dynamics processor on a 5.1, a 7.1.4 and a Virtual Speakers session lands on the lanes the
/// `DynamicsSessionMapping` table says, and the page's "Acts on" text follows the same table. Real specs, eight rates.
@MainActor
final class DynamicsSessionMappingTests: XCTestCase {
    private func everythingOn() -> DynamicsConfiguration {
        var d = DynamicsConfiguration()
        d.stereoMode = .trueMono
        d.stereoWidener.enabled = true
        d.dcOffsetFilter.enabled = true
        d.infrasonicFilter.enabled = true
        d.mainsNotch.enabled = true
        d.loudnessMatch.enabled = true
        d.loudnessContour.enabled = true
        d.deHarsh.enabled = true
        d.dialogueRelativeLeveler.enabled = true
        d.deEsser.enabled = true
        d.multibandCompressor.enabled = true
        d.compressor.enabled = true
        d.expander.enabled = true
        d.pauseGate.enabled = true
        d.limiter.enabled = true
        return d
    }

    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_433, uid: "map-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "map-out")
        return engine
    }

    private func lanes(_ spec: UnifiedGraphSpec, kind: n60_stage_kind) -> [Int] {
        var found = Set<Int>()
        for stage in spec.stages where stage.kind == kind.rawValue {
            if stage.laneMask != 0 {
                for lane in 0..<64 where stage.laneMask & (UInt64(1) << UInt64(lane)) != 0 { found.insert(lane) }
            } else {
                found.insert(Int(stage.laneA))
                found.insert(Int(stage.laneB))
            }
        }
        return found.sorted()
    }

    func testEveryProcessorLandsOnTheTableLanesAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            try engine.replaceDynamicsConfiguration(everythingOn())
            var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
            let stereo = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
            for (layout, virtual) in [(OutputProgramLayout.fiveOne, false), (.sevenOneFour, false), (.fiveOne, true)] {
                let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
                var configuration = UnifiedGraphTranslator.multichannelConfiguration(
                    sampleRate: rate, programChannels: layout.roles.count, subwoofers: [])
                configuration.orderPolicy = .canonical
                configuration.programDSP = UnifiedGraphProgramDSP(
                    stereo: stereo, shape: shape, eqMode: .linked, virtualSpeakers: virtual)
                let spec = try configuration.makeSpec()
                func table(_ module: ProductionDynamicsModule) -> [Int] {
                    DynamicsSessionMapping.mapping(for: module, shape: shape, virtualSpeakers: virtual).lanes.sorted()
                }
                let context = "\(layout.roles.count) lanes, virtual \(virtual), \(rate)"
                XCTAssertEqual(lanes(spec, kind: N60_STAGE_CLEANUP), table(.dcOffset), "cleanup \(context)")
                XCTAssertEqual(lanes(spec, kind: N60_STAGE_IMAGE), table(.stereoMode), "stereo mode and widener \(context)")
                XCTAssertEqual(lanes(spec, kind: N60_STAGE_LOUDNESS), table(.dialogueLeveler), "loudness group \(context)")
                XCTAssertEqual(lanes(spec, kind: N60_STAGE_DEESS), table(.deHarsh), "de-harsh and de-esser \(context)")
                XCTAssertEqual(lanes(spec, kind: N60_STAGE_MULTIBAND), table(.multiband), "multiband \(context)")
                XCTAssertEqual(lanes(spec, kind: N60_STAGE_COMPRESSOR), table(.compressor), "compressor \(context)")
                XCTAssertEqual(lanes(spec, kind: N60_STAGE_EXPANDER), table(.expander), "expander \(context)")
                XCTAssertEqual(lanes(spec, kind: N60_STAGE_PAUSE_GATE), table(.pauseGate), "pause gate \(context)")
                if !virtual {
                    XCTAssertEqual(lanes(spec, kind: N60_STAGE_PROTECTION).filter { $0 < layout.roles.count }, table(.limiter),
                                   "protection \(context)")
                }
                // The compressor and expander are one linked group that includes the LFE in the detector.
                let lfe = try XCTUnwrap(shape.lfeLane)
                let compressor = DynamicsSessionMapping.mapping(for: .compressor, shape: shape, virtualSpeakers: virtual)
                XCTAssertTrue(compressor.linked)
                XCTAssertTrue(compressor.detectorLanes.contains(lfe))
                // Front-pair processors leave the LFE and every other lane untouched.
                XCTAssertFalse(table(.stereoWidener).contains(lfe))
                XCTAssertEqual(table(.stereoWidener).count, 2)
            }
        }
    }

    func testRefusalAndEQLaneSetRows() throws {
        // A layout with no front pair refuses the front-pair processors with the named reason.
        let noFront = try XCTUnwrap(UnifiedGraphLayoutShape(roles: [.frontCenter, .lowFrequencyEffects]))
        let refused = DynamicsSessionMapping.mapping(for: .stereoWidener, shape: noFront, virtualSpeakers: false)
        XCTAssertEqual(refused.refusal, .noFrontPair)
        XCTAssertTrue(DynamicsSessionMapping.actsOnText(for: .stereoWidener, shape: noFront, virtualSpeakers: false)
            .hasPrefix("Unavailable"))
        // The denoiser follows the EQ lane set: no LFE when linked, pairs only when independent.
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: OutputProgramLayout.fiveOne.roles))
        let linked = DynamicsSessionMapping.mapping(for: .denoiser, shape: shape, virtualSpeakers: false, eqMode: .linked)
        XCTAssertFalse(linked.lanes.contains(try XCTUnwrap(shape.lfeLane)))
        XCTAssertTrue(linked.lanes.contains(try XCTUnwrap(shape.centerLane)))
        let independent = DynamicsSessionMapping.mapping(for: .denoiser, shape: shape, virtualSpeakers: false, eqMode: .independent)
        XCTAssertFalse(independent.lanes.contains(try XCTUnwrap(shape.centerLane)))
    }

    func testActsOnTextFollowsTheTranslatorLaneSets() throws {
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: OutputProgramLayout.fiveOne.roles))
        let stereoShape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: [.frontLeft, .frontRight]))
        for module in ProductionDynamicsModule.allCases {
            for (current, virtual) in [(shape, false), (shape, true), (stereoShape, false)] {
                let mapping = DynamicsSessionMapping.mapping(for: module, shape: current, virtualSpeakers: virtual)
                let text = DynamicsSessionMapping.actsOnText(for: module, shape: current, virtualSpeakers: virtual)
                XCTAssertFalse(text.isEmpty)
                XCTAssertEqual(text.contains("LFE included"), mapping.scope == .everyLane && current.lfeLane != nil && !(current.laneCount == 2),
                               "\(module) \(text)")
                XCTAssertEqual(text.contains("linked"), mapping.linked, "\(module) \(text)")
                XCTAssertEqual(text.hasPrefix("Front pair"), mapping.scope == .frontPair && current.laneCount > 2, "\(module) \(text)")
            }
        }
    }
}
