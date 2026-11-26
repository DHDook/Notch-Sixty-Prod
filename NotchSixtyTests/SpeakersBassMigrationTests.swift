import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E12 S16b (G16, G118, G119): the older Crossover Design and Sub Phase Alignment cards are retired, what they stored is
/// carried to the routing matrix or the arrangement, the sound does not move at the eight standard rates, and the
/// distances and levels table has per-driver rows.
@MainActor
final class SpeakersBassMigrationTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512
    private let flags = FeatureFlags()

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    // MARK: Fixtures

    private func logical(_ topology: CrossoverTopology, hz: Double = 90) -> PlaybackSystemState {
        var state = PlaybackSystemState()
        state.associatedOutputUID = "dev"
        state.bassManagement.enabled = true
        state.bassManagement.frequencyHz = hz
        state.bassManagement.topology = topology
        return state
    }

    private func physical(_ mode: SpeakerCrossoverMode) -> PlaybackSystemState {
        let buses: [SpeakerOutputBus] = mode == .mainsSub ? [.leftHigh, .rightHigh, .subMono]
            : [.leftLow, .rightLow, .leftHigh, .rightHigh]
        var state = PlaybackSystemState()
        state.bassManagement.enabled = true
        state.bassManagement.physicalOutputMode = mode
        state.bassManagement.frequencyHz = mode == .mainsSub ? 80 : 400
        state.outputRouting = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: buses.enumerated().map { index, bus in
                SpeakerOutputRoute(
                    name: bus.displayName, bus: bus,
                    destination: PhysicalOutputEndpoint(deviceUID: "dev", channelIndex: UInt32(index)))
            })
        return state
    }

    // MARK: Where the settings go

    func testLogicalCrossoverIsCarriedToTheArrangement() {
        for topology in CrossoverTopology.allCases {
            XCTAssertEqual(SpeakersBassMigration.outcome(for: logical(topology)), .arrangement)
        }
        XCTAssertEqual(SpeakersBassMigration.outcome(for: PlaybackSystemState()), .nothingToCarry)
    }

    func testPhysicalCrossoverIsCarriedToTheMatrixWithSubPhaseAndPolarity() throws {
        for mode in SpeakerCrossoverMode.allCases {
            var state = physical(mode)
            state.bassManagement.subPolarityInverted = true
            state.bassManagement.subPhaseAlignmentEnabled = true
            state.bassManagement.subPhaseAlignmentFrequencyHz = 60
            XCTAssertEqual(SpeakersBassMigration.outcome(for: state), .matrix, "\(mode)")
            let migrated = state.migratingSpeakerRouting(enabled: true)
            XCTAssertNotNil(migrated.speakerRouting, "\(mode)")
            XCTAssertEqual(SpeakersBassMigration.outcome(for: migrated), .matrix, "\(mode) after load")
        }
    }

    func testWhatCannotBeCarriedKeepsPlayingAndSaysWhy() {
        var state = physical(.biAmp)
        var drivers = SpeakerDriverProcessingConfiguration(buses: [
            SpeakerDriverBusProcessingConfiguration(
                bus: .leftLow, enabled: true, limiterEnabled: true, limiterThresholdDBFS: -25),
        ])
        drivers.buses[0].limiterEnabled = true
        state.speakerDriverProcessing = drivers
        guard case .keepsPlaying(let reason) = SpeakersBassMigration.outcome(for: state) else {
            return XCTFail("a limiter below the routing floor has no matrix equivalent")
        }
        XCTAssertFalse(reason.isEmpty)
        let page = SpeakersPageModel.make(
            matrixEnabled: false, bass: state.bassManagement, legacyRoutingReason: nil, carry: .keepsPlaying(reason))
        let summary = page.legacyBassSummary ?? ""
        XCTAssertTrue(summary.contains("400 Hz"))
        XCTAssertTrue(summary.contains(reason))

        var phase = physical(.mainsSub)
        phase.outputRouting?.enabled = false
        phase.bassManagement.subPhaseAlignmentEnabled = true
        guard case .keepsPlaying = SpeakersBassMigration.outcome(for: phase) else {
            return XCTFail("a sub phase all-pass with routing off cannot be dropped silently")
        }
    }

    func testCarryStoresTheArrangementOnceAndLeavesLegacyFieldsAlone() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        try rig.profiles.replaceSelectedSystemBassManagement(logical(.linkwitzRiley48, hz: 110).bassManagement)
        let before = try XCTUnwrap(rig.profiles.selectedSystemProfile?.state)
        XCTAssertNil(before.systemArrangement)
        XCTAssertEqual(try SpeakersBassMigration.carry(profiles: rig.profiles, detectedChannelCount: 6), .arrangement)
        let after = try XCTUnwrap(rig.profiles.selectedSystemProfile?.state)
        XCTAssertEqual(after.systemArrangement?.bass, .dspMonoToMains)
        XCTAssertNil(after.systemArrangement?.stereoAlignment?.monoBassFilter, "no override: LR 24 and 48 are the kernel's own")
        XCTAssertEqual(after.bassManagement, before.bassManagement)
        // Idempotent.
        XCTAssertEqual(try SpeakersBassMigration.carry(profiles: rig.profiles, detectedChannelCount: 6), .arrangement)
        XCTAssertEqual(rig.profiles.selectedSystemProfile?.state.systemArrangement, after.systemArrangement)
        // The arrangement editor reads the stored frequency and slope back.
        let editor = SpeakersArrangementEditorModel(engine: rig.engine, profiles: rig.profiles)
        XCTAssertEqual(editor.topologyPreset.crossoverHz, 110)
        XCTAssertEqual(editor.topologyPreset.slope, .linkwitzRiley48)
    }

    func testSlopeEditedInTheEditorReachesTheStoredBassSettings() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        let editor = SpeakersArrangementEditorModel(engine: rig.engine, profiles: rig.profiles)
        editor.chooseBass(.dspMonoToMains)
        editor.topologyPreset.slope = .linkwitzRiley48
        editor.topologyPreset.crossoverHz = 120
        let bass = try XCTUnwrap(rig.profiles.selectedSystemProfile?.state.bassManagement)
        XCTAssertEqual(bass.topology, .linkwitzRiley48)
        XCTAssertEqual(bass.frequencyHz, 120)
        XCTAssertEqual(rig.engine.bassManagementConfiguration.topology, .linkwitzRiley48)
    }

    // MARK: Null test at the eight standard rates

    private func snapshot(rate: Double, hz: Double, topology: CrossoverTopology) -> N60DSPGraphSnapshot {
        var s = N60DSPGraphSnapshotMakeUnity(rate)
        XCTAssertTrue(N60CrossoverSnapshotMake(
            rate, hz, topology.cType, N60CrossoverMonitorModeRecombined, 1, false, true, &s.crossover))
        return s
    }

    private func render(_ configuration: UnifiedGraphConfiguration, _ input: [[Float]]) throws -> [[Float]] {
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        defer { host.release() }
        var out: [[Float]] = [[], []]
        var position = 0
        while position + block <= input[0].count {
            let chunk = input.map { Array($0[position..<position + block]) }
            let rendered = try host.processOffline(input: chunk, frames: block)
            out[0] += rendered[0]; out[1] += rendered[1]
            position += block
        }
        return out
    }

    private func program(_ rate: Double) -> [[Float]] {
        let n = Int(rate * 0.4) / block * block
        func tone(_ hz: Double, _ a: Float, _ phase: Double) -> [Float] {
            (0..<n).map { Float(Double(a) * sin(2 * .pi * hz * Double($0) / rate + phase)) }
        }
        let a = zip(tone(60, 0.2, 0), tone(1_000, 0.15, 0.5)).map { $0 + $1 }
        let b = zip(tone(95, 0.2, 1), tone(310, 0.15, 0)).map { $0 + $1 }
        return [a, b]
    }

    /// The output before the carry (the stored crossover read as today) against after it (the arrangement compiled and
    /// its stereo alignment applied): the same samples, to float rounding, for both slopes at every rate.
    func testCarriedLogicalCrossoverRendersTheSameAtEveryRate() throws {
        for rate in Self.rates {
            for topology in CrossoverTopology.allCases {
                let state = logical(topology)
                let derived = try XCTUnwrap(SystemArrangementMigration.derive(from: state, detectedChannelCount: 2))
                XCTAssertEqual(derived.bass, .dspMonoToMains)
                let compiled = try SystemArrangementCompiler.compile(derived, preserving: nil).get()
                XCTAssertTrue(compiled.bassManagementEnabled)

                var legacySnapshot = snapshot(rate: rate, hz: state.bassManagement.frequencyHz, topology: topology)
                var carriedSnapshot = legacySnapshot
                let legacy = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(
                    snapshot: &legacySnapshot, sampleRate: rate, alignment: nil))
                let carried = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(
                    snapshot: &carriedSnapshot, sampleRate: rate, alignment: compiled.stereoAlignment))
                let input = program(rate)
                let before = try render(legacy, input)
                let after = try render(carried, input)
                for lane in 0..<2 {
                    XCTAssertEqual(before[lane].count, after[lane].count)
                    let worst = zip(before[lane], after[lane]).reduce(0.0) { max($0, Double(abs($1.0 - $1.1))) }
                    XCTAssertLessThanOrEqual(worst, 1e-6, "\(topology) lane \(lane) at \(rate)")
                }
                XCTAssertGreaterThan(before[0].reduce(0) { max($0, abs($1)) }, 0.01, "the test program is audible")
            }
        }
    }

    /// The physical crossovers carried to the matrix render the same as the older splitter at the eight rates: that
    /// equivalence is `SpeakerRoutingMigrationTests.testMigratedRenderMatchesLegacyWithoutLimiter` (E6 parity tolerance);
    /// here the same migration is reached through the outcome the page uses.
    func testMatrixCarryUsesTheSameMigrationTheParityTestsCover() throws {
        for mode in SpeakerCrossoverMode.allCases {
            let state = physical(mode)
            let direct = SpeakerRoutingMigration.migrate(
                routing: state.outputRouting, bassManagement: state.bassManagement, driverProcessing: nil)
            XCTAssertEqual(state.migratingSpeakerRouting(enabled: true).speakerRouting, direct.routing, "\(mode)")
            XCTAssertEqual(SpeakersBassMigration.outcome(for: state), .matrix)
        }
    }

    // MARK: Page

    func testRetiredCardsAreNotOnTheOwnedPage() {
        // The page for the arrangement owner shows the arrangement's own bass controls, and the older cards only
        // exist in the flag-off layout; the model says the arrangement is in charge.
        let page = SpeakersPageModel.make(
            matrixEnabled: false, bass: logical(.linkwitzRiley24).bassManagement, legacyRoutingReason: nil,
            carry: .arrangement)
        XCTAssertEqual(page.owner, .arrangement)
        XCTAssertNil(page.legacyBassSummary)
    }

    // MARK: Per-driver rows (G119)

    private func routing() -> SpeakerRoutingConfiguration {
        func way(_ name: String, _ channel: UInt32, role: DriverRole) -> RoutedWay {
            var w = RoutedWay(
                name: name, endpoint: PhysicalOutputEndpoint(deviceUID: OfflineSetupRig.outputUID, channelIndex: channel))
            w.role = role
            return w
        }
        return SpeakerRoutingConfiguration(
            enabled: true,
            speakers: [
                RoutedSpeaker(name: "Left", source: .program(0), ways: [way("Woofer", 0, role: .woofer), way("Tweeter", 2, role: .tweeter)]),
                RoutedSpeaker(name: "Right", source: .program(1), ways: [way("Woofer", 1, role: .woofer), way("Tweeter", 3, role: .tweeter)]),
            ],
            matrix: [])
    }

    func testDriverRowsListEveryWayAndEditsAreClamped() {
        let config = routing()
        let rows = SpeakerDriverTable.rows(routing: config)
        XCTAssertEqual(rows.map(\.title), ["Left Woofer", "Left Tweeter", "Right Woofer", "Right Tweeter"])
        XCTAssertTrue(SpeakerDriverTable.rows(routing: nil).isEmpty)
        var off = config
        off.enabled = false
        XCTAssertTrue(SpeakerDriverTable.rows(routing: off).isEmpty)
        let id = rows[1].id
        let edited = SpeakerDriverTable.editing(config, way: id) { $0.trimDB = 99; $0.delayMs = -4; $0.polarityInverted = true }
        let row = SpeakerDriverTable.rows(routing: edited)[1]
        XCTAssertEqual(row.trimDB, 24)
        XCTAssertEqual(row.delayMs, 0)
        XCTAssertTrue(row.polarityInverted)
        XCTAssertEqual(SpeakerDriverTable.rows(routing: edited)[0], rows[0], "other drivers are untouched")
    }

    func testDriverTableEditReachesTheEngineRouting() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        try rig.engine.replaceSpeakerRoutingConfiguration(routing())
        let id = try XCTUnwrap(SpeakerDriverTable.rows(routing: rig.engine.speakerRoutingConfiguration).first?.id)
        try SpeakerDriverTableEditor.edit(way: id, engine: rig.engine, profiles: rig.profiles) {
            $0.trimDB = -3.5
            $0.delayMs = 1.25
        }
        let row = try XCTUnwrap(SpeakerDriverTable.rows(routing: rig.engine.speakerRoutingConfiguration).first)
        XCTAssertEqual(row.trimDB, -3.5)
        XCTAssertEqual(row.delayMs, 1.25)
    }

    func testDriverTableFitsTheDefaultAndSmallWindows() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        try rig.engine.replaceSpeakerRoutingConfiguration(routing())
        for width in [1_280.0, 1_920.0] {
            let view = SpeakerDistancesLevelsTable(engine: rig.engine, profiles: rig.profiles)
                .frame(width: width, height: 600)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width)
        }
    }
}
