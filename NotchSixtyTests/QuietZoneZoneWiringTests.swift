import XCTest
@testable import NotchSixty

/// E4 S27: the zone chooser through production wiring (`QuietZoneFlagWiring`, `QuietZoneZoneController` and the real
/// `ActiveQuietZoneController` design) with the free-field twin at the eight device rates. Live microphones and a real
/// bed are bench checks (E22).
@MainActor
extension QuietZoneVirtualMicWiringTests {
    private func zoneFlags(_ on: [String]) -> FeatureFlags {
        let defaults = UserDefaults(suiteName: "QuietZoneZoneWiringTests.\(UUID().uuidString)")!
        return FeatureFlags(
            known: FeatureFlag.all, defaults: defaults, policy: .launchArgumentOnly,
            arguments: on.isEmpty ? [] : ["-NotchSixtyFeatures", on.joined(separator: ",")])
    }

    /// Attaches the controllers the way `ProductController` does, for the given flags.
    private func attachZonesLikeProduction(_ rig: Rig, flags: [String]) {
        let f = zoneFlags(flags)
        if f.isEnabled(.virtualMicrophone) { rig.quietZone.attachVirtualMicrophone(rig.survey) }
        // The same call `QuietZoneFlagWiring.attachControllers` makes for the zone chooser.
        if f.isEnabled(.zones), rig.quietZone.virtualMic != nil {
            rig.quietZone.attachZones(QuietZoneZoneController())
        }
    }

    private func surveySecond(_ rig: Rig, zones: QuietZoneZoneController, frequencies: [Double]) {
        let s = zones.second
        s.selectEar(rig.ear2ID)
        s.beginVisit(.monitor)
        for _ in 0..<QuietZoneVirtualMicSurveyController.windowsPerVisit {
            s.ingestWindow(Dictionary(uniqueKeysWithValues: frequencies.map { ($0, rig.twin.noiseAtMonitor($0)) }))
        }
        s.beginVisit(.ear)
        for _ in 0..<QuietZoneVirtualMicSurveyController.windowsPerVisit {
            s.ingestWindow(Dictionary(uniqueKeysWithValues: frequencies.map { ($0, rig.twin.noiseAtEar2($0)) }))
        }
        s.useAtEar = true
    }

    func testZoneChooserExistsOnlyWithBothFlagsAndStartsAtOneSeat() throws {
        let rig = try makeRig(rate: 48_000)
        attachZonesLikeProduction(rig, flags: [])
        XCTAssertNil(rig.quietZone.zones)
        XCTAssertEqual(rig.quietZone.zoneMode, .fixedSeat)

        let rig3 = try makeRig(rate: 48_000)
        attachZonesLikeProduction(rig3, flags: ["e4.zones", "e4.virtual-microphone"])
        let zones = try XCTUnwrap(rig3.quietZone.zones)
        XCTAssertEqual(zones.mode, .fixedSeat)
        XCTAssertFalse(rig3.quietZone.arm.isArmed, "attaching the chooser never arms anything")
    }

    func testModesAreRefusedUntilTheirSurveysExist() throws {
        let rig = try makeRig(rate: 48_000)
        attachZonesLikeProduction(rig, flags: ["e4.zones", "e4.virtual-microphone"])
        let zones = try XCTUnwrap(rig.quietZone.zones)
        XCTAssertFalse(zones.setMode(.twoZones))
        XCTAssertFalse(zones.setMode(.follow))
        XCTAssertEqual(zones.mode, .fixedSeat)
        runSurvey(rig, frequencies: [60, 80])
        rig.survey.useAtEar = true
        XCTAssertFalse(zones.setMode(.twoZones), "the second zone is not surveyed yet")
        XCTAssertFalse(zones.setMode(.follow), "head follow is not attached")
        XCTAssertEqual(zones.mode, .fixedSeat)
    }

    func testTwoZonesBothMeetTheTargetMinusFiveDBAndTheMonitorStaysWithinOneDBAtEightRates() throws {
        for rate in rates {
            let rig = try makeRig(rate: rate)
            attachZonesLikeProduction(rig, flags: ["e4.zones", "e4.virtual-microphone"])
            let zones = try XCTUnwrap(rig.quietZone.zones)
            let frequencies = [60.0, 80.0]
            runSurvey(rig, frequencies: frequencies)
            rig.survey.useAtEar = true
            surveySecond(rig, zones: zones, frequencies: frequencies)
            XCTAssertTrue(zones.setMode(.twoZones), "rate \(rate): \(zones.message)")

            let plan = try XCTUnwrap(zones.plan, "rate \(rate)")
            XCTAssertEqual(plan.zonePointIDs, [rig.earID, rig.ear2ID])
            XCTAssertEqual(plan.otherSeatPointIDs.count, 1, "the monitor position is the other surveyed point")

            for f in frequencies {
                let a = try rig.quietZone.surveyPaths(frequencyHz: f, earPositionID: rig.earID)
                let b = try rig.quietZone.surveyPaths(frequencyHz: f, earPositionID: rig.ear2ID)
                let design = try XCTUnwrap(
                    try rig.quietZone.twoZoneDesign(
                        frequencyHz: f, monitorDisturbance: rig.twin.noiseAtMonitor(f),
                        monitorLeft: a.monitorLeft, monitorRight: a.monitorRight,
                        bassMode: .free, injectionPeakOverride: 0.5),
                    "rate \(rate) f \(f)")
                func reduction(_ noise: ActiveQuietZoneComplex, _ l: ActiveQuietZoneComplex, _ r: ActiveQuietZoneComplex) -> Double {
                    20 * log10(noise.magnitude / (noise + l * design.left + r * design.right).magnitude)
                }
                let target = QuietZoneQualificationTargets.quietZoneTonalReductionDB - 5
                XCTAssertGreaterThanOrEqual(
                    reduction(rig.twin.noiseAtEar(f), a.earLeft, a.earRight), target, "zone A rate \(rate) f \(f)")
                XCTAssertGreaterThanOrEqual(
                    reduction(rig.twin.noiseAtEar2(f), b.earLeft, b.earRight), target, "zone B rate \(rate) f \(f)")
                let monitorChange = -reduction(rig.twin.noiseAtMonitor(f), a.monitorLeft, a.monitorRight)
                XCTAssertLessThanOrEqual(
                    monitorChange, QuietZoneQualificationTargets.maximumOtherSeatIncreaseDB + 1e-6, "rate \(rate) f \(f)")
            }
        }
    }

    func testOneSeatAndFollowModesNeverUseTheTwoZoneDesign() throws {
        let rig = try makeRig(rate: 96_000)
        attachZonesLikeProduction(rig, flags: ["e4.zones", "e4.virtual-microphone"])
        let zones = try XCTUnwrap(rig.quietZone.zones)
        runSurvey(rig, frequencies: [60])
        rig.survey.useAtEar = true
        surveySecond(rig, zones: zones, frequencies: [60])
        let p = try rig.quietZone.surveyPaths(frequencyHz: 60, earPositionID: rig.earID)
        XCTAssertNil(try rig.quietZone.twoZoneDesign(
            frequencyHz: 60, monitorDisturbance: rig.twin.noiseAtMonitor(60),
            monitorLeft: p.monitorLeft, monitorRight: p.monitorRight, bassMode: .free))
        XCTAssertTrue(zones.setMode(.twoZones))
        // A conditioned bass path keeps the one-zone design rather than a two-zone solve that cannot honour it.
        XCTAssertNil(try rig.quietZone.twoZoneDesign(
            frequencyHz: 60, monitorDisturbance: rig.twin.noiseAtMonitor(60),
            monitorLeft: p.monitorLeft, monitorRight: p.monitorRight, bassMode: .commonMode))
        // A tone surveyed in only one zone keeps the one-zone design.
        XCTAssertNil(try rig.quietZone.twoZoneDesign(
            frequencyHz: 90, monitorDisturbance: rig.twin.noiseAtMonitor(90),
            monitorLeft: p.monitorLeft, monitorRight: p.monitorRight, bassMode: .free))
    }

    func testModeJoinsTheEarnedCapBindingAndRevalidationDropsBackToOneSeat() throws {
        let rig = try makeRig(rate: 48_000)
        attachZonesLikeProduction(rig, flags: ["e4.zones", "e4.virtual-microphone"])
        let zones = try XCTUnwrap(rig.quietZone.zones)
        runSurvey(rig, frequencies: [60])
        rig.survey.useAtEar = true
        surveySecond(rig, zones: zones, frequencies: [60])
        XCTAssertEqual(rig.quietZone.zoneMode, .fixedSeat)
        XCTAssertTrue(zones.setMode(.twoZones))
        XCTAssertEqual(rig.quietZone.zoneMode, .twoZones)
        let before = EarnedCapBinding(outputDeviceUID: "o", inputDeviceUID: "i", sampleRate: 48_000, zoneMode: .fixedSeat)
        let after = EarnedCapBinding(outputDeviceUID: "o", inputDeviceUID: "i", sampleRate: 48_000, zoneMode: rig.quietZone.zoneMode)
        XCTAssertNotEqual(before, after, "a zone change is a different binding, so the output starts at -40 dBFS")

        var changes = 0
        zones.onModeChanged = { changes += 1 }
        zones.second.discardSurvey()
        zones.revalidate()
        XCTAssertEqual(zones.mode, .fixedSeat)
        XCTAssertEqual(changes, 1)
    }

    func testChangingTheZoneWhileArmedDisarmsWithTheZoneReason() throws {
        let rig = try makeRig(rate: 48_000)
        attachZonesLikeProduction(rig, flags: ["e4.zones", "e4.virtual-microphone"])
        let zones = try XCTUnwrap(rig.quietZone.zones)
        runSurvey(rig, frequencies: [60])
        rig.survey.useAtEar = true
        surveySecond(rig, zones: zones, frequencies: [60])
        // Armed state is the arm switch's own; the engine here is not running, so arm the switch directly.
        let environment = LiveTreatmentEnvironment(
            outputDeviceUID: "out", sampleRate: 48_000, engineRunning: true, inputAvailable: true,
            microphoneLevelDBFS: nil, inputDeviceUID: "mic", outputGainDB: 0, microphoneSignalFault: nil,
            howlGuardTripCount: 0, bassPathFingerprint: nil)
        try rig.quietZone.arm.arm(environment: environment)
        XCTAssertTrue(rig.quietZone.arm.isArmed)
        XCTAssertTrue(zones.setMode(.twoZones))
        XCTAssertFalse(rig.quietZone.arm.isArmed)
        XCTAssertEqual(rig.quietZone.arm.lastDisarmReason, .zoneChanged)
    }
}
