import XCTest
@testable import NotchSixty

/// Test double: a microphone list the test changes while the app runs.
final class MutableInputCatalog: InputDeviceCataloging, @unchecked Sendable {
    var devices: [AudioInputDevice]
    init(_ devices: [AudioInputDevice]) { self.devices = devices }
    func inputDevices() throws -> [AudioInputDevice] { devices }
}

struct AuthorizedMicrophonePermission: MicrophonePermissionRequesting, Sendable {
    func currentStatus() -> MicrophonePermissionStatus { .authorized }
    func requestAccess() async -> MicrophonePermissionStatus { .authorized }
}

/// E12 S22: microphone state, the Dashboard status lines and the Room Treatment words. The model is pure; the
/// microphone watch is driven with a catalog the test changes.
@MainActor
final class AcousticsStatusTests: XCTestCase {
    private func input(_ uid: String, _ name: String) -> AudioInputDevice {
        AudioInputDevice(
            deviceID: 7, uid: uid, name: name, nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 48_000)])
    }

    func testMicrophoneStatesAreDistinctAndPlain() {
        typealias M = AcousticsStatusModel
        XCTAssertEqual(M.microphoneState(permissionGranted: false, selectedName: nil, lostName: nil, monitorStatus: .stopped), .permissionNeeded)
        XCTAssertEqual(M.microphoneState(permissionGranted: true, selectedName: nil, lostName: nil, monitorStatus: .stopped), .notChosen)
        XCTAssertEqual(M.microphoneState(permissionGranted: true, selectedName: "Mic", lostName: nil, monitorStatus: .stopped), .ready(name: "Mic"))
        XCTAssertEqual(M.microphoneState(permissionGranted: true, selectedName: "Mic", lostName: nil, monitorStatus: .observing), .live(name: "Mic"))
        XCTAssertEqual(M.microphoneState(permissionGranted: true, selectedName: "Mic", lostName: nil, monitorStatus: .failed), .problem(name: "Mic"))
        XCTAssertEqual(M.microphoneState(permissionGranted: true, selectedName: nil, lostName: "Mic", monitorStatus: .stopped), .lost(name: "Mic"))
        XCTAssertTrue(AcousticsMicrophoneState.live(name: "Mic").isLive)
        XCTAssertFalse(AcousticsMicrophoneState.ready(name: "Mic").isLive)
        XCTAssertTrue(AcousticsMicrophoneState.lost(name: "Mic").detail.contains("stays off until you turn it on again"))
        XCTAssertTrue(AcousticsMicrophoneState.sharedNote.contains("both Playback Adaptation and Quiet Zone"))
    }

    func testStatusLinesAreOnePerFeatureAndReadOnly() {
        var i = AcousticsStatusInputs()
        var lines = AcousticsStatusModel.lines(i)
        XCTAssertEqual(lines.map(\.id), ["playbackAdaptation", "quietZone", "roomTreatment"])
        XCTAssertTrue(lines.allSatisfy { !$0.isOn })
        i.playbackAdaptationOn = true
        i.quietZoneArmed = true
        lines = AcousticsStatusModel.lines(i)
        XCTAssertTrue(lines[0].isOn)
        XCTAssertTrue(lines[1].isOn)
        i.microphoneLost = true
        i.quietZoneArmed = false
        i.quietZoneOffReason = LiveTreatmentDisarmReason.inputLost.message
        lines = AcousticsStatusModel.lines(i)
        XCTAssertEqual(lines[0].text, "Paused, microphone lost")
        XCTAssertFalse(lines[0].isOn)
        XCTAssertEqual(lines[1].text, LiveTreatmentDisarmReason.inputLost.message)
        i.roomTreatmentAvailable = false
        XCTAssertEqual(AcousticsStatusModel.lines(i).map(\.id), ["playbackAdaptation", "quietZone"])
    }

    func testTheDashboardCardShowsTheLinesAndKeepsTheOldLineWithout() {
        var inputs = DashboardInputs()
        inputs.acoustics = .staged
        XCTAssertEqual(DashboardModel.cards(inputs).first { $0.id == "acoustics" }?.line, "Ready for the next start")
        var status = AcousticsStatusInputs()
        status.quietZoneArmed = true
        inputs.acousticsStatus = AcousticsStatusModel.lines(status)
        let card = DashboardModel.cards(inputs).first { $0.id == "acoustics" }
        XCTAssertTrue(card?.isOn == true)
        XCTAssertTrue(card?.line.contains("Quiet Zone: On, reducing noise at your seat") == true)
        XCTAssertTrue(card?.line.contains("Playback Adaptation: Off") == true)
    }

    func testRoomTreatmentWordsSayWhatIsMissingAndHowItDiffers() {
        XCTAssertEqual(AcousticsStatusModel.roomTreatmentHeadline,
                       "You can design and preview. Turning it on needs a qualified setup.")
        let all = AcousticsStatusModel.roomTreatmentMissing(measuredSpeakers: false, designed: false, qualified: false, refusals: ["Extra"])
        XCTAssertEqual(all.count, 4)
        XCTAssertTrue(AcousticsStatusModel.roomTreatmentMissing(measuredSpeakers: true, designed: true, qualified: true, refusals: []).isEmpty)
        XCTAssertTrue(AcousticsStatusModel.roomTreatmentDifference.contains("Room Correction"))
        let texts = all + [AcousticsStatusModel.roomTreatmentHeadline, AcousticsStatusModel.roomTreatmentDifference]
        for text in texts {
            XCTAssertNil(text.range(of: #"\bPR\d+"#, options: .regularExpression), text)
        }
    }

    // MARK: Microphone watch

    private func makeRig() -> (RoomCorrectionCalibrationController, AmbientCompensationController, MutableInputCatalog) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let engine = AudioIOEngine()
        let catalog = MutableInputCatalog([input("mic", "Measurement Mic"), input("other", "Other Mic")])
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        let calibration = RoomCorrectionCalibrationController(
            engine: engine, inputCatalog: catalog, permissionClient: AuthorizedMicrophonePermission())
        calibration.prepareForUse()
        calibration.selectInput(uid: "mic")
        let projects = RoomCorrectionProjectController(
            profiles: profiles, store: RoomCorrectionProjectStore(rootDirectory: root.appendingPathComponent("rc", isDirectory: true)))
        let ambient = AmbientCompensationController(engine: engine, profiles: profiles, microphone: calibration, projects: projects)
        return (calibration, ambient, catalog)
    }

    func testTheChosenMicrophoneIsKeptWhileLostAndResumesByUID() {
        let (calibration, _, catalog) = makeRig()
        XCTAssertNil(calibration.checkInputPresence(), "nothing changed")
        catalog.devices = [input("other", "Other Mic")]
        XCTAssertEqual(calibration.checkInputPresence(), .lost(name: "Measurement Mic"))
        XCTAssertNil(calibration.checkInputPresence(), "reported once")
        XCTAssertEqual(calibration.selectedInputUID, "mic", "the choice is kept, not swapped for another device")
        XCTAssertNil(calibration.selectedInputDevice)
        XCTAssertEqual(calibration.lostInput?.name, "Measurement Mic")
        catalog.devices = [input("other", "Other Mic"), input("mic", "Measurement Mic")]
        XCTAssertEqual(calibration.checkInputPresence(), .returned(name: "Measurement Mic"))
        XCTAssertNil(calibration.lostInput)
        XCTAssertEqual(calibration.selectedInputDevice?.uid, "mic")
    }

    func testChoosingAnotherMicrophoneWhileLostClearsTheLostState() {
        let (calibration, _, catalog) = makeRig()
        catalog.devices = [input("other", "Other Mic")]
        _ = calibration.checkInputPresence()
        calibration.selectInput(uid: "other")
        XCTAssertNil(calibration.checkInputPresence())
        XCTAssertNil(calibration.lostInput)
        catalog.devices = [input("other", "Other Mic"), input("mic", "Measurement Mic")]
        XCTAssertNil(calibration.checkInputPresence(), "the old microphone coming back changes nothing")
        XCTAssertEqual(calibration.selectedInputUID, "other")
    }

    func testALostMicrophoneStopsMonitoringAndTellsQuietZone() {
        let (calibration, ambient, catalog) = makeRig()
        var told = 0
        ambient.onMicrophoneLost = { told += 1 }
        catalog.devices = [input("other", "Other Mic")]
        ambient.checkMicrophonePresence()
        XCTAssertEqual(told, 1)
        XCTAssertEqual(ambient.monitorStatus, .stopped)
        XCTAssertNotNil(calibration.lostInput)
        ambient.checkMicrophonePresence()
        XCTAssertEqual(told, 1, "once per loss")
    }
}
