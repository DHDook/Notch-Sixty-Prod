import CoreAudio
import XCTest
@testable import NotchSixty

/// E15 S6: transport kinds, the linked headphone entry on an output change (closes E13 G27), and the wireless output
/// policy (defaults, notes, and the `.wirelessOutput` refusals). Fake devices and fake store; no hardware.
@MainActor
final class WirelessOutputAndLinkedHeadphoneTests: XCTestCase {
    private static let standardRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Transport kinds

    func testEveryTransportConstantMapsToItsKind() {
        let cases: [(UInt32, OutputTransportKind)] = [
            (kAudioDeviceTransportTypeBuiltIn, .builtIn), (kAudioDeviceTransportTypeUSB, .usb),
            (kAudioDeviceTransportTypeFireWire, .fireWire), (kAudioDeviceTransportTypeThunderbolt, .thunderbolt),
            (kAudioDeviceTransportTypePCI, .pci), (kAudioDeviceTransportTypeHDMI, .hdmi),
            (kAudioDeviceTransportTypeDisplayPort, .displayPort), (kAudioDeviceTransportTypeBluetooth, .bluetooth),
            (kAudioDeviceTransportTypeBluetoothLE, .bluetoothLE), (kAudioDeviceTransportTypeAirPlay, .airPlay),
            (kAudioDeviceTransportTypeAggregate, .aggregate), (kAudioDeviceTransportTypeVirtual, .virtual),
            (kAudioDeviceTransportTypeUnknown, .unknown),
        ]
        for (constant, kind) in cases { XCTAssertEqual(OutputTransportKind(coreAudioTransportType: constant), kind) }
    }

    func testUnrecognisedTransportValuesAreUnknown() {
        for value: UInt32 in [0, 1, 0x1234_5678, UInt32.max] {
            XCTAssertEqual(OutputTransportKind(coreAudioTransportType: value), .unknown)
        }
    }

    func testOnlyBluetoothAndAirPlayAreWireless() {
        let wireless = OutputTransportKind.allCases.filter(\.isWireless)
        XCTAssertEqual(Set(wireless), [.bluetooth, .bluetoothLE, .airPlay])
    }

    func testDeviceModelCarriesTransportAndDiagnosticsReportsIt() throws {
        let device = AudioOutputDevice(
            deviceID: 7, uid: "bt", name: "Headset", nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 8_000, maximum: 48_000)], transport: .bluetooth)
        XCTAssertEqual(device.transport, .bluetooth)
        let catalog = Catalog(devices: [device])
        let engine = AudioIOEngine(deviceCatalog: catalog)
        try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "bt")
        XCTAssertEqual(engine.diagnosticsSnapshot().selectedOutputTransport, .bluetooth)
    }

    // MARK: Linked headphone entry (E13 G27)

    private final class FakeProfiles: LinkedHeadphoneProfiles {
        var list: HeadphoneList?
        var edits = 0
        var failEdit = false
        var selectedSystemHeadphoneList: HeadphoneList? { list }
        func editSelectedSystemHeadphoneList(_ change: (inout HeadphoneList) throws -> Void) throws {
            if failEdit { throw HeadphoneListError.unknownEntry }
            var copy = list ?? HeadphoneList()
            try change(&copy)
            list = copy
            edits += 1
        }
    }

    private func twoHeadphones(linking uid: String?) throws -> (HeadphoneList, UUID, UUID) {
        var list = HeadphoneList()
        let a = try list.add(name: "Studio", enabled: true, outputDeviceUID: nil)
        let b = try list.add(name: "Travel", enabled: true, outputDeviceUID: nil)
        try list.select(a)
        if let uid { try list.link(b, toOutputUID: uid) }
        return (list, a, b)
    }

    func testLinkedEntryIsSelectedWhenItsDeviceBecomesTheOutput() throws {
        let profiles = FakeProfiles()
        let (list, _, b) = try twoHeadphones(linking: "usb-dac")
        profiles.list = list
        let selector = LinkedHeadphoneSelector(profiles: profiles, flagEnabled: { true })
        XCTAssertEqual(selector.outputBecameSelected("usb-dac"), .selected(b))
        XCTAssertEqual(profiles.list?.selectedID, b)
        XCTAssertEqual(profiles.edits, 1)
    }

    func testUnlinkedDeviceLeavesTheSelectionAlone() throws {
        let profiles = FakeProfiles()
        let (list, a, _) = try twoHeadphones(linking: "usb-dac")
        profiles.list = list
        let selector = LinkedHeadphoneSelector(profiles: profiles, flagEnabled: { true })
        XCTAssertEqual(selector.outputBecameSelected("other"), .notLinked)
        XCTAssertEqual(selector.outputBecameSelected(nil), .notLinked)
        XCTAssertEqual(profiles.list?.selectedID, a)
        XCTAssertEqual(profiles.edits, 0)
    }

    func testAlreadySelectedEntryCausesNoEditAndNoReconfigure() throws {
        let profiles = FakeProfiles()
        let (list, a, _) = try twoHeadphones(linking: nil)
        var linked = list
        try linked.link(a, toOutputUID: "usb-dac")
        profiles.list = linked
        let selector = LinkedHeadphoneSelector(profiles: profiles, flagEnabled: { true })
        XCTAssertEqual(selector.outputBecameSelected("usb-dac"), .alreadySelected(a))
        XCTAssertEqual(profiles.edits, 0)
    }

    func testFlagOffAndNoListDoNothingAndAFailedEditIsReported() throws {
        let profiles = FakeProfiles()
        let (list, _, _) = try twoHeadphones(linking: "usb-dac")
        profiles.list = list
        XCTAssertEqual(LinkedHeadphoneSelector(profiles: profiles, flagEnabled: { false }).outputBecameSelected("usb-dac"), .flagOff)
        XCTAssertEqual(profiles.edits, 0)

        let empty = FakeProfiles()
        XCTAssertEqual(LinkedHeadphoneSelector(profiles: empty, flagEnabled: { true }).outputBecameSelected("usb-dac"), .notLinked)

        profiles.failEdit = true
        let selector = LinkedHeadphoneSelector(profiles: profiles, flagEnabled: { true })
        guard case .failed = selector.outputBecameSelected("usb-dac") else { return XCTFail("a failed edit is reported") }
        XCTAssertNotNil(selector.lastError)
    }

    /// A manual pick, a followed switch, the remote panel and setup all end in `selectOutput`; the observer sees each.
    func testEngineOutputChangeSelectsTheLinkedEntryThroughTheObserver() async throws {
        let catalog = Catalog(devices: [device("a"), device("usb-dac")])
        let engine = AudioIOEngine(deviceCatalog: catalog)
        try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "a")
        let profiles = FakeProfiles()
        let (list, _, b) = try twoHeadphones(linking: "usb-dac")
        profiles.list = list
        let selector = LinkedHeadphoneSelector(profiles: profiles, flagEnabled: { true })
        let subscription = selector.observeOutput(of: engine)
        try engine.selectOutput(uid: "usb-dac")
        for _ in 0..<50 where profiles.list?.selectedID != b { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(profiles.list?.selectedID, b)
        XCTAssertEqual(profiles.edits, 1)
        subscription.cancel()
    }

    // MARK: Wireless policy

    func testNewSystemDefaultsAreLowLatencyAndInsideTheBudgetAtEveryRate() {
        for transport in [OutputTransportKind.bluetooth, .bluetoothLE, .airPlay] {
            let defaults = WirelessOutputPolicy.newSystemDefaults(transport: transport, flagOn: true)
            XCTAssertEqual(defaults?.correctionMode, .video, "minimum-phase room correction")
            XCTAssertEqual(defaults?.eqPhaseMode, .minimumPhase, "linear-phase EQ off")
            XCTAssertEqual(defaults?.budgetMilliseconds, 20)
            XCTAssertLessThanOrEqual(WirelessOutputPolicy.addedLatencyMilliseconds(of: defaults!), 20)
        }
        // The added delay is rate-independent for these defaults, so the check holds at each standard rate and at a
        // wireless device's own rates.
        for rate in Self.standardRates + [8_000, 16_000, 24_000, 32_000] {
            let defaults = WirelessOutputPolicy.newSystemDefaults(transport: .bluetooth, flagOn: true)!
            XCTAssertLessThanOrEqual(WirelessOutputPolicy.addedLatencyMilliseconds(of: defaults), 20, "at \(rate) Hz")
        }
    }

    func testWiredOutputsAndFlagOffKeepTheNormalDefaults() {
        XCTAssertNil(WirelessOutputPolicy.newSystemDefaults(transport: .usb, flagOn: true))
        XCTAssertNil(WirelessOutputPolicy.newSystemDefaults(transport: .bluetooth, flagOn: false))
        XCTAssertNil(WirelessOutputPolicy.newSystemDefaults(transport: nil, flagOn: true))
        XCTAssertEqual(WirelessOutputPolicy.defaultCorrectionMode(transport: .usb, flagOn: true), .music)
        XCTAssertEqual(WirelessOutputPolicy.defaultCorrectionMode(transport: .airPlay, flagOn: true), .video)
        XCTAssertEqual(WirelessOutputPolicy.defaultCorrectionMode(transport: .airPlay, flagOn: false), .music)
    }

    func testAnOverBudgetSystemGetsANoteAndAnInBudgetOneDoesNot() {
        for rate in Self.standardRates {
            let overFrames = UInt32(rate * 0.045)
            let note = WirelessOutputPolicy.overBudgetNote(latencyFrames: overFrames, sampleRate: rate, transport: .airPlay, flagOn: true)
            XCTAssertEqual(note?.contains("45 ms on top of the AirPlay delay"), true, "at \(rate) Hz")
            XCTAssertNil(WirelessOutputPolicy.overBudgetNote(
                latencyFrames: UInt32(rate * 0.015), sampleRate: rate, transport: .airPlay, flagOn: true))
        }
        XCTAssertEqual(
            WirelessOutputPolicy.overBudgetNote(latencyFrames: 480, sampleRate: 48_000, transport: .bluetooth, flagOn: true), nil)
        XCTAssertNil(WirelessOutputPolicy.overBudgetNote(latencyFrames: 48_000, sampleRate: 48_000, transport: .usb, flagOn: true))
        XCTAssertNil(WirelessOutputPolicy.overBudgetNote(latencyFrames: 48_000, sampleRate: 48_000, transport: .bluetooth, flagOn: false))
        XCTAssertEqual(
            WirelessOutputNotes.notes(transport: .bluetooth, nominalRateHz: 48_000, latencyFrames: 480, flagOn: true), [])
    }

    func testSixteenKilohertzBluetoothShowsTheHeadsetNoteAndNoRateChange() throws {
        XCTAssertEqual(
            WirelessOutputPolicy.rateNote(transport: .bluetooth, nominalRateHz: 16_000, flagOn: true)?.contains("headset mode (a microphone is open)"),
            true)
        XCTAssertNil(WirelessOutputPolicy.rateNote(transport: .bluetooth, nominalRateHz: 48_000, flagOn: true))
        XCTAssertNil(WirelessOutputPolicy.rateNote(transport: .airPlay, nominalRateHz: 16_000, flagOn: true))
        XCTAssertNil(WirelessOutputPolicy.rateNote(transport: .bluetooth, nominalRateHz: 16_000, flagOn: false))
        // The engine's selection keeps the device's own rate: nothing sets or resamples it.
        let headset = AudioOutputDevice(
            deviceID: 3, uid: "hs", name: "Headset", nominalSampleRate: 16_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 16_000, maximum: 16_000)], transport: .bluetooth)
        let engine = AudioIOEngine(deviceCatalog: Catalog(devices: [headset]))
        try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "hs")
        XCTAssertEqual(engine.selectedOutputDevice?.nominalSampleRate, 16_000)
    }

    // MARK: Refusals

    func testArmRefusesOnAWirelessOutputAndSetsNothing() {
        let arm = LiveTreatmentArm(feature: .quietZone)
        var environment = LiveTreatmentEnvironment(
            outputDeviceUID: "bt", sampleRate: 48_000, engineRunning: true, inputAvailable: true, microphoneLevelDBFS: nil)
        environment.outputIsWireless = true
        XCTAssertThrowsError(try arm.arm(environment: environment)) { error in
            XCTAssertEqual(error as? LiveTreatmentArmError, .wirelessOutput)
        }
        XCTAssertFalse(arm.isArmed)
        let mimo = LiveTreatmentArm(feature: .mimoRoomTreatment)
        XCTAssertThrowsError(try mimo.arm(environment: environment))
        XCTAssertFalse(mimo.isArmed)
        environment.outputIsWireless = false
        XCTAssertNoThrow(try arm.arm(environment: environment), "a wired output arms as before")
    }

    func testFeedForwardIsRefusedOnAWirelessOutputEvenWithQuietZoneArmed() {
        var policy = FeedForwardLiveArmingPolicy()
        var budget = QuietZoneFeedForwardBudget.missing
        budget.readiness = .physicallyPlausible
        var facts = FeedForwardLiveQuietZoneFacts(
            armed: true, hasBaseline: true, verdict: .ok, leaseRequired: false, leaseHealthy: true,
            outputDeviceUID: "bt", sampleRate: 48_000, budget: budget)
        facts.outputIsWireless = true
        XCTAssertFalse(policy.request(quietZone: facts, now: 0))
        facts.outputIsWireless = false
        XCTAssertTrue(policy.request(quietZone: facts, now: 0))
    }

    func testMeasurementsAreRefusedOnAWirelessOutputWithAReason() {
        var inputs = MeasurementReadiness.Inputs(permission: .authorized, hasInputDevice: true, hasOutputDevice: true)
        XCTAssertTrue(MeasurementReadiness.evaluate(inputs).isReady)
        inputs.outputIsWireless = true
        let readiness = MeasurementReadiness.evaluate(inputs)
        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.reason, WirelessOutputPolicy.measurementRefusal)
    }

    func testPolicyAppliesOnlyToWirelessWithTheFlagOn() {
        XCTAssertTrue(WirelessOutputPolicy.applies(.airPlay, flagOn: true))
        XCTAssertFalse(WirelessOutputPolicy.applies(.airPlay, flagOn: false))
        XCTAssertFalse(WirelessOutputPolicy.applies(.thunderbolt, flagOn: true))
        XCTAssertFalse(WirelessOutputPolicy.applies(nil, flagOn: true))
    }

    // MARK: Fixtures

    private func device(_ uid: String) -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: 1, uid: uid, name: uid, nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)])
    }

    private final class Catalog: OutputDeviceCataloging {
        var devices: [AudioOutputDevice]
        init(devices: [AudioOutputDevice]) { self.devices = devices }
        func outputDevices() throws -> [AudioOutputDevice] { devices }
    }
}
