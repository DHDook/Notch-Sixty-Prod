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
            // The three E4 survey flags graduated (G16): the list is the exact set that is on, the rest are off.
            arguments: ["-NotchSixtyFeatures", (on + ["e4.virtual-microphone", "e4.head-position-camera", "e4.zones"]
                .filter { !on.contains($0) }.map { "-" + $0 }).joined(separator: ",")])
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

    /// E4 G18: the controller hands the adaptive worker the ears each tone was designed for and the other seats it must
    /// not worsen, and the seeds built from them become shadow tones with the split's path (the seeds are no longer withheld).
    func testAdaptiveSeedPointsCarryTheEarsAndOtherSeatsForOneSeatAndTwoZones() throws {
        for rate in rates {
            let rig = try makeRig(rate: rate)
            attachZonesLikeProduction(rig, flags: ["e4.zones", "e4.virtual-microphone"])
            let zones = try XCTUnwrap(rig.quietZone.zones)
            let frequencies = [60.0, 80.0]
            runSurvey(rig, frequencies: frequencies)
            rig.survey.useAtEar = true
            let one = rig.quietZone.adaptiveSeedPoints(near: 60, twoZones: false)
            XCTAssertEqual(one.ears.count, 1, "rate \(rate)")
            XCTAssertTrue(one.limits.isEmpty, "rate \(rate)")
            let ear = try XCTUnwrap(rig.survey.earTone(near: 60))
            XCTAssertEqual((one.ears[0].ratio - ear.ratio).magnitude, 0, accuracy: 1e-12)
            XCTAssertTrue(rig.quietZone.adaptiveSeedPoints(near: 60, twoZones: true).ears.isEmpty, "zones not surveyed")

            surveySecond(rig, zones: zones, frequencies: frequencies)
            XCTAssertTrue(zones.setMode(.twoZones), "rate \(rate): \(zones.message)")
            let two = rig.quietZone.adaptiveSeedPoints(near: 60, twoZones: true)
            XCTAssertEqual(two.ears.count, 2, "rate \(rate)")
            let b = try XCTUnwrap(zones.secondTone(near: 60))
            XCTAssertEqual((two.ears[1].left - b.earLeft).magnitude, 0, accuracy: 1e-12)

            // The seed becomes a shadow tone, so the live worker adapts (it is built, not withheld).
            let seed = AdaptiveQuietZoneSeed(
                frequencyHz: 60, leftPath: ActiveQuietZoneComplex(real: 0.5, imaginary: 0.1),
                rightPath: ActiveQuietZoneComplex(real: 0.4, imaginary: -0.2),
                leftOutput: ActiveQuietZoneComplex(real: 0.03, imaginary: 0.01),
                rightOutput: ActiveQuietZoneComplex(real: 0.02, imaginary: 0), ears: two.ears, limitSeats: two.limits)
            XCTAssertEqual(AdaptiveQuietZoneShadowTone.tones(from: [seed])[0].ears.count, 2)
        }
    }

    /// E4 G23: `ActiveQuietZoneController.evaluate` itself, driven with an injected analysis (a synthetic residual and
    /// rendered reference carrying the twin's noise at the tones), through to the seeds, the shadow tones and the live
    /// worker, at the eight rates. The only seams are the observation install and the injection headroom; the survey
    /// and zone controllers are attached the way `QuietZoneFlagWiring` attaches them. Flag policy is launch-argument
    /// only, so the nightly flags-off environment cannot change it (the production flags-off path is pinned in
    /// `E4GraduationTests`).
    func testEvaluateDrivesTheSeedsThroughToTheAdaptiveWorkerAtEightRates() throws {
        for rate in rates {
            let rig = try makeRig(rate: rate)
            attachZonesLikeProduction(rig, flags: ["e4.zones", "e4.virtual-microphone"])
            let zones = try XCTUnwrap(rig.quietZone.zones)
            let frequencies = [60.0, 80.0]
            runSurvey(rig, frequencies: frequencies)
            rig.survey.useAtEar = true

            // One window of rendered reference and residual: tone phasors in the planner's convention (A cos(wn + phi)
            // reads back as A e^{j phi}); the residual is the twin's monitor noise plus the speakers' own path.
            let count = Int(rate)
            let refLeft = ActiveQuietZoneComplex(real: 0.2, imaginary: 0.05)
            let refRight = ActiveQuietZoneComplex(real: 0.1, imaginary: -0.04)
            var rawLeft = [Float](repeating: 0, count: count)
            var rawRight = rawLeft
            var residual = rawLeft
            for f in frequencies {
                let paths = try rig.quietZone.surveyPaths(frequencyHz: f, earPositionID: rig.earID)
                let error = rig.twin.noiseAtMonitor(f) + paths.monitorLeft * refLeft + paths.monitorRight * refRight
                let omega = 2 * Double.pi * f / rate
                for n in 0..<count {
                    let c = cos(omega * Double(n)), s = sin(omega * Double(n))
                    rawLeft[n] += Float(refLeft.real * c - refLeft.imaginary * s)
                    rawRight[n] += Float(refRight.real * c - refRight.imaginary * s)
                    residual[n] += Float(error.real * c - error.imaginary * s)
                }
            }
            let snapshot = AmbientAnalysisSnapshot(
                sampleRate: rate, analyzedFrames: count, separationMode: .modeledPlaybackSubtraction,
                separationConfidence: 0.9, predictionGain: 1, microphoneLevelDBFS: -24,
                predictedPlaybackLevelDBFS: -28, ambientLevelDBFS: -34, ambientLevelDBSPL: nil,
                stationarityScore: 0.9, periodicityScore: 0.9, periodicFrequencyHz: 60,
                lowFrequencyEnergyFraction: 0.9, cancellationCandidateScore: 0.9, character: .tonal,
                spectrum: [], tonalComponents: [])
            let detailed = AmbientAnalysisDetailedResult(
                snapshot: snapshot, separatedResidualSamples: residual,
                playbackAlignmentLagFrames: nil, playbackAlignmentConfidence: nil)
            rig.quietZone.ambient.installQuietZoneObservationForTesting(
                detailed: detailed, rawLeft: rawLeft, rawRight: rawRight)
            let target = ActiveQuietZoneRuntimeTarget(
                tones: frequencies.map {
                    ActiveQuietZoneRuntimeTone(
                        frequencyHz: $0, leftOutput: ActiveQuietZoneComplex(real: 0.05, imaginary: 0.01),
                        rightOutput: ActiveQuietZoneComplex(real: 0.03, imaginary: -0.01))
                },
                transitionMilliseconds: 100)

            // One seat at the surveyed ear: each seed carries the ear, no other seats.
            var telemetry = try rig.quietZone.evaluateForTesting(
                scheduledTarget: target, detailed: detailed, availableInjectionPeak: 0.5)
            XCTAssertEqual(telemetry.count, 2, "rate \(rate)")
            var seeds = rig.quietZone.adaptiveSeeds
            XCTAssertEqual(seeds.map(\.frequencyHz), frequencies, "rate \(rate)")
            for seed in seeds {
                XCTAssertEqual(seed.ears.count, 1, "one seat rate \(rate) f \(seed.frequencyHz)")
                XCTAssertTrue(seed.limitSeats.isEmpty, "rate \(rate)")
            }
            func assertWorker(_ ears: Int, _ message: String) throws {
                let tones = AdaptiveQuietZoneShadowTone.tones(from: rig.quietZone.adaptiveSeeds)
                XCTAssertEqual(tones.map(\.ears.count), [ears, ears], message)
                XCTAssertNotNil(
                    AdaptiveTonalLiveWorker(
                        sampleRate: rate, tones: tones, link: AdaptiveQuietZoneShadowTests.NullLink()), message)
            }
            try assertWorker(1, "one seat rate \(rate)")

            // Two zones: each seed carries both ears.
            surveySecond(rig, zones: zones, frequencies: frequencies)
            XCTAssertTrue(zones.setMode(.twoZones), "rate \(rate): \(zones.message)")
            telemetry = try rig.quietZone.evaluateForTesting(
                scheduledTarget: target, detailed: detailed, availableInjectionPeak: 0.5)
            XCTAssertEqual(telemetry.count, 2, "rate \(rate)")
            seeds = rig.quietZone.adaptiveSeeds
            for seed in seeds {
                XCTAssertEqual(seed.ears.count, 2, "two zones rate \(rate) f \(seed.frequencyHz)")
                // The monitor limit is the worker's own (monitorIncreaseLimitDB); seeds list only other surveyed seats.
                XCTAssertTrue(seed.limitSeats.isEmpty, "no other surveyed seat, rate \(rate)")
            }
            try assertWorker(2, "two zones rate \(rate)")
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
