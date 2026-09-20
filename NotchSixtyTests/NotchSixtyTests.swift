import CoreAudio
import XCTest
@testable import NotchSixty

final class NotchSixtyTests: XCTestCase {
    func testBootstrapTestBundleRuns() {
        XCTAssertTrue(true)
    }

    func testSampleRateRangeNormalizesBoundsAndMatchesRates() {
        let range = AudioSampleRateRange(minimum: 192_000, maximum: 44_100)

        XCTAssertEqual(range.minimum, 44_100)
        XCTAssertEqual(range.maximum, 192_000)
        XCTAssertTrue(range.contains(96_000))
        XCTAssertFalse(range.contains(384_000))
    }

    func testLifecycleAcceptsProductionStartupPath() throws {
        var machine = AudioLifecycleStateMachine()
        let startupPath: [AudioLifecycleState] = [
            .requestingPermission,
            .creatingTap,
            .creatingAggregate,
            .openingOutput,
            .starting,
            .running,
        ]

        for state in startupPath {
            try machine.transition(to: state)
        }

        XCTAssertEqual(machine.state, .running)
    }

    func testLifecycleRejectsInvalidJumpWithoutMutatingState() {
        var machine = AudioLifecycleStateMachine()

        XCTAssertThrowsError(try machine.transition(to: .running)) { error in
            XCTAssertEqual(
                error as? AudioLifecycleTransitionError,
                AudioLifecycleTransitionError(from: .idle, to: .running)
            )
        }
        XCTAssertEqual(machine.state, .idle)
    }

    @MainActor
    func testSelectionFollowsStableUIDAcrossTransientDeviceIDChange() throws {
        let catalog = StubOutputDeviceCatalog(devices: [
            makeDevice(deviceID: 10, uid: "device-a", name: "Output A"),
            makeDevice(deviceID: 20, uid: "device-b", name: "Output B"),
        ])
        let engine = AudioIOEngine(deviceCatalog: catalog)

        try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "device-b")
        XCTAssertEqual(engine.selectedOutputDevice?.deviceID, 20)

        catalog.devices = [
            makeDevice(deviceID: 99, uid: "device-b", name: "Output B"),
        ]
        try engine.refreshOutputDevices()

        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "device-b")
        XCTAssertEqual(engine.selectedOutputDevice?.deviceID, 99)
    }

    @MainActor
    func testRefreshPreservesSelectedUIDWhenHardwareDisappears() throws {
        let catalog = StubOutputDeviceCatalog(devices: [
            makeDevice(deviceID: 20, uid: "device-b", name: "Output B"),
        ])
        let engine = AudioIOEngine(deviceCatalog: catalog)

        try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "device-b")

        catalog.devices = []
        try engine.refreshOutputDevices()

        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "device-b")
        XCTAssertNil(engine.selectedOutputDevice)

        let snapshot = engine.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.selectedOutputUID, "device-b")
        XCTAssertFalse(snapshot.selectedOutputPresent)
        XCTAssertEqual(snapshot.discoveredOutputCount, 0)
    }

    @MainActor
    func testSelectingUnavailableOutputFailsWithoutChangingRoute() throws {
        let catalog = StubOutputDeviceCatalog(devices: [
            makeDevice(deviceID: 10, uid: "device-a", name: "Output A"),
        ])
        let engine = AudioIOEngine(
            deviceCatalog: catalog,
            initialRouteConfiguration: AudioRouteConfiguration(selectedOutputUID: "persisted-device")
        )

        try engine.refreshOutputDevices()

        XCTAssertThrowsError(try engine.selectOutput(uid: "missing-device")) { error in
            XCTAssertEqual(
                error as? AudioRouteSelectionError,
                .outputDeviceUnavailable(uid: "missing-device")
            )
        }
        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "persisted-device")
    }

    private func makeDevice(deviceID: AudioDeviceID, uid: String, name: String) -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: deviceID,
            uid: uid,
            name: name,
            nominalSampleRate: 96_000,
            availableSampleRateRanges: [
                AudioSampleRateRange(minimum: 44_100, maximum: 384_000),
            ]
        )
    }
}

private final class StubOutputDeviceCatalog: OutputDeviceCataloging {
    var devices: [AudioOutputDevice]

    init(devices: [AudioOutputDevice]) {
        self.devices = devices
    }

    func outputDevices() throws -> [AudioOutputDevice] {
        devices
    }
}
