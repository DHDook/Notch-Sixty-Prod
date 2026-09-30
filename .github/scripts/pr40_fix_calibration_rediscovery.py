from pathlib import Path

controller_path = Path("NotchSixty/State/RoomCorrectionCalibrationController.swift")
text = controller_path.read_text()
old = '''    private func discoverInputs() throws -> [AudioInputDevice] {
        let devices = try inputCatalog.inputDevices()
        inputDevices = devices
        if let selectedInputUID, devices.contains(where: { $0.uid == selectedInputUID }) {
            return devices
        }
        selectedInputUID = devices.first?.uid
        selectedInputChannelIndex = 0
        return devices
    }
'''
new = '''    private func discoverInputs() throws -> [AudioInputDevice] {
        let devices = try inputCatalog.inputDevices()
        inputDevices = devices
        if let selectedInputUID, devices.contains(where: { $0.uid == selectedInputUID }) {
            return devices
        }
        let replacementUID = devices.first?.uid
        if selectedInputUID != replacementUID {
            microphoneCalibration = nil
        }
        selectedInputUID = replacementUID
        selectedInputChannelIndex = 0
        return devices
    }
'''
if new not in text:
    if text.count(old) != 1:
        raise SystemExit(f"Unexpected discoverInputs anchor: found {text.count(old)}")
    text = text.replace(old, new, 1)
controller_path.write_text(text)


tests_path = Path("NotchSixtyTests/RoomCorrectionCalibrationControllerTests.swift")
text = tests_path.read_text()
fixture_anchor = '''    private struct InputCatalogFixture: InputDeviceCataloging {
        let devices: [AudioInputDevice]
        func inputDevices() throws -> [AudioInputDevice] { devices }
    }
'''
mutable_fixture = fixture_anchor + '''

    private final class MutableInputCatalogFixture: InputDeviceCataloging {
        var devices: [AudioInputDevice]

        init(devices: [AudioInputDevice]) {
            self.devices = devices
        }

        func inputDevices() throws -> [AudioInputDevice] { devices }
    }
'''
if "private final class MutableInputCatalogFixture" not in text:
    if text.count(fixture_anchor) != 1:
        raise SystemExit("Unexpected input catalog fixture anchor")
    text = text.replace(fixture_anchor, mutable_fixture, 1)

test_anchor = '''    func testAnalysisUsesOwnedMicrophoneCalibration() async throws {
'''
new_test = r'''    func testDeviceRediscoveryClearsCalibrationWhenSelectedMicrophoneDisappears() throws {
        let output = outputDevice()
        let first = inputDevice()
        let second = AudioInputDevice(
            deviceID: 24,
            uid: "rediscovered-input-fixture",
            name: "Rediscovered Measurement Mic",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [
                AudioSampleRateRange(minimum: 48_000, maximum: 48_000),
            ]
        )
        let catalog = MutableInputCatalogFixture(devices: [first])
        let controller = RoomCorrectionCalibrationController(
            engine: try engine(output: output),
            inputCatalog: catalog,
            permissionClient: PermissionFixture(status: .authorized)
        )
        controller.prepareForUse()
        _ = try controller.importMicrophoneCalibration(
            text: "20 1.0\n1000 0.0\n20000 -1.0",
            sourceName: "first.cal"
        )
        XCTAssertEqual(controller.selectedInputDevice?.uid, first.uid)
        XCTAssertNotNil(controller.microphoneCalibration)

        catalog.devices = [second]
        _ = try controller.refreshInputDevices()

        XCTAssertEqual(controller.selectedInputDevice?.uid, second.uid)
        XCTAssertEqual(controller.selectedInputChannelIndex, 0)
        XCTAssertNil(controller.microphoneCalibration)
    }

'''
if new_test not in text:
    if text.count(test_anchor) != 1:
        raise SystemExit("Unexpected calibration test anchor")
    text = text.replace(test_anchor, new_test + test_anchor, 1)
tests_path.write_text(text)
