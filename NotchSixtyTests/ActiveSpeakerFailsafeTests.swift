import XCTest
@testable import NotchSixty

/// E9 S9: the active-speaker failsafe. A crossover DAC must not be the macOS default output, because the app only
/// protects its drivers while it runs.
@MainActor
final class ActiveSpeakerFailsafeTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func ep(_ uid: String, _ i: UInt32) -> PhysicalOutputEndpoint {
        PhysicalOutputEndpoint(deviceUID: uid, channelIndex: i)
    }

    private func devices(rate: Double) -> [AudioOutputDevice] {
        [AudioOutputDevice(deviceID: 1, uid: "dac", name: "Tri-amp DAC", nominalSampleRate: rate,
                           availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)],
                           outputChannelCount: 8),
         AudioOutputDevice(deviceID: 2, uid: "builtin", name: "Built-in", nominalSampleRate: rate,
                           availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 96_000)])]
    }

    private func twoWayOn(_ uid: String) -> SpeakerRoutingConfiguration {
        SpeakerRoutingTemplate.twoWay.build(
            mains: [.init(lane: 0, name: "Left", endpoints: [ep(uid, 0), ep(uid, 1)]),
                    .init(lane: 1, name: "Right", endpoints: [ep(uid, 2), ep(uid, 3)])],
            subs: [], crossoverHz: [2_000])!
    }

    func testVerdictFlagsTheDefaultOutputOnlyWhenItCarriesACrossover() {
        for rate in Self.rates {
            let list = devices(rate: rate)
            let config = twoWayOn("dac")
            XCTAssertEqual(
                ActiveSpeakerFailsafe.verdict(config, defaultOutputUID: "dac", devices: list),
                .defaultOutputIsCrossoverDevice(uid: "dac", name: "Tri-amp DAC"), "\(rate)")
            XCTAssertTrue(ActiveSpeakerFailsafe.verdict(config, defaultOutputUID: "builtin", devices: list).isSafe)
            XCTAssertTrue(ActiveSpeakerFailsafe.verdict(config, defaultOutputUID: nil, devices: list).isSafe)
            var off = config
            off.enabled = false
            XCTAssertTrue(ActiveSpeakerFailsafe.verdict(off, defaultOutputUID: "dac", devices: list).isSafe)
        }
    }

    func testSingleWayFullRangeSpeakersAndPlainSubsAreNotCrossoverDevices() {
        let config = SpeakerRoutingTemplate.mainsPlusSub.build(
            mains: [.init(lane: 0, name: "Left", endpoints: [ep("builtin", 0)]),
                    .init(lane: 1, name: "Right", endpoints: [ep("builtin", 1)])],
            subs: [ep("dac", 0)], crossoverHz: [])
        XCTAssertNotNil(config)
        XCTAssertFalse(ActiveSpeakerFailsafe.crossoverDeviceUIDs(config!).contains("dac"))
    }

    func testSetupGateRefusesAnyWayCrossoverOnTheDefaultOutputAtEveryRate() {
        for rate in Self.rates {
            let m = SpeakerRoutingEditorModel(context: SpeakerRoutingContext(programLanes: 2, subwoofers: 0, sampleRate: rate))
            var committed = 0
            m.onCommit = { _ in committed += 1 }
            let list = devices(rate: rate)
            m.failsafe = (defaultOutputUID: { "dac" }, devices: { list })
            m.setEnabled(true)
            committed = 0
            XCTAssertFalse(m.applyTemplate(.twoWay, deviceUID: "dac"), "\(rate)")
            XCTAssertEqual(committed, 0)
            XCTAssertTrue(m.failsafeRefusal?.contains("Tri-amp DAC") == true)
            XCTAssertFalse(m.configuration.speakers.contains { !$0.ways.isEmpty && $0.ways.count > 1 })

            // A different default output lets the same setup through and clears the message.
            m.failsafe = (defaultOutputUID: { "builtin" }, devices: { list })
            XCTAssertTrue(m.applyTemplate(.twoWay, deviceUID: "dac"))
            XCTAssertNil(m.failsafeRefusal)
            XCTAssertEqual(m.configuration.wayCount, 4)
            XCTAssertGreaterThan(committed, 0)
        }
    }

    func testDisablingRoutingIsAlwaysAllowedAndNoGateMeansNoRefusal() {
        let m = SpeakerRoutingEditorModel(context: SpeakerRoutingContext(programLanes: 2, subwoofers: 0, sampleRate: 48_000))
        m.replace(twoWayOn("dac"))
        XCTAssertEqual(m.configuration.wayCount, 4)  // no gate installed: flag off behaves as before
        m.failsafe = (defaultOutputUID: { "dac" }, devices: { [] })
        m.setEnabled(false)
        XCTAssertFalse(m.configuration.enabled)
        XCTAssertNil(m.failsafeRefusal)
    }

    func testLaunchMessageAdvisesCapacitorsAndSafeVerdictHasNone() {
        XCTAssertNil(ActiveSpeakerFailsafe.message(.safe, launch: true))
        let text = ActiveSpeakerFailsafe.message(.defaultOutputIsCrossoverDevice(uid: "dac", name: "DAC"), launch: true)
        XCTAssertTrue(text?.contains("capacitor") == true)
    }

    // MARK: E9 S8 (G28): listener, off-main read, import note

    private final class FakeReader: DefaultOutputDeviceReading, @unchecked Sendable {
        private let lock = NSLock()
        private var uid: String?
        private(set) var mainThreadReads = 0
        init(_ uid: String?) { self.uid = uid }
        func set(_ uid: String?) { lock.lock(); self.uid = uid; lock.unlock() }
        func defaultOutputDeviceUID() -> String? {
            lock.lock(); defer { lock.unlock() }
            if Thread.isMainThread { mainThreadReads += 1 }
            return uid
        }
    }

    private final class FakeObserver: DefaultOutputChangeObserving {
        var onChange: (@Sendable () -> Void)?
        var stopped = false
        func start(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
        func stop() { stopped = true; onChange = nil }
    }

    func testMonitorFollowsADefaultChangeFromTheListenerWithoutReadingOnTheMainThread() async {
        let reader = FakeReader("builtin")
        let observer = FakeObserver()
        let monitor = DefaultOutputMonitor(reader: reader, observer: observer)
        monitor.start()
        await monitor.refresh()
        XCTAssertTrue(monitor.hasRead)
        XCTAssertEqual(monitor.defaultOutputUID, "builtin")
        XCTAssertNotNil(observer.onChange, "the listener is installed")

        // A default change while the app stays frontmost: the listener fires and the cache follows.
        reader.set("dac")
        observer.onChange?()
        let deadline = Date().addingTimeInterval(2)
        while monitor.defaultOutputUID != "dac", Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(monitor.defaultOutputUID, "dac")
        XCTAssertEqual(monitor.uidForGate(), "dac")
        XCTAssertEqual(reader.mainThreadReads, 0, "reads happen off the main thread once the cache is warm")

        // The gate sees the new default with no further read.
        for rate in Self.rates {
            let list = devices(rate: rate)
            XCTAssertFalse(ActiveSpeakerFailsafe.verdict(
                twoWayOn("dac"), defaultOutputUID: monitor.uidForGate(), devices: list).isSafe, "\(rate)")
        }
        monitor.stop()
        XCTAssertTrue(observer.stopped)
    }

    func testGateFailsClosedBeforeTheFirstReadLands() {
        let reader = FakeReader("dac")
        let monitor = DefaultOutputMonitor(reader: reader, observer: FakeObserver())
        XCTAssertFalse(monitor.hasRead)
        XCTAssertEqual(monitor.uidForGate(), "dac", "no cached value yet: a direct read, not an assumption of safety")
    }

    func testRefusedImportAddsAnInterchangeNoteAndAcceptedImportDoesNot() {
        let m = SpeakerRoutingEditorModel(context: SpeakerRoutingContext(programLanes: 2, subwoofers: 0, sampleRate: 48_000))
        m.failsafe = (defaultOutputUID: { "dac" }, devices: { [] })
        let note = m.applyImportedRouting(twoWayOn("dac"))
        XCTAssertTrue(note?.contains("not applied") == true)
        XCTAssertTrue(note?.contains("default output") == true)
        XCTAssertEqual(m.configuration.wayCount, 0, "a refused import changes nothing")

        m.failsafe = (defaultOutputUID: { "builtin" }, devices: { [] })
        XCTAssertNil(m.applyImportedRouting(twoWayOn("dac")))
        XCTAssertEqual(m.configuration.wayCount, 4)
    }
}
