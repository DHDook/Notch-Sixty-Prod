import XCTest
@testable import NotchSixty

/// E25 S8c: a stored arrangement is applied on profile load and launch restore (not only by the wizard), and the
/// stereo session renders the applied alignment at the lowest and highest device rates.
@MainActor
final class StoredArrangementApplyTests: XCTestCase {
    private let uid = OfflineSetupRig.outputUID
    private func ep(_ i: UInt32) -> PhysicalOutputEndpoint { PhysicalOutputEndpoint(deviceUID: uid, channelIndex: i) }

    private func monoBass(_ alignment: StereoBassAlignment) -> SystemArrangement {
        var a = SystemArrangement(
            outputs: SystemOutputs(deviceUID: uid, detectedChannelCount: 6, channelsInUse: 2),
            layout: .stereo, bass: .dspMonoToMains, subwooferCount: 0,
            speakers: [ArrangedSpeaker(role: .frontLeft, feed: .direct(ep(0))),
                       ArrangedSpeaker(role: .frontRight, feed: .direct(ep(1)))])
        a.stereoAlignment = alignment
        return a
    }

    private func fiveOne(source: String) -> SystemArrangement {
        let roles: [OutputProgramRole] = [.frontLeft, .frontRight, .frontCenter, .sideLeft, .sideRight, .lowFrequencyEffects]
        var a = SystemArrangement(
            outputs: SystemOutputs(deviceUID: uid, detectedChannelCount: 6, channelsInUse: 6),
            layout: .fiveOne, bass: .fullRange, subwooferCount: 0,
            speakers: roles.enumerated().map { ArrangedSpeaker(role: $0.element, feed: .direct(ep(UInt32($0.offset)))) })
        a.foldDown = ProgramFoldDown(programSourceDeviceUID: source, lfe: .foldPlus10dBWithLimiter, headroom: .none)
        return a
    }

    private func rig(flag: Bool) throws -> OfflineSetupRig {
        let rig = try OfflineSetupRig(rate: 48_000, arrangementEnabled: flag)
        rig.profiles.arrangementFlagEnabled = { flag }
        return rig
    }

    func testProfileLoadAppliesStoredAlignmentLikeTheWizard() throws {
        let alignment = StereoBassAlignment(monoBassFilter: MonoBassFilter(family: .bessel, slopeDBPerOctave: 36))
        let arrangement = monoBass(alignment)
        let rig = try rig(flag: true)
        defer { rig.tearDown() }
        try rig.profiles.replaceSelectedSystemArrangement(arrangement)
        XCTAssertNil(rig.engine.appliedStereoAlignment)
        try rig.profiles.applySelectedLayersNow()
        let compiled = try SystemArrangementCompiler.compile(arrangement, preserving: nil).get()
        XCTAssertEqual(rig.engine.appliedStereoAlignment, compiled.stereoAlignment)
        XCTAssertNotNil(rig.engine.appliedStereoAlignment?.monoBassFilter)
        // Launch restore takes the same path.
        try rig.engine.applyStereoAlignment(nil)
        let relaunched = ProductProfileController(
            engine: rig.engine, storageURL: rig.root.appendingPathComponent("profiles.json"))
        relaunched.arrangementFlagEnabled = { true }
        relaunched.restoreSelectedLayers()
        XCTAssertEqual(rig.engine.appliedStereoAlignment, compiled.stereoAlignment)
    }

    func testProfileLoadAppliesStoredFoldDown() throws {
        let rig = try rig(flag: true)
        defer { rig.tearDown() }
        let arrangement = fiveOne(source: "receiver-hdmi")
        try rig.profiles.replaceSelectedSystemArrangement(arrangement)
        try rig.profiles.applySelectedLayersNow()
        let plan = try XCTUnwrap(rig.engine.appliedProgramFoldPlan)
        XCTAssertEqual(plan.sourceUID, "receiver-hdmi")
        XCTAssertEqual(plan.layout, .fiveOne)
        // Switching to a profile with no fold clears it.
        try rig.profiles.replaceSelectedSystemArrangement(monoBass(StereoBassAlignment()))
        try rig.profiles.applySelectedLayersNow()
        XCTAssertNil(rig.engine.appliedProgramFoldPlan)
    }

    func testFlagOffLeavesTheEngineAlone() throws {
        let rig = try rig(flag: false)
        defer { rig.tearDown() }
        try rig.profiles.replaceSelectedSystemArrangement(fiveOne(source: "receiver-hdmi"))
        try rig.profiles.applySelectedLayersNow()
        XCTAssertNil(rig.engine.appliedProgramFoldPlan)
        XCTAssertNil(rig.engine.appliedStereoAlignment)
    }

    /// The alignment the UI model produced is what the stereo session renders: identical to the offline graph built
    /// from the compiled arrangement, and the mono-bass filter is audibly doing something at the low corner.
    func testRenderedMonoBassRunMatchesTheOfflineGraphAtLowAndHighRates() throws {
        let block = 512
        for rate in [44_100.0, 384_000.0] {
            let rig = try OfflineSetupRig(rate: rate, arrangementEnabled: true)
            defer { rig.tearDown() }
            rig.profiles.arrangementFlagEnabled = { true }
            rig.model.begin()
            rig.model.chooseOutput(uid: OfflineSetupRig.outputUID)
            rig.model.chooseChannelCount(2)
            rig.model.chooseBass(.dspMonoToMains)
            var base = try XCTUnwrap(rig.model.arrangement)
            base.stereoAlignment = StereoBassAlignment(monoBassFilter: MonoBassFilter(family: .bessel, slopeDBPerOctave: 36))
            try rig.profiles.replaceSelectedSystemArrangement(base)
            try rig.profiles.applySelectedLayersNow()
            let applied = try XCTUnwrap(rig.engine.appliedStereoAlignment, "\(rate)")
            let compiled = try SystemArrangementCompiler.compile(base, preserving: nil).get()
            XCTAssertEqual(applied, compiled.stereoAlignment, "\(rate)")

            func render(_ alignment: StereoBassAlignment) throws -> [[Float]] {
                var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
                XCTAssertTrue(N60CrossoverSnapshotMake(
                    rate, 90, N60CrossoverTopologyLinkwitzRiley24, N60CrossoverMonitorModeRecombined, 1, false, true, &snapshot.crossover))
                let config = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(
                    snapshot: &snapshot, sampleRate: rate, alignment: alignment))
                let host = try UnifiedGraphHost(spec: try config.makeSpec())
                defer { host.release() }
                let n = Int(rate * 0.4) / block * block
                let tone = (0..<n).map { Float(0.25 * sin(2 * .pi * 45 * Double($0) / rate)) }
                let input = [tone, tone.map { -$0 }]   // out of phase: mono bass cancels the low band
                var out: [[Float]] = [[], []]
                var p = 0
                while p + block <= n {
                    let r = try host.processOffline(input: input.map { Array($0[p..<p + block]) }, frames: block)
                    out[0] += r[0]; out[1] += r[1]; p += block
                }
                return out
            }
            let fromEngine = try render(applied)
            let offline = try render(try XCTUnwrap(compiled.stereoAlignment))
            XCTAssertEqual(fromEngine, offline, "\(rate)")
            let tail = fromEngine[0].count * 3 / 4
            let rms = sqrt(fromEngine[0][tail...].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(fromEngine[0].count - tail))
            XCTAssertLessThan(rms, 0.25 / 2.0.squareRoot() * 0.5, "mono bass attenuates the differential low band at \(rate)")
        }
    }
}
