import XCTest
@testable import NotchSixty

/// E8 S12 (`e8.active-commissioning`): driver roles and the hard high-pass rule.
@MainActor
final class DriverRoleTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func ep(_ i: UInt32) -> PhysicalOutputEndpoint { PhysicalOutputEndpoint(deviceUID: "dev", channelIndex: i) }
    private func spec(_ hz: Double, order: Int = 4, family: CrossoverCore.Family = .linkwitzRiley) -> CrossoverCore.FilterSpec {
        CrossoverCore.FilterSpec(family: family, order: order, cornerHz: hz)
    }

    private func context(rate: Double = 48_000, enforce: Bool = true) -> SpeakerRoutingContext {
        SpeakerRoutingContext(programLanes: 2, subwoofers: 0, sampleRate: rate, enforceDriverRoles: enforce)
    }

    private func config(_ way: RoutedWay) -> SpeakerRoutingConfiguration {
        SpeakerRoutingConfiguration(speakers: [RoutedSpeaker(name: "L", source: .program(0), ways: [way])])
    }

    private func model(enforce: Bool = true) -> SpeakerRoutingEditorModel {
        let m = SpeakerRoutingEditorModel(context: context(enforce: enforce))
        XCTAssertTrue(m.applyTemplate(
            .threeWay,
            mains: [.init(lane: 0, name: "Left", endpoints: [ep(0), ep(1), ep(2)]),
                    .init(lane: 1, name: "Right", endpoints: [ep(3), ep(4), ep(5)])],
            crossoverHz: [400, 3_000]))
        return m
    }

    // MARK: Validation table

    func testValidationTableForEveryRole() {
        struct Case { var role: DriverRole; var hp: CrossoverCore.FilterSpec?; var errors: Int }
        let cases: [Case] = [
            Case(role: .tweeter, hp: nil, errors: 1),
            Case(role: .tweeter, hp: spec(1_000), errors: 1),
            Case(role: .tweeter, hp: spec(1_500), errors: 0),
            Case(role: .tweeter, hp: spec(2_000, order: 1, family: .butterworth), errors: 1),
            Case(role: .tweeter, hp: spec(3_000, order: 1, family: .butterworth), errors: 0),
            Case(role: .midrange, hp: nil, errors: 1),
            Case(role: .midrange, hp: spec(150), errors: 1),
            Case(role: .midrange, hp: spec(300, order: 1, family: .butterworth), errors: 1),
            Case(role: .midrange, hp: spec(400, order: 1, family: .butterworth), errors: 0),
            Case(role: .midrange, hp: spec(400), errors: 0),
            Case(role: .woofer, hp: nil, errors: 0),
            Case(role: .subwoofer, hp: nil, errors: 0),
            Case(role: .fullRange, hp: nil, errors: 0),
        ]
        for c in cases {
            let way = RoutedWay(name: "W", endpoint: ep(0), highPass: c.hp, role: c.role)
            let v = config(way).validate(in: context())
            XCTAssertEqual(v.errors.count, c.errors, "\(c.role) \(String(describing: c.hp))")
            // Flag off: the rule does not run.
            XCTAssertTrue(config(way).validate(in: context(enforce: false)).isValid, "\(c.role) off")
        }
    }

    func testRulesHoldAtEveryRateAndOverrideMovesTheLimit() {
        for rate in Self.rates {
            var way = RoutedWay(name: "T", endpoint: ep(0), highPass: spec(1_200), role: .tweeter)
            XCTAssertFalse(config(way).validate(in: context(rate: rate)).isValid, "\(rate)")
            way.lowestSafeHz = 1_000
            XCTAssertTrue(config(way).validate(in: context(rate: rate)).isValid, "\(rate)")
        }
        // A role-less way is exempt; band findings stay warnings.
        XCTAssertTrue(config(RoutedWay(name: "W", endpoint: ep(0))).validate(in: context()).isValid)
    }

    func testOldStoredWayWithoutRoleDecodes() throws {
        let way = RoutedWay(name: "W", endpoint: ep(0), highPass: spec(500), role: .midrange)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(way)) as? [String: Any])
        json["role"] = nil
        json["lowestSafeHz"] = nil
        json["roleInferred"] = nil
        let decoded = try JSONDecoder().decode(RoutedWay.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.role)
        XCTAssertNil(decoded.effectiveLowestSafeHz)
    }

    // MARK: Live edits

    func testRefusedEditLeavesPublishedConfigurationUnchanged() throws {
        let m = model()
        var committed: [SpeakerRoutingConfiguration] = []
        m.onCommit = { committed.append($0) }
        let before = m.configuration
        let speaker = before.speakers[0]
        let tweeter = speaker.ways[2]
        XCTAssertEqual(tweeter.role, .tweeter)

        // Removing the high-pass in one commit is refused.
        m.setFilter(nil, edge: .highPass, way: tweeter.id, speaker: speaker.id)
        XCTAssertEqual(m.configuration, before)
        XCTAssertTrue(committed.isEmpty)
        XCTAssertNotNil(m.roleRefusal)
        // So is moving the corner below the limit, or a first-order filter too close to it.
        m.setFilter(spec(1_000), edge: .highPass, way: tweeter.id, speaker: speaker.id)
        m.setFilter(spec(2_000, order: 1, family: .butterworth), edge: .highPass, way: tweeter.id, speaker: speaker.id)
        XCTAssertEqual(m.configuration, before)
        XCTAssertTrue(committed.isEmpty)
        // A swap to a steeper filter above the limit is one atomic commit.
        m.setFilter(spec(2_500, order: 8), edge: .highPass, way: tweeter.id, speaker: speaker.id)
        XCTAssertEqual(committed.count, 1)
        XCTAssertNil(m.roleRefusal)
        XCTAssertEqual(m.configuration.speakers[0].ways[2].highPass, spec(2_500, order: 8))
        // A whole-configuration replace that breaks the rule is refused too.
        var broken = m.configuration
        broken.speakers[1].ways[2].highPass = nil
        m.replace(broken)
        XCTAssertEqual(committed.count, 1)
        XCTAssertNotNil(m.roleRefusal)
    }

    func testFlagOffEditsBehaveAsToday() {
        let m = model(enforce: false)
        var committed = 0
        m.onCommit = { _ in committed += 1 }
        let s = m.configuration.speakers[0]
        m.setFilter(nil, edge: .highPass, way: s.ways[2].id, speaker: s.id)
        XCTAssertEqual(committed, 1)
        XCTAssertNil(m.configuration.speakers[0].ways[2].highPass)
        XCTAssertNil(m.roleRefusal)
    }

    func testAlreadyBrokenWayCanStillBeFixed() {
        var broken = model(enforce: false).configuration
        broken.speakers[0].ways[2].highPass = nil
        let m = SpeakerRoutingEditorModel(configuration: broken, context: context())
        let s = broken.speakers[0]
        m.setFilter(spec(2_000), edge: .highPass, way: s.ways[2].id, speaker: s.id)
        XCTAssertNotNil(m.configuration.speakers[0].ways[2].highPass)
        XCTAssertNil(m.roleRefusal)
    }

    func testLoweringTheLimitNeedsConfirmation() {
        let m = model()
        let s = m.configuration.speakers[0]
        let tweeter = s.ways[2]
        guard case .needsConfirmation(let message) = m.setLowestSafeHz(1_000, way: tweeter.id, speaker: s.id) else {
            return XCTFail("expected a confirmation")
        }
        XCTAssertTrue(message.contains("destroyed"))
        XCTAssertNil(m.configuration.speakers[0].ways[2].lowestSafeHz)
        XCTAssertEqual(m.setLowestSafeHz(1_000, way: tweeter.id, speaker: s.id, confirmed: true), .applied)
        XCTAssertEqual(m.configuration.speakers[0].ways[2].lowestSafeHz, 1_000)
        // Raising it needs no confirmation but the existing 3 kHz corner still passes.
        XCTAssertEqual(m.setLowestSafeHz(2_500, way: tweeter.id, speaker: s.id), .applied)
        // Raising it above the corner is refused by the rule.
        guard case .refused = m.setLowestSafeHz(4_000, way: tweeter.id, speaker: s.id) else { return XCTFail("expected refusal") }
        XCTAssertEqual(m.configuration.speakers[0].ways[2].lowestSafeHz, 2_500)
    }

    // MARK: Templates and inference

    func testTemplatesSetRoles() {
        let m = model()
        XCTAssertEqual(m.configuration.speakers[0].ways.map(\.role), [.woofer, .midrange, .tweeter])
        let mains = SpeakerRoutingEditorModel(context: SpeakerRoutingContext(programLanes: 2, subwoofers: 1, sampleRate: 48_000))
        XCTAssertTrue(mains.applyTemplate(.mainsPlusSub, deviceUID: "dev"))
        XCTAssertEqual(mains.configuration.speakers.map { $0.ways[0].role }, [.fullRange, .fullRange, .subwoofer])
        XCTAssertTrue(m.validation.isValid)
    }

    func testInferenceFromPositionAndCorners() {
        var stored = model(enforce: false).configuration
        for s in stored.speakers.indices { for w in stored.speakers[s].ways.indices {
            stored.speakers[s].ways[w].role = nil
        } }
        stored.speakers.append(RoutedSpeaker(
            name: "Sub", source: .sub(0), ways: [RoutedWay(name: "Sub", endpoint: ep(9))]))
        let m = SpeakerRoutingEditorModel(
            configuration: stored, context: SpeakerRoutingContext(programLanes: 2, subwoofers: 1, sampleRate: 48_000, enforceDriverRoles: true))
        m.inferMissingRoles()
        XCTAssertEqual(m.configuration.speakers[0].ways.map(\.role), [.woofer, .midrange, .tweeter])
        XCTAssertEqual(m.configuration.speakers[2].ways[0].role, .subwoofer)
        XCTAssertEqual(m.unconfirmedRoleWays.count, 7)
        let s = m.configuration.speakers[0]
        m.confirmRole(way: s.ways[2].id, speaker: s.id)
        XCTAssertEqual(m.unconfirmedRoleWays.count, 6)
    }

    func testMigratedLegacyProfilesCarryInferredRoles() throws {
        let buses: [SpeakerOutputBus] = [.leftLow, .rightLow, .leftMid, .rightMid, .leftHigh, .rightHigh]
        var b = BassManagementConfiguration()
        b.enabled = true
        b.physicalOutputMode = .triAmp
        b.frequencyHz = 400
        b.upperFrequencyHz = 3_000
        let routes = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: buses.enumerated().map { SpeakerOutputRoute(name: $0.element.displayName, bus: $0.element, destination: ep(UInt32($0.offset))) })
        let routing = try XCTUnwrap(SpeakerRoutingMigration.migrate(
            routing: routes, bassManagement: b, driverProcessing: nil).routing)
        XCTAssertEqual(routing.speakers[0].ways.map(\.role), [.woofer, .midrange, .tweeter])
        XCTAssertTrue(routing.speakers.flatMap(\.ways).allSatisfy { $0.roleInferred == true })
        let v = routing.validate(in: context())
        XCTAssertTrue(v.isValid, "\(v.errors)")
    }

    func testFeatureFlagRegisteredDark() {
        XCTAssertTrue(FeatureFlag.all.contains(.activeCommissioning))
        XCTAssertFalse(FeatureFlag.activeCommissioning.resolvedDefault)
    }
}
