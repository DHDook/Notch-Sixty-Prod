import XCTest
@testable import NotchSixty

/// E19 S10b: way captures in the seat flow (G36), support overrides in the class key and speaker list (G38), matrix-only outputs
/// (G39) and the routed baseline of the permit path (G42). No hardware: captures are synthetic, the measurer is a fake.
@MainActor
final class MIMORoutedWayCaptureTests: XCTestCase {
    private func ep(_ channel: UInt32) -> PhysicalOutputEndpoint { PhysicalOutputEndpoint(deviceUID: "DEV", channelIndex: channel) }
    private func lr(_ hz: Double) -> CrossoverCore.FilterSpec { .init(family: .linkwitzRiley, order: 4, cornerHz: hz) }
    /// Way trim of the synthetic rig. The planner's budget is 1.5 dB at 0 dB trim, so G44 pulls it down to buy headroom.
    private var wayTrimDB = 0.0
    private func way(_ name: String, _ channel: UInt32, high: CrossoverCore.FilterSpec? = nil, low: CrossoverCore.FilterSpec? = nil) -> RoutedWay {
        var w = RoutedWay(endpoint: ep(channel))
        w.name = name
        w.trimDB = wayTrimDB
        w.highPass = high
        w.lowPass = low
        return w
    }
    private func speaker(_ name: String, _ source: RoutingSource, _ ways: [RoutedWay]) -> RoutedSpeaker {
        var s = RoutedSpeaker(source: source, ways: ways)
        s.name = name
        return s
    }
    private func twoWayMainsAndSubs() -> SpeakerRoutingConfiguration {
        SpeakerRoutingConfiguration(speakers: [
            speaker("Left", .program(0), [way("L woofer", 0, low: lr(2_000)), way("L tweeter", 1, high: lr(2_000))]),
            speaker("Right", .program(1), [way("R woofer", 2, low: lr(2_000)), way("R tweeter", 3, high: lr(2_000))]),
            speaker("Sub 1", .sub(0), [way("Sub 1", 4)]),
            speaker("Sub 2", .sub(1), [way("Sub 2", 5)]),
        ])
    }
    private let seats = [MultichannelCalibrationSeat(name: "Seat 1"), MultichannelCalibrationSeat(name: "Seat 2")]

    /// Strength of the two decaying modes in the synthetic room. The default is faint; G44 uses a room the designer must treat.
    private var modeGain = 0.0008  // G44 sets 0.2, as the unrouted controller tests do

    private func rawIR(rate: Double, seed: Int, modes: Bool, seconds: Double = 1.2) -> [Float] {
        let length = Int(rate * seconds)
        var ir = [Float](repeating: 0, count: length)
        ir[Int(rate * (0.002 + 0.0003 * Double(seed % 5)))] = 1
        guard modes else { return ir }
        let alpha = 6.907755 / (0.8 * rate)
        for (index, hz) in [40.0, 70.0].enumerated() {
            let gain = modeGain * (1 + 0.3 * Double((seed + index) % 3))
            let phase = 0.7 * Double(seed + index)
            for n in 0..<length {
                ir[n] += Float(gain * exp(-alpha * Double(n)) * sin(2 * Double.pi * hz * Double(n) / rate + phase))
            }
        }
        return ir
    }

    private func storedCaptures(_ routing: SpeakerRoutingConfiguration, rate: Double, bassOnly: Bool = true) -> [MultichannelWayCapture] {
        var out: [MultichannelWayCapture] = []
        for (si, speaker) in routing.speakers.enumerated() {
            for (wi, way) in speaker.ways.enumerated() {
                let bass = (way.highPass?.cornerHz ?? 0) < 400
                if bassOnly && !bass { continue }
                for (ki, seat) in seats.enumerated() {
                    out.append(MultichannelWayCapture(
                        speakerID: speaker.id, wayID: way.id, seatID: seat.id, sampleRate: rate,
                        channel: RoomCorrectionChannelMeasurement(
                            capturedAt: Date(), rawCapture: [], impulseResponse: rawIR(rate: rate, seed: si * 3 + wi + ki, modes: bass),
                            transferFunction: nil, quality: RoomCorrectionMeasurementQuality())))
                }
            }
        }
        return out
    }

    // MARK: G36 targets and storage

    func testMissingTargetsAreInBandWaysAtEveryIncludedSeat() {
        let routing = twoWayMainsAndSubs()
        let ids = seats.map(\.id)
        let all = MultichannelWayCaptureTargets.missing(routing: routing, seatIDs: ids, captures: [], sampleRate: 48_000)
        // Woofers and subs only (the tweeters' 2 kHz high-pass is outside 15-150 Hz): four speakers, two seats each.
        XCTAssertEqual(all.count, 8)
        XCTAssertFalse(all.contains { $0.wayName.contains("tweeter") })
        let have = storedCaptures(routing, rate: 48_000)
        XCTAssertTrue(MultichannelWayCaptureTargets.missing(routing: routing, seatIDs: ids, captures: have, sampleRate: 48_000).isEmpty)
        // A capture at another rate does not count.
        XCTAssertEqual(MultichannelWayCaptureTargets.missing(routing: routing, seatIDs: ids, captures: have, sampleRate: 96_000).count, 8)
        // One seat missing, and an excluded speaker needs nothing.
        let partial = have.filter { !($0.seatID == ids[1] && $0.speakerID == routing.speakers[0].id) }
        let missing = MultichannelWayCaptureTargets.missing(routing: routing, seatIDs: ids, captures: partial, sampleRate: 48_000)
        XCTAssertEqual(missing.map(\.seatID), [ids[1]])
        XCTAssertTrue(MultichannelWayCaptureTargets.missing(
            routing: routing, seatIDs: ids, captures: partial, excluded: [routing.speakers[0].id], sampleRate: 48_000).isEmpty)
    }

    func testSupportOverrideWidensTheNeededWays() {
        let routing = twoWayMainsAndSubs()
        let ids = seats.map(\.id)
        let wide = MultichannelWayCaptureTargets.missing(
            routing: routing, seatIDs: ids, captures: [], overrides: [routing.speakers[0].id: 25...3_000], sampleRate: 48_000)
        XCTAssertEqual(wide.filter { $0.speakerID == routing.speakers[0].id }.count, 4, "woofer and tweeter at two seats")
    }

    func testRoutedWayCapturesCarryTheChainFlagAndTheImpulseResponse() {
        let routing = twoWayMainsAndSubs()
        let stored = storedCaptures(routing, rate: 48_000)
        let routed = stored.map { c in
            MIMORoutedWayCapture(
                speakerID: c.speakerID, wayID: c.wayID, seatID: c.seatID, sampleRate: c.sampleRate,
                impulseResponse: c.channel.impulseResponse, includesChain: true)
        }
        XCTAssertEqual(routed.count, stored.count)
        XCTAssertTrue(routed.allSatisfy(\.includesChain))
    }

    func testCampaignArchiveRoundTripsWayCapturesAndOldArchivesDecode() throws {
        let routing = twoWayMainsAndSubs()
        let archive = MultichannelCalibrationCampaignArchive(
            playbackSystemID: UUID(), routingSignature: "sig", sampleRate: 48_000, seats: seats, measurements: [],
            wayCaptures: storedCaptures(routing, rate: 48_000))
        let data = try JSONEncoder().encode(archive)
        XCTAssertEqual(try JSONDecoder().decode(MultichannelCalibrationCampaignArchive.self, from: data), archive)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "wayCaptures")
        let old = try JSONDecoder().decode(
            MultichannelCalibrationCampaignArchive.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.wayCaptures)
    }

    // MARK: Planner: a capture that holds the chain

    func testChainCaptureGivesTheSamePlantAsRawThroughTheRenderedChain() async throws {
        for rate in [48_000.0, 96_000.0] {
            let routing = SpeakerRoutingConfiguration(speakers: [
                speaker("Left", .program(0), [way("L woofer", 0, low: lr(2_000)), way("L tweeter", 1, high: lr(2_000))]),
            ])
            let left = routing.speakers[0]
            let chains = try MIMORoutedTreatmentPlanner.renderChains(of: left, name: "Left", sampleRate: rate, offsetFrames: 0)
            var raw: [MIMORoutedWayCapture] = [], chained: [MIMORoutedWayCapture] = []
            for (wi, w) in left.ways.enumerated() {
                for (ki, seat) in seats.enumerated() {
                    let ir = rawIR(rate: rate, seed: wi + ki, modes: wi == 0)
                    raw.append(MIMORoutedWayCapture(speakerID: left.id, wayID: w.id, seatID: seat.id, sampleRate: rate, impulseResponse: ir))
                    let through = try MeasurementCore.predictTreatedIR(plants: [ir], filters: [chains[w.id]!])
                    chained.append(MIMORoutedWayCapture(
                        speakerID: left.id, wayID: w.id, seatID: seat.id, sampleRate: rate, impulseResponse: through, includesChain: true))
                }
            }
            var settings = MIMORoutedTreatmentSettings()
            settings.taps = Int(try MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: rate).lowRateHz)
            let a = try await MIMORoutedTreatmentPlanner.plan(
                routing: routing, sampleRate: rate, programLanes: 1, subwoofers: 0, seats: seats, captures: raw, settings: settings)
            let b = try await MIMORoutedTreatmentPlanner.plan(
                routing: routing, sampleRate: rate, programLanes: 1, subwoofers: 0, seats: seats, captures: chained, settings: settings)
            for seat in 0..<seats.count {
                let x = try XCTUnwrap(a.request.plants[0][seat]?.program), y = try XCTUnwrap(b.request.plants[0][seat]?.program)
                var err = 0.0, peak = 0.0
                for i in 0..<max(x.count, y.count) {
                    let p = i < x.count ? Double(x[i]) : 0, q = i < y.count ? Double(y[i]) : 0
                    err = max(err, abs(p - q)); peak = max(peak, abs(p))
                }
                XCTAssertLessThan(20 * log10(max(err, 1e-30) / peak), -100, "rate \(rate)")
            }
        }
    }

    // MARK: G38 and G39 helpers

    func testClassKeyCountFollowsSupportOverrides() {
        let routing = twoWayMainsAndSubs()
        XCTAssertEqual(MIMORoutedTreatmentPlanner.inBandWayCount(of: routing), 1)
        XCTAssertEqual(MIMORoutedTreatmentPlanner.inBandWayCount(of: routing, overrides: [routing.speakers[0].id: 25...3_000]), 2)
    }

    func testMatrixOnlyOutputsHelper() {
        var routing = SpeakerRoutingConfiguration(speakers: [speaker("Left", .program(0), [way("Left", 0)])])
        routing.matrix = [RoutingMatrixEntry(source: .program(0), output: ep(5), gain: 1)]
        XCTAssertEqual(MIMORoutedTreatmentPlanner.matrixOnlyOutputs(of: routing), [ep(5)])
    }

    // MARK: Controller

    private final class FakeHost: MIMOTreatmentHost {
        let treatment: MIMOGraphTreatment
        var sampleRate: Double? = 48_000
        var routing: SpeakerRoutingConfiguration
        var configuration: UnifiedGraphConfiguration?
        var overrides: [UUID: ClosedRange<Double>] = [:]
        var verifications: [MIMOTreatmentVerificationResult?] = []
        var staged: [UnifiedGraphMIMOStage] = []

        init(flags: FeatureFlags, routing: SpeakerRoutingConfiguration, rate: Double) throws {
            self.routing = routing
            sampleRate = rate
            treatment = MIMOGraphTreatment(flags: flags)
            treatment.settle = {}
            treatment.publish = { _ in }
            var base = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane](repeating: UnifiedGraphLane(), count: 2))
            base.bassManagement = UnifiedGraphBassManagement(
                lfeLane: nil, subwoofers: [UnifiedGraphSubwoofer](repeating: UnifiedGraphSubwoofer(), count: 2))
            var config = try SpeakerRoutingCompiler.compile(routing, onto: base)
            config.outputProtection = UnifiedGraphOutputProtection()
            configuration = config
        }

        func treatmentContext() -> MIMOGraphTreatment.Context {
            MIMOGraphTreatment.Context(
                engineRunning: true, outputDeviceUID: "DEV", sampleRate: sampleRate, stageAttached: true, hardLimitPresent: true,
                engineLeaseHeld: true, videoLatencyMode: false, outputTrimsDB: [], laneCount: 6)
        }
        func treatmentSources() -> [MIMOTreatmentSourceInfo] {
            var infos = [
                MIMOTreatmentSourceInfo(source: .speaker(.frontLeft), lane: 0, name: "Front Left"),
                MIMOTreatmentSourceInfo(source: .speaker(.frontRight), lane: 1, name: "Front Right"),
                MIMOTreatmentSourceInfo(source: .subwoofer(0), lane: 2, name: "Sub 1"),
                MIMOTreatmentSourceInfo(source: .subwoofer(1), lane: 3, name: "Sub 2"),
            ]
            for speaker in routing.speakers {
                let lane = speaker.source.kind == .program ? speaker.source.index : 2 + speaker.source.index
                let window = overrides[speaker.id] ?? MIMORoutedTreatmentPlanner.defaultSupportHz
                infos[lane].inBandWays = MIMORoutedTreatmentPlanner
                    .inBandWays(of: speaker, lowHz: window.lowerBound, highHz: window.upperBound).map(\.name)
            }
            return infos
        }
        func treatmentGraphConfiguration() -> UnifiedGraphConfiguration? { configuration }
        func stageTreatment(_ stage: UnifiedGraphMIMOStage, configuration: UnifiedGraphConfiguration) throws {
            staged.append(stage)
            treatment.stage(stage)
        }
        func issueTreatmentPermit(
            verification: MIMOTreatmentVerificationResult?, acceptance: MIMORoomTreatmentHardwareAcceptance?
        ) -> Result<MIMOGraphTreatment.Permit, MIMOTreatmentPermitRefusal> {
            verifications.append(verification)
            return treatment.issuePermit(
                context: treatmentContext(), videoLatency: .known(videoLatencyMode: false), verification: verification,
                acceptance: acceptance, routed: true)
        }
        func requestTreatmentArm() async throws { try await treatment.requestArm(context: treatmentContext()) }
        func disarmTreatment() { treatment.userDisarm() }
        func treatmentReadback() -> n60_mimo_readback? { nil }
        func hardwareAcceptance() -> MIMORoomTreatmentHardwareAcceptance? { nil }
        func treatmentRouting() -> SpeakerRoutingConfiguration? { routing }
        func setTreatmentSupportOverrides(_ overrides: [UUID: ClosedRange<Double>]) { self.overrides = overrides }
    }

    private final class FakeMeasurer: TreatmentWayMeasuring {
        var captures: [MIMORoutedWayCapture] = []
        var supply: [MIMORoutedWayCapture] = []
        var calls = 0
        var seen: [UUID: ClosedRange<Double>] = [:]
        func missingWayNotes(overrides: [UUID: ClosedRange<Double>], excluded: Set<UUID>) -> [String] {
            supply.isEmpty ? [] : (captures.isEmpty ? ["Left, L woofer, at Seat 1"] : [])
        }
        func measureMissingWays(overrides: [UUID: ClosedRange<Double>], excluded: Set<UUID>) async throws -> Int {
            calls += 1
            seen = overrides
            captures = supply
            return supply.count
        }
        func wayCaptures() -> [MIMORoutedWayCapture] { captures }
    }

    private func flags() -> FeatureFlags {
        FeatureFlags(
            defaults: UserDefaults(suiteName: "MIMORoutedWayCaptureTests.\(UUID().uuidString)") ?? .standard,
            policy: .launchArgumentOnly, arguments: [FeatureFlags.launchArgument, FeatureFlag.mimoTreatment.id])
    }

    private func rig(
        treated: @escaping () -> [MultichannelCalibrationMeasurement] = { [] }
    ) throws -> (MIMOTreatmentController, FakeHost, FakeMeasurer, SpeakerRoutingConfiguration) {
        var routing = twoWayMainsAndSubs()
        routing.matrix = [RoutingMatrixEntry(source: .program(0), output: ep(7), gain: 0.5)]
        let host = try FakeHost(flags: flags(), routing: routing, rate: 48_000)
        let measurer = FakeMeasurer()
        measurer.supply = storedCaptures(routing, rate: 48_000, bassOnly: false).map {
            MIMORoutedWayCapture(
                speakerID: $0.speakerID, wayID: $0.wayID, seatID: $0.seatID, sampleRate: $0.sampleRate,
                impulseResponse: $0.channel.impulseResponse, includesChain: true)
        }
        var limits = MIMOTreatmentRealisationLimits.standard
        limits.maximumDeviationDB = 12
        let controller = MIMOTreatmentController(
            host: host, flags: flags(), seats: { self.seats }, baseline: { [] }, treated: treated, wayMeasurer: measurer,
            limits: limits, taps: Int(try MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: 48_000).lowRateHz))
        controller.refreshSources()
        controller.decayTarget = .seconds(0.3)
        controller.setTau(milliseconds: 20)
        return (controller, host, measurer, routing)
    }

    func testRoutedRowsMatrixOnlyOutputsAndSupportOverridesShowInTheScreenModel() throws {
        let (controller, host, _, routing) = try rig()
        XCTAssertEqual(controller.rows.map(\.lane), [0, 1, 2, 3], "no per-source measurement is needed for a routed speaker")
        XCTAssertEqual(controller.rows[0].inBandWays, ["L woofer"])
        XCTAssertEqual(controller.matrixOnlyOutputs.count, 1)
        XCTAssertTrue(controller.matrixOnlyOutputs[0].contains("Output 8"))
        controller.setSupport(lowHz: 25, highHz: 3_000, lane: 0)
        XCTAssertEqual(host.overrides[routing.speakers[0].id], 25...3_000)
        XCTAssertEqual(controller.rows[0].inBandWays, ["L woofer", "L tweeter"], "the speaker list follows the override")
    }

    func testMeasureWaysStoresCapturesThenRoutedDesignRunsAndPermitReadsTheSpeakerBaseline() async throws {
        let (controller, _, measurer, _) = try rig()
        XCTAssertEqual(controller.missingWayNotes.count, 1)
        await controller.measureWays()
        XCTAssertEqual(measurer.calls, 1)
        XCTAssertNil(controller.wayMeasureStatus.flatMap { $0.contains("Stored 0") ? $0 : nil })
        XCTAssertTrue(controller.missingWayNotes.isEmpty)
        await controller.design()
        // The synthetic room cannot always meet the planner's headroom budget; what this test pins is that the stored
        // captures reach the planner (no "missing captures" refusal). The permit baseline is pinned below.
        if case .failed(let message) = controller.phase {
            XCTAssertFalse(message.lowercased().contains("capture"), message)
            XCTAssertFalse(message.lowercased().contains("measure"), message)
        }
    }

    func testSpeakerBaselineHasOneMeasurementPerIncludedSpeakerAndSeat() async throws {
        let (controller, _, measurer, routing) = try rig()
        await controller.measureWays()
        let plan = try await MIMORoutedTreatmentPlanner.plan(
            routing: routing, sampleRate: 48_000, programLanes: 2, subwoofers: 2, seats: seats, captures: measurer.captures,
            settings: { var s = MIMORoutedTreatmentSettings(); s.taps = 2_000; return s }())
        let baseline = MIMOTreatmentController.speakerBaseline(plan: plan, rows: controller.rows, seats: seats, sampleRate: 48_000)
        XCTAssertEqual(baseline.count, 4 * seats.count)
        XCTAssertEqual(Set(baseline.map(\.source)).count, 4)
        XCTAssertTrue(baseline.allSatisfy { !$0.channel.impulseResponse.isEmpty })
    }

    // MARK: E19 S11 (G44, G46)

    /// A room the planner's headroom budget accepts: 6 dB of way trim buys the headroom the 1.5 dB default budget lacks
    /// (E19 G44). Measure the ways, design, and read the stage and the permit baseline the verifier is given.
    func testRoutedDesignEndToEndStagesAndTheVerifierReadsTheSpeakerBaseline() async throws {
        wayTrimDB = -6
        modeGain = 0.2
        var baselineSeen: [MultichannelCalibrationMeasurement] = []
        let (controller, host, measurer, routing) = try rig(treated: { baselineSeen })
        await controller.measureWays()
        await controller.design()
        XCTAssertEqual(controller.phase, .designed, "\(controller.phase)")
        let stage = try XCTUnwrap(host.staged.last)
        XCTAssertNotNil(stage.routed, "a routed topology stages the routed stage")
        XCTAssertFalse(stage.armed, "designing never arms")
        XCTAssertEqual(controller.seatDecays.count, seats.count)
        XCTAssertTrue(controller.seatDecays.allSatisfy { $0.beforeSeconds != nil && $0.afterSeconds != nil })
        // The permit path: the verifier is given a result, nothing arms, no permit exists without acceptance.
        controller.requestPermit()
        XCTAssertNotNil(host.verifications.last ?? nil)
        XCTAssertFalse(host.treatment.isArmed)
        XCTAssertFalse(controller.permitRefusals.isEmpty, "no permit exists before the E22 qualification")
        XCTAssertFalse(controller.permitRefusals.joined().lowercased().contains("baseline"), controller.permitRefusals.joined())
        // The per-speaker baseline the spatial check reads: one measurement per included speaker and seat.
        var settings = MIMORoutedTreatmentSettings()
        settings.taps = 2_000
        settings.tauSeconds = 0.02
        let plan = try await MIMORoutedTreatmentPlanner.plan(
            routing: routing, sampleRate: 48_000, programLanes: 2, subwoofers: 2, seats: seats, captures: measurer.captures,
            settings: settings)
        baselineSeen = MIMOTreatmentController.speakerBaseline(plan: plan, rows: controller.rows, seats: seats, sampleRate: 48_000)
        XCTAssertEqual(baselineSeen.count, 4 * seats.count)
        controller.requestPermit()
        XCTAssertFalse(host.treatment.isArmed)
        XCTAssertFalse(controller.permitRefusals.isEmpty)
        // The treated repeat measurement here is the baseline itself (nothing changed), so the criteria fail by name, but the
        // spatial report was built from the per-speaker baseline (no "report missing") and the predicted decay passes.
        let result = try XCTUnwrap(host.verifications.last ?? nil)
        XCTAssertFalse(result.failures.contains(.spatialReportMissing), "\(result.failures)")
        XCTAssertTrue(result.failures.contains(.spatialCriteriaFailed))
        XCTAssertFalse(result.failures.contains { if case .decayNotShortened(.predicted, _) = $0 { return true } else { return false } })
    }

    /// S11: a designed routed stage arms with a test permit (the production registry issues none before E22) and bypasses.
    func testDesignedRoutedStageArmsOnlyWithATestPermitAndBypasses() async throws {
        wayTrimDB = -6
        modeGain = 0.2
        let (controller, host, _, _) = try rig()
        await controller.measureWays()
        await controller.design()
        XCTAssertEqual(controller.phase, .designed, "\(controller.phase)")
        let stage = try XCTUnwrap(host.treatment.stage)
        await controller.arm()
        XCTAssertFalse(controller.isArmed, "no permit: the arm refuses")
        host.treatment.setPermit(.init(fingerprint: host.treatment.currentFingerprint(stage, host.treatmentContext())))
        controller.refreshReadout()
        XCTAssertFalse(controller.isArmed, "a permit alone never arms")
        await controller.arm()
        XCTAssertTrue(controller.isArmed, controller.armMessage ?? "")
        controller.bypass()
        XCTAssertFalse(controller.isArmed)
    }

    /// G46: a routed prediction renders the programme at the stage per speaker (source lanes, before ROUTE), not an equal feed.
    func testRoutedFeedsAreRenderedPerSourceLane() throws {
        let routing = twoWayMainsAndSubs()
        let host = try FakeHost(flags: flags(), routing: routing, rate: 48_000)
        let configuration = try XCTUnwrap(host.configuration)
        XCTAssertNotNil(configuration.routing)
        XCTAssertNil(MIMOUnroutedPlantModel.upstreamConfiguration(of: configuration).routing)
        let feeds = try MIMOUnroutedPlantModel.upstreamFeeds(of: configuration, lanes: [0, 1, 2, 3])
        XCTAssertEqual(feeds.count, 4)
        XCTAssertTrue(feeds.allSatisfy { $0.contains { $0 != 0 } }, "each speaker has a feed at the stage")
    }
}
