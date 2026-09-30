from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Unexpected {label}: found {count} anchors")
    return text.replace(old, new, 1)


# Controller: own the active calibration, invalidate it when physical input identity
# changes, and use it automatically for offline analysis.
controller_path = Path("NotchSixty/State/RoomCorrectionCalibrationController.swift")
text = controller_path.read_text()
text = replace_once(
    text,
    "    @Published private(set) var selectedInputChannelIndex = 0\n",
    "    @Published private(set) var selectedInputChannelIndex = 0\n"
    "    @Published private(set) var microphoneCalibration: RoomCorrectionMicrophoneCalibration?\n",
    "controller calibration property",
)

old_select = '''    func selectInput(uid: String?) {
        guard activeTransport == nil else { return }
        guard let uid else {
            selectedInputUID = nil
            selectedInputChannelIndex = 0
            return
        }
        guard inputDevices.contains(where: { $0.uid == uid }) else { return }
        selectedInputUID = uid
        selectedInputChannelIndex = 0
        lastErrorDescription = nil
    }

    func selectInputChannel(index: Int) throws {
        guard activeTransport == nil else {
            throw RoomCorrectionCalibrationControllerError.measurementAlreadyActive
        }
        guard index >= 0 else {
            throw RoomCorrectionCalibrationControllerError.invalidInputChannel(index)
        }
        selectedInputChannelIndex = index
        lastErrorDescription = nil
    }
'''
new_select = '''    func selectInput(uid: String?) {
        guard activeTransport == nil else { return }
        guard let uid else {
            if selectedInputUID != nil { microphoneCalibration = nil }
            selectedInputUID = nil
            selectedInputChannelIndex = 0
            return
        }
        guard inputDevices.contains(where: { $0.uid == uid }) else { return }
        if selectedInputUID != uid { microphoneCalibration = nil }
        selectedInputUID = uid
        selectedInputChannelIndex = 0
        lastErrorDescription = nil
    }

    func selectInputChannel(index: Int) throws {
        guard activeTransport == nil else {
            throw RoomCorrectionCalibrationControllerError.measurementAlreadyActive
        }
        guard index >= 0 else {
            throw RoomCorrectionCalibrationControllerError.invalidInputChannel(index)
        }
        if selectedInputChannelIndex != index { microphoneCalibration = nil }
        selectedInputChannelIndex = index
        lastErrorDescription = nil
    }

    @discardableResult
    func importMicrophoneCalibration(
        text: String,
        sourceName: String? = nil
    ) throws -> RoomCorrectionMicrophoneCalibration {
        let parsed = try RoomCorrectionMicrophoneCalibrationParser().parse(
            text,
            sourceName: sourceName
        )
        microphoneCalibration = parsed
        lastErrorDescription = nil
        return parsed
    }

    func setMicrophoneCalibration(_ calibration: RoomCorrectionMicrophoneCalibration?) throws {
        if let calibration {
            _ = try calibration.gainDB(at: 1.0)
        }
        microphoneCalibration = calibration
        lastErrorDescription = nil
    }

    func clearMicrophoneCalibration() {
        microphoneCalibration = nil
        lastErrorDescription = nil
    }
'''
text = replace_once(text, old_select, new_select, "controller input/calibration methods")

old_analysis = '''        let generation = analysisGeneration
        do {
            let analysis = try await analysisOperation(capture, plan, microphoneCalibration)
'''
new_analysis = '''        let generation = analysisGeneration
        let activeMicrophoneCalibration = microphoneCalibration ?? self.microphoneCalibration
        do {
            let analysis = try await analysisOperation(capture, plan, activeMicrophoneCalibration)
'''
text = replace_once(text, old_analysis, new_analysis, "analysis calibration threading")
controller_path.write_text(text)


# Production Setup UI: import/clear calibration through the sandbox file picker,
# restore the selected Playback System project's curve, and persist the same
# curve used by analysis into first-position metadata.
ui_path = Path("NotchSixty/UI/ProductionRoomCorrectionWorkspace.swift")
text = ui_path.read_text()
text = replace_once(
    text,
    "import SwiftUI\n",
    "import Foundation\nimport SwiftUI\nimport UniformTypeIdentifiers\n",
    "UI imports",
)
text = replace_once(
    text,
    "    @State private var positionName = \"\"\n",
    "    @State private var positionName = \"\"\n"
    "    @State private var importingMicrophoneCalibration = false\n",
    "UI calibration importer state",
)

input_anchor = '''                LabeledContent("Microphone Channel") {
                    Stepper(
                        "Input \\(calibration.selectedInputChannelIndex + 1)",
                        value: inputChannelBinding,
                        in: 1...32
                    )
                    .disabled(
                        calibration.selectedInputDevice == nil
                            || calibration.state == .measuring
                            || calibration.state == .arming
                    )
                }
'''
calibration_ui = input_anchor + '''

                LabeledContent("Microphone Calibration") {
                    HStack(spacing: 10) {
                        Text(calibration.microphoneCalibration?.sourceName ?? "No calibration curve")
                            .foregroundStyle(calibration.microphoneCalibration == nil ? .secondary : .primary)
                            .lineLimit(1)

                        Button("Import…") {
                            actionError = nil
                            importingMicrophoneCalibration = true
                        }
                        .disabled(calibration.state == .measuring || calibration.state == .arming)

                        Button("Clear") {
                            actionError = nil
                            calibration.clearMicrophoneCalibration()
                        }
                        .disabled(
                            calibration.microphoneCalibration == nil
                                || calibration.state == .measuring
                                || calibration.state == .arming
                        )
                    }
                }

                if let microphoneCalibration = calibration.microphoneCalibration {
                    Text("\\(microphoneCalibration.points.count) calibration points. The curve is applied to offline measurement analysis only; it is never inserted into daily playback DSP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
'''
text = replace_once(text, input_anchor, calibration_ui, "microphone calibration setup UI")

old_project_task = '''        .task(id: profiles.selectedSystemProfileID) {
            projects.prepareForUse()
        }
'''
new_project_task = '''        .task(id: profiles.selectedSystemProfileID) {
            projects.prepareForUse()
            do {
                try calibration.setMicrophoneCalibration(projects.project?.microphone?.calibration)
            } catch {
                actionError = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $importingMicrophoneCalibration,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            importMicrophoneCalibrationFile(result)
        }
'''
text = replace_once(text, old_project_task, new_project_task, "project/calibration task")

text = replace_once(
    text,
    "            calibration: projects.project?.microphone?.calibration\n",
    "            calibration: calibration.microphoneCalibration\n",
    "retained microphone calibration",
)

method_anchor = '''    private func retainReviewedMeasurement(_ analysis: RoomCorrectionMeasurementAnalysis) {
'''
import_method = r'''    private func importMicrophoneCalibrationFile(_ result: Result<URL, Error>) {
        actionError = nil
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                actionError = "Microphone calibration files must be UTF-8 text with frequency and gain columns."
                return
            }
            _ = try calibration.importMicrophoneCalibration(
                text: text,
                sourceName: url.lastPathComponent
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

'''
if import_method not in text:
    if text.count(method_anchor) != 1:
        raise SystemExit("Unexpected retain method anchor")
    text = text.replace(method_anchor, import_method + method_anchor, 1)
ui_path.write_text(text)


# Sandbox: user-selected read-only file access for calibration import.
entitlements_path = Path("NotchSixty/NotchSixty.entitlements")
text = entitlements_path.read_text()
if "com.apple.security.files.user-selected.read-only" not in text:
    text = replace_once(
        text,
        "\t<key>com.apple.security.device.audio-input</key>\n\t<true/>\n",
        "\t<key>com.apple.security.device.audio-input</key>\n\t<true/>\n"
        "\t<key>com.apple.security.files.user-selected.read-only</key>\n\t<true/>\n",
        "user-selected file entitlement",
    )
entitlements_path.write_text(text)


# Controller tests: parser ownership/invalidation plus proof that owned calibration
# is the exact object sent to the analysis operation.
tests_path = Path("NotchSixtyTests/RoomCorrectionCalibrationControllerTests.swift")
text = tests_path.read_text()
actor_anchor = '''    private actor AnalysisGate {
'''
recorder = '''    private actor CalibrationRecorder {
        private var value: RoomCorrectionMicrophoneCalibration?

        func record(_ calibration: RoomCorrectionMicrophoneCalibration?) {
            value = calibration
        }

        func snapshot() -> RoomCorrectionMicrophoneCalibration? { value }
    }

'''
if recorder not in text:
    if text.count(actor_anchor) != 1:
        raise SystemExit("Unexpected analysis gate anchor")
    text = text.replace(actor_anchor, recorder + actor_anchor, 1)

test_anchor = '''    func testAnalysisFailureFailsClosedAndKeepsResultUnpublished() async throws {
'''
new_tests = r'''    func testMicrophoneCalibrationImportIsOwnedAndInvalidatedByInputChange() throws {
        let output = outputDevice()
        let first = inputDevice()
        let second = AudioInputDevice(
            deviceID: 23,
            uid: "second-input-fixture",
            name: "Second Measurement Mic",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [
                AudioSampleRateRange(minimum: 48_000, maximum: 48_000),
            ]
        )
        let controller = RoomCorrectionCalibrationController(
            engine: try engine(output: output),
            inputCatalog: InputCatalogFixture(devices: [first, second]),
            permissionClient: PermissionFixture(status: .authorized)
        )
        controller.prepareForUse()

        let imported = try controller.importMicrophoneCalibration(
            text: "20 1.5\n1000 -2.0\n20000 -0.5",
            sourceName: "fixture.cal"
        )

        XCTAssertEqual(controller.microphoneCalibration, imported)
        XCTAssertEqual(imported.sourceName, "fixture.cal")
        XCTAssertEqual(imported.points.count, 3)

        controller.selectInput(uid: second.uid)
        XCTAssertNil(controller.microphoneCalibration)
    }

    func testAnalysisUsesOwnedMicrophoneCalibration() async throws {
        let output = outputDevice()
        let input = inputDevice()
        let transport = TransportFixture()
        let expected = analysisResult()
        let recorder = CalibrationRecorder()
        let controller = RoomCorrectionCalibrationController(
            engine: try engine(output: output),
            inputCatalog: InputCatalogFixture(devices: [input]),
            permissionClient: PermissionFixture(status: .authorized),
            transportFactory: { _, _, _, _ in transport },
            analysisOperation: { _, _, calibration in
                await recorder.record(calibration)
                return expected
            }
        )
        controller.prepareForUse()
        let imported = try controller.importMicrophoneCalibration(
            text: "20 1.0\n1000 2.0\n20000 3.0",
            sourceName: "owned.cal"
        )
        try controller.beginMeasurement()
        _ = try controller.finishMeasurement()

        let published = await controller.analyzeLatestCapture()
        let received = await recorder.snapshot()

        XCTAssertTrue(published)
        XCTAssertEqual(received, imported)
        XCTAssertEqual(controller.latestAnalysis, expected)
    }

'''
if new_tests not in text:
    if text.count(test_anchor) != 1:
        raise SystemExit("Unexpected analysis-failure test anchor")
    text = text.replace(test_anchor, new_tests + test_anchor, 1)
tests_path.write_text(text)
