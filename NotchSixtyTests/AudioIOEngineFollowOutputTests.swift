import XCTest
@testable import NotchSixty

/// E15 S2: the engine entry with fakes. An idle engine only updates its selection; the follow cause disarms as an
/// output change; the engine takes an injected hardware-event monitor.
@MainActor
final class AudioIOEngineFollowOutputTests: XCTestCase {
    private struct Catalog: OutputDeviceCataloging {
        let devices: [AudioOutputDevice]
        func outputDevices() throws -> [AudioOutputDevice] { devices }
    }

    private final class FakeMonitor: AudioHardwareEvents {
        var onDeviceListChanged: (() -> Void)?
        var onSelectedOutputSampleRateChanged: (() -> Void)?
        var onWillSleep: (() -> Void)?
        var onDidWake: (() -> Void)?
        var started = 0
        func start() throws { started += 1 }
        func monitorSampleRate(of deviceID: AudioDeviceID?) throws {}
        func removeSelectedOutputSampleRateMonitor() {}
        func stop() {}
    }

    func testIdleEngineOnlyUpdatesSelection() throws {
        let device = AudioOutputDevice(
            deviceID: 7, uid: "usb", name: "USB", nominalSampleRate: 96_000,
            availableSampleRateRanges: [], outputChannelCount: 2)
        let monitor = FakeMonitor()
        let engine = AudioIOEngine(deviceCatalog: Catalog(devices: [device]), eventMonitor: monitor)
        try engine.switchFollowedOutput(to: "usb")
        XCTAssertEqual(engine.selectedOutputUID, "usb")
        XCTAssertEqual(engine.lifecycleState, .idle)
    }

    func testUnknownOutputThrowsAndKeepsSelection() {
        let engine = AudioIOEngine(deviceCatalog: Catalog(devices: []), eventMonitor: FakeMonitor())
        XCTAssertThrowsError(try engine.switchFollowedOutput(to: "gone"))
        XCTAssertNil(engine.selectedOutputUID)
    }

    func testFollowTeardownDisarmsAsOutputChange() {
        XCTAssertEqual(TransportTeardownCause.followOutput.disarmReason, .outputDeviceChanged)
    }
}
