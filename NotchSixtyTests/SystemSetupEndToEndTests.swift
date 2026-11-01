import XCTest
@testable import NotchSixty

/// E24 S0: drives the production setup-window model through all ten steps against the synthetic
/// 2.1 reference room (3 seats). Steps that are known to be broken are wrapped in a strict
/// `XCTExpectFailure` naming the slice that fixes them, so a fix cannot land without flipping
/// its marker.
@MainActor
final class SystemSetupEndToEndTests: XCTestCase {
    /// Q5: all eight standard rates. `N60_E24_RATES=44100,48000,384000` narrows the list.
    static var rates: [Double] {
        if let list = ProcessInfo.processInfo.environment["N60_E24_RATES"] {
            let parsed = list.split(separator: ",").compactMap { Double($0) }
            if !parsed.isEmpty { return parsed }
        }
        return [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    }

    private func strict() -> XCTExpectedFailure.Options {
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        return options
    }

    private func waitForVerification(_ model: SystemSetupFlowModel) async {
        for _ in 0..<600 where model.isVerifying { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func testAllTenStepsAtEveryRate() async throws {
        for rate in Self.rates {
            let rig = try OfflineSetupRig(rate: rate)
            defer { rig.tearDown() }
            try rig.installTwoPointOneProfile()
            let model = rig.model
            let label = "\(rate) Hz"

            model.begin()
            XCTAssertEqual(model.step, .output, label)
            XCTAssertEqual(model.choices.sampleRate, rate, label)
            model.chooseOutput(uid: OfflineSetupRig.outputUID)
            model.next()
            XCTAssertEqual(model.step, .topology, "\(label): \(model.message ?? "")")

            model.chooseTopology(.twoPointOne)
            model.next()
            XCTAssertEqual(model.step, .microphone, "\(label): \(model.message ?? "")")

            // Level: the noise runs in the measurement-owned level session (E24 S1).
            model.selectMicrophone(uid: OfflineSetupRig.inputUID)
            model.toggleNoise()
            XCTAssertTrue(model.noiseIsPlaying, "\(label): \(model.message ?? "")")
            XCTAssertEqual(rig.levelTransports.pumps.count, 1, label)
            model.stopNoise()
            XCTAssertFalse(model.noiseIsPlaying, label)
            model.acceptSweepLevel(measuredSPLdBC: 75)
            model.next()
            XCTAssertEqual(model.step, .room, "\(label): \(model.message ?? "")")
            model.next()
            XCTAssertEqual(model.step, .measure, "\(label): \(model.message ?? "")")

            // Measure: 3 seats x (L, R, sub) through the real analysis path.
            model.prepareMeasure()
            model.addSeat()
            model.addSeat()
            await model.measureAll()
            XCTAssertEqual(model.measureProgress.next == nil, true, "\(label): \(model.message ?? "")")
            XCTAssertEqual(model.choices.measurementIDs.count, 3, label)
            XCTAssertEqual(rig.transports.made, 9, label)
            model.next()
            XCTAssertEqual(model.step, .alignment, "\(label): \(model.message ?? "")")

            await model.computeAlignment()
            XCTAssertNotNil(model.alignment, "\(label): \(model.message ?? "")")
            model.applyAlignment()
            XCTAssertTrue(model.choices.alignmentApplied, label)
            model.next()
            XCTAssertEqual(model.step, .bass, "\(label): \(model.message ?? "")")

            model.computeBass()
            XCTAssertNotNil(model.bass, "\(label): \(model.message ?? "")")
            model.applyBass()
            XCTAssertTrue(model.choices.bassApplied, label)
            model.next()
            XCTAssertEqual(model.step, .correction, "\(label): \(model.message ?? "")")

            model.prepareCorrection()
            XCTAssertTrue(model.correctionIsPrepared, "\(label): \(model.message ?? "")")
            model.applyCorrection()
            XCTAssertTrue(model.choices.correctionApplied, "\(label): \(model.message ?? "")")
            model.next()
            XCTAssertEqual(model.step, .verify, "\(label): \(model.message ?? "")")

            // Verify plays the sweep through the live graph and the reference room (E24 S3a).
            model.runVerification()
            await waitForVerification(model)
            XCTAssertNotNil(model.choices.verificationPassed, label)
            let verifiedMessage = "\(label): \(model.message ?? "") \(String(describing: model.verificationSummary))"
            if rate >= 176_400 {
                // The stored measurement impulse response overstates the 60 to 120 Hz resonance by about 2 dB at the
                // high rates (the trial room is exact), so the prediction misses by 1.6 to 2.0 dB. Open: see E24.md.
                XCTExpectFailure("Stored measurement IR is inaccurate at 176.4 kHz and above: open, see E24.md", options: strict()) {
                    XCTAssertEqual(model.choices.verificationPassed, true, verifiedMessage)
                }
            } else {
                XCTAssertEqual(model.choices.verificationPassed, true, verifiedMessage)
            }
            XCTAssertEqual(rig.trialPlayer.sweepsPlayed, 1, label)
            XCTExpectFailure("Mixed phase never produced by the wizard: fixed by E24 S3b", options: strict()) {
                XCTAssertEqual(model.choices.designKind, .mixedPhase, label)
            }
            model.next()
            XCTAssertEqual(model.step, .save, "\(label): \(model.message ?? "")")

            model.setProfileName("E24 reference \(Int(rate))")
            model.save()
            XCTAssertNotNil(model.savedProfileName, "\(label): \(model.message ?? "")")
        }
    }

    /// A disabled Measure Next must say why (E24 S2).
    func testDisabledMeasureCarriesAReason() throws {
        let rig = try OfflineSetupRig(rate: 48_000, permission: .denied)
        defer { rig.tearDown() }
        try rig.installTwoPointOneProfile()
        rig.calibration.prepareForUse()
        XCTAssertFalse(rig.calibration.canMeasure)
        let reason = try XCTUnwrap(rig.calibration.readiness.reason)
        XCTAssertTrue(reason.contains("Microphone access"), reason)
        XCTAssertEqual(rig.calibration.readiness.fix, .openSystemSettings)
    }
}

/// Each injectable service, called once through the production factory against the offline
/// boundary, must not report that it is unavailable.
@MainActor
final class ProductionWiringTests: XCTestCase {
    private func strict() -> XCTExpectedFailure.Options {
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        return options
    }

    func testNoisePlayerDoesNotReportUnavailable() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        let services = ProductionSystemSetupServices.production(
            engine: rig.engine, profiles: rig.profiles, microphone: rig.microphone, levelTransport: rig.levelTransports.factory)
        var failure: Error?
        do { try services.noise.start(SystemSetupLevelPlan().generatorSettings(), selection: .lane(0)) } catch { failure = error }
        XCTAssertNil(failure)
        services.noise.stop()
    }

    func testVerifierDoesNotReportUnavailable() async throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        let services = ProductionSystemSetupServices.production(
            engine: rig.engine, profiles: rig.profiles, microphone: rig.microphone, levelTransport: rig.levelTransports.factory)
        var failure: Error?
        do { _ = try await services.verifier.measureMainSeat(predictedErrorDB: 1, sampleRate: 48_000) } catch { failure = error }
        // With no correction applied the verifier says why it cannot check; it is no longer an always-unavailable stand-in.
        guard case .couldNotMeasure(let reason)? = failure as? SystemSetupVerificationError else {
            return XCTFail("\(String(describing: failure))")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    /// The Generator card's Play with idle playback goes to the level session instead of the graph renderer.
    func testGeneratorPlayWithIdlePlaybackUsesTheLevelSession() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        let controller = MeasurementGeneratorController(
            engine: rig.engine, profiles: rig.profiles, microphone: rig.microphone, transport: rig.levelTransports.factory)
        controller.play(SystemSetupLevelPlan().generatorSettings(), selection: .lane(0))
        XCTAssertTrue(controller.isPlaying, controller.message ?? "")
        XCTAssertEqual(rig.levelTransports.pumps.count, 1)
        controller.stop()
        XCTAssertFalse(controller.isPlaying)
    }
}
