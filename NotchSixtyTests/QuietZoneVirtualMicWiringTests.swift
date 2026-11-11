import XCTest
@testable import NotchSixty

/// E4 S26a: the ear-position survey and the design at the ear, through the real `ActiveQuietZoneController`
/// (its speaker paths come from Room Correction positions) with a free-field twin at the eight device rates.
/// Phasors are synthesised analytically; the controller, survey controller and design are production code.
@MainActor
final class QuietZoneVirtualMicWiringTests: XCTestCase {
    private struct OutputCatalog: OutputDeviceCataloging {
        let devices: [AudioOutputDevice]
        func outputDevices() throws -> [AudioOutputDevice] { devices }
    }

    private struct InputCatalog: InputDeviceCataloging {
        let devices: [AudioInputDevice]
        func inputDevices() throws -> [AudioInputDevice] { devices }
    }

    private struct Permission: MicrophonePermissionRequesting, Sendable {
        func currentStatus() -> MicrophonePermissionStatus { .authorized }
        func requestAccess() async -> MicrophonePermissionStatus { .authorized }
    }

    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    /// Free-field twin: delays in samples, so the paths are exact at every rate.
    private struct Twin {
        var rate: Double
        // Speaker-to-position delays and gains.
        var monitor: (l: (g: Double, k: Int), r: (g: Double, k: Int))
        var ear: (l: (g: Double, k: Int), r: (g: Double, k: Int))
        // Noise arrival (samples) at each position.
        var noiseMonitorK: Int
        var noiseEarK: Int

        func phasor(gain: Double, delay: Int, f: Double) -> ActiveQuietZoneComplex {
            let w = 2 * Double.pi * f * Double(delay) / rate
            return ActiveQuietZoneComplex(real: gain * cos(w), imaginary: -gain * sin(w))
        }
        func noiseAtMonitor(_ f: Double) -> ActiveQuietZoneComplex { phasor(gain: 0.05, delay: noiseMonitorK, f: f) }
        func noiseAtEar(_ f: Double) -> ActiveQuietZoneComplex { phasor(gain: 0.045, delay: noiseEarK, f: f) }
    }

    private func twin(rate: Double) -> Twin {
        // About 3 ms, 4 ms, 2.6 ms and 3.2 ms of path; the ear is nearer the right speaker.
        func k(_ ms: Double) -> Int { Int((rate * ms / 1000).rounded()) }
        return Twin(
            rate: rate,
            monitor: ((0.30, k(3.0)), (0.30, k(3.4))),
            ear: ((0.22, k(4.1)), (0.34, k(2.6))),
            noiseMonitorK: k(1.0), noiseEarK: k(1.5))
    }

    private func impulse(rate: Double, gain: Double, delay: Int) -> RoomCorrectionChannelMeasurement {
        var ir = [Float](repeating: 0, count: min(Int(rate * 0.25), 32_000))
        ir[delay] = Float(gain)
        let quality = RoomCorrectionMeasurementQuality(clipped: false, estimatedSNRDB: 45, sweepComplete: true)
        return RoomCorrectionChannelMeasurement(
            capturedAt: Date(), rawCapture: [0], impulseResponse: ir, transferFunction: nil, quality: quality)
    }

    private struct Rig {
        var quietZone: ActiveQuietZoneController
        var survey: QuietZoneVirtualMicSurveyController
        var earID: UUID
        var twin: Twin
    }

    private func makeRig(rate: Double) throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let output = AudioOutputDevice(
            deviceID: 11, uid: "out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: rate, maximum: rate)])
        let input = AudioInputDevice(
            deviceID: 22, uid: "mic", name: "Mic", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: rate, maximum: rate)])
        let engine = AudioIOEngine(deviceCatalog: OutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: output.uid)
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        let calibration = RoomCorrectionCalibrationController(
            engine: engine, inputCatalog: InputCatalog(devices: [input]), permissionClient: Permission())
        calibration.prepareForUse()
        calibration.selectInput(uid: "mic")
        let projects = RoomCorrectionProjectController(
            profiles: profiles,
            store: RoomCorrectionProjectStore(rootDirectory: root.appendingPathComponent("rc", isDirectory: true)))
        try projects.startNewProject()
        var project = try XCTUnwrap(projects.project)
        project.microphone = RoomCorrectionMicrophone(stableID: "mic", displayName: "Mic")
        let t = twin(rate: rate)
        let monitorPosition = RoomCorrectionMeasurementPosition(
            name: "Seat microphone", sampleRate: rate,
            left: impulse(rate: rate, gain: t.monitor.l.g, delay: t.monitor.l.k),
            right: impulse(rate: rate, gain: t.monitor.r.g, delay: t.monitor.r.k))
        let earPosition = RoomCorrectionMeasurementPosition(
            name: "Left ear", sampleRate: rate,
            left: impulse(rate: rate, gain: t.ear.l.g, delay: t.ear.l.k),
            right: impulse(rate: rate, gain: t.ear.r.g, delay: t.ear.r.k))
        project.measurements = [monitorPosition, earPosition]
        try projects.adoptProject(project)
        let ambient = AmbientCompensationController(
            engine: engine, profiles: profiles, microphone: calibration, projects: projects)
        try ambient.setPlaybackModelPosition(monitorPosition.id)
        let quietZone = ActiveQuietZoneController(engine: engine, profiles: profiles, ambient: ambient)
        let survey = QuietZoneVirtualMicSurveyController()
        quietZone.attachVirtualMicrophone(survey)
        return Rig(quietZone: quietZone, survey: survey, earID: earPosition.id, twin: t)
    }

    /// Runs both visits with the twin's noise phasors, as the controller's evaluate would hand them over.
    private func runSurvey(_ rig: Rig, frequencies: [Double], steady: Bool = true) {
        let survey = rig.survey
        survey.selectEar(rig.earID)
        survey.beginVisit(.monitor)
        for window in 0..<QuietZoneVirtualMicSurveyController.windowsPerVisit {
            let wobble = steady ? 1.0 : (window.isMultiple(of: 2) ? 3.0 : 0.1)
            survey.ingestWindow(Dictionary(uniqueKeysWithValues: frequencies.map {
                ($0, rig.twin.noiseAtMonitor($0) * ActiveQuietZoneComplex(real: wobble, imaginary: 0))
            }))
        }
        survey.beginVisit(.ear)
        for _ in 0..<QuietZoneVirtualMicSurveyController.windowsPerVisit {
            survey.ingestWindow(Dictionary(uniqueKeysWithValues: frequencies.map { ($0, rig.twin.noiseAtEar($0)) }))
        }
    }

    func testSurveyRecoversTheRatioAndDesignsAtTheEarWithinThreeDBAtEightRates() throws {
        for rate in rates {
            let rig = try makeRig(rate: rate)
            let frequencies = [60.0, 80.0]
            runSurvey(rig, frequencies: frequencies)
            XCTAssertEqual(rig.survey.phase, .ready, "rate \(rate)")
            XCTAssertEqual(rig.survey.tones.count, 2, "rate \(rate)")
            rig.survey.useAtEar = true
            XCTAssertTrue(rig.survey.isActive)

            for f in frequencies {
                let tone = try XCTUnwrap(rig.survey.earTone(near: f), "rate \(rate)")
                // The surveyed ratio is the ear noise over the monitor noise.
                let truth = rig.twin.noiseAtEar(f) / rig.twin.noiseAtMonitor(f)
                XCTAssertEqual(tone.ratio.magnitude, truth.magnitude, accuracy: 1e-6, "rate \(rate)")

                let paths = try rig.quietZone.surveyPaths(frequencyHz: f, earPositionID: rig.earID)
                let design = try XCTUnwrap(
                    try rig.quietZone.virtualEarDesign(
                        frequencyHz: f, monitorDisturbance: rig.twin.noiseAtMonitor(f),
                        monitorLeft: paths.monitorLeft, monitorRight: paths.monitorRight,
                        bassMode: .free, injectionPeakOverride: 0.5),
                    "rate \(rate) f \(f)")

                // A real error microphone at the ear, designing against the true ear noise.
                let real = try ActiveQuietZonePlanner().solveStereo(
                    frequencyHz: f, disturbance: rig.twin.noiseAtEar(f),
                    leftSecondaryPath: paths.earLeft, rightSecondaryPath: paths.earRight,
                    availableInjectionPeak: 0.5, configuration: rig.quietZone.configuration)
                let achievedAtEar = rig.twin.noiseAtEar(f)
                    + paths.earLeft * design.left + paths.earRight * design.right
                let achievedDB = 20 * log10(rig.twin.noiseAtEar(f).magnitude / achievedAtEar.magnitude)
                XCTAssertEqual(achievedDB, real.predictedReductionDB, accuracy: 3, "rate \(rate) f \(f)")
                XCTAssertGreaterThan(achievedDB, 3, "rate \(rate) f \(f)")
                // The monitor microphone is held to the other-seat limit.
                let monitor = rig.twin.noiseAtMonitor(f)
                    + paths.monitorLeft * design.left + paths.monitorRight * design.right
                let monitorChange = 20 * log10(monitor.magnitude / rig.twin.noiseAtMonitor(f).magnitude)
                XCTAssertLessThanOrEqual(monitorChange, QuietZoneQualificationTargets.maximumOtherSeatIncreaseDB + 1e-6)
            }
        }
    }

    func testSwitchedOffOrUnsurveyedToneKeepsTheMonitorDesign() throws {
        let rig = try makeRig(rate: 48_000)
        runSurvey(rig, frequencies: [60])
        let paths = try rig.quietZone.surveyPaths(frequencyHz: 60, earPositionID: rig.earID)
        func design(_ f: Double) throws -> QuietZoneVirtualDesignResult? {
            try rig.quietZone.virtualEarDesign(
                frequencyHz: f, monitorDisturbance: rig.twin.noiseAtMonitor(f),
                monitorLeft: paths.monitorLeft, monitorRight: paths.monitorRight,
                bassMode: .free, injectionPeakOverride: 0.5)
        }
        // Surveyed but not switched on.
        XCTAssertNil(try design(60))
        rig.survey.useAtEar = true
        XCTAssertNotNil(try design(60))
        // A tone outside the survey.
        XCTAssertNil(try design(75))
        // Discarding the survey returns to the fixed seat.
        rig.survey.discardSurvey()
        XCTAssertNil(try design(60))
        XCTAssertFalse(rig.survey.useAtEar)
    }

    func testUnsteadyNoiseAndMissingEarRefuseTheSurvey() throws {
        let rig = try makeRig(rate: 48_000)
        runSurvey(rig, frequencies: [60], steady: false)
        XCTAssertTrue(rig.survey.tones.isEmpty)
        XCTAssertFalse(rig.survey.isActive)
        XCTAssertTrue(rig.survey.message.contains("noise not steady"), rig.survey.message)

        let noEar = QuietZoneVirtualMicSurveyController()
        noEar.beginVisit(.monitor)
        XCTAssertFalse(noEar.isCapturing)
    }

    func testEarPositionsExcludeTheMonitorModelAndChangingEarDiscardsTheSurvey() throws {
        let rig = try makeRig(rate: 48_000)
        XCTAssertEqual(rig.survey.earPositionCandidates.map(\.id), [rig.earID])
        runSurvey(rig, frequencies: [60])
        XCTAssertFalse(rig.survey.tones.isEmpty)
        rig.survey.selectEar(nil)
        XCTAssertTrue(rig.survey.tones.isEmpty)
        XCTAssertNil(rig.survey.ear)
    }

    func testFlagIsOffByDefaultAndSurveyIsNotAttachedWithoutIt() throws {
        XCTAssertFalse(FeatureFlags(defaults: UserDefaults(suiteName: UUID().uuidString)!).isEnabled(.virtualMicrophone))
    }
}
