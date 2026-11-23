import XCTest
@testable import NotchSixty

/// E12 S14 (G10): the output switch sequence against a fake transport. No test touches Core Audio.
@MainActor
final class LiveOutputSwitchTests: XCTestCase {
    private final class FakeTransport: OutputSwitchTransport {
        var isProcessing: Bool
        var selectedOutputUID: String?
        var availableOutputs: [(uid: String, name: String)] = [("dac-a", "DAC A"), ("dac-b", "DAC B")]
        var failStartOn: Set<String> = []
        var calls: [String] = []

        init(processing: Bool, selected: String?) { isProcessing = processing; selectedOutputUID = selected }

        func stopProcessing() { calls.append("stop"); isProcessing = false }
        func selectOutput(uid: String?) throws { calls.append("select:\(uid ?? "none")"); selectedOutputUID = uid }
        func startProcessing() async throws {
            calls.append("start:\(selectedOutputUID ?? "none")")
            if let uid = selectedOutputUID, failStartOn.contains(uid) {
                throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "failsafe refused"])
            }
            isProcessing = true
        }
    }

    func testSwitchWhileRunningStopsSelectsAndStarts() async {
        let t = FakeTransport(processing: true, selected: "dac-a")
        let outcome = await LiveOutputSwitch(transport: t).switchOutput(to: "dac-b")
        XCTAssertEqual(outcome, .switched(name: "DAC B"))
        XCTAssertEqual(t.calls, ["stop", "select:dac-b", "start:dac-b"])
        XCTAssertTrue(t.isProcessing)
        XCTAssertNil(outcome.errorMessage)
    }

    func testSwitchWhileStoppedOnlySelects() async {
        let t = FakeTransport(processing: false, selected: "dac-a")
        let outcome = await LiveOutputSwitch(transport: t).switchOutput(to: "dac-b")
        XCTAssertEqual(outcome, .selected(name: "DAC B"))
        XCTAssertEqual(t.calls, ["select:dac-b"])
    }

    func testChoosingTheSameOutputDoesNothing() async {
        let t = FakeTransport(processing: true, selected: "dac-a")
        let outcome = await LiveOutputSwitch(transport: t).switchOutput(to: "dac-a")
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertTrue(t.calls.isEmpty)
    }

    func testAbsentDeviceIsRefusedWithoutInterruptingAudio() async {
        let t = FakeTransport(processing: true, selected: "dac-a")
        let outcome = await LiveOutputSwitch(transport: t).switchOutput(to: "gone")
        guard case .refused = outcome else { return XCTFail("expected refusal, got \(outcome)") }
        XCTAssertTrue(t.calls.isEmpty)
        XCTAssertTrue(t.isProcessing)
        XCTAssertEqual(t.selectedOutputUID, "dac-a")
        XCTAssertNotNil(outcome.errorMessage)
    }

    func testFailedStartReturnsToThePreviousDeviceWithANamedReason() async {
        let t = FakeTransport(processing: true, selected: "dac-a")
        t.failStartOn = ["dac-b"]
        let outcome = await LiveOutputSwitch(transport: t).switchOutput(to: "dac-b")
        guard case let .rolledBack(reason) = outcome else { return XCTFail("expected rollback, got \(outcome)") }
        XCTAssertTrue(reason.contains("DAC B"))
        XCTAssertTrue(reason.contains("failsafe refused"))
        XCTAssertEqual(t.selectedOutputUID, "dac-a")
        XCTAssertTrue(t.isProcessing)
        XCTAssertEqual(t.calls, ["stop", "select:dac-b", "start:dac-b", "stop", "select:dac-a", "start:dac-a"])
    }

    func testBothDevicesFailingLeavesProcessingStopped() async {
        let t = FakeTransport(processing: true, selected: "dac-a")
        t.failStartOn = ["dac-a", "dac-b"]
        let outcome = await LiveOutputSwitch(transport: t).switchOutput(to: "dac-b")
        guard case .stoppedAfterFailure = outcome else { return XCTFail("expected stop, got \(outcome)") }
        XCTAssertFalse(t.isProcessing)
    }

    func testClearingTheOutputStopsAndDoesNotRestart() async {
        let t = FakeTransport(processing: true, selected: "dac-a")
        let outcome = await LiveOutputSwitch(transport: t).switchOutput(to: nil)
        XCTAssertEqual(outcome, .cleared)
        XCTAssertEqual(t.calls, ["stop", "select:none"])
    }

    func testOnlyTheUsersChoiceIsEverSelected() async {
        // The switch has no input but the user's UID and the engine's own list: it cannot follow the macOS default.
        let t = FakeTransport(processing: true, selected: "dac-a")
        t.failStartOn = ["dac-b"]
        _ = await LiveOutputSwitch(transport: t).switchOutput(to: "dac-b")
        let selected = t.calls.filter { $0.hasPrefix("select:") }
        XCTAssertEqual(selected, ["select:dac-b", "select:dac-a"])
    }

    func testEngineTransportListsTheEngineOutputsAndStopsAtIdle() {
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        let transport = OutputSwitchEngineTransport(engine: engine, start: {})
        XCTAssertFalse(transport.isProcessing)
        XCTAssertNil(transport.selectedOutputUID)
        XCTAssertTrue(transport.availableOutputs.isEmpty)
    }
}
