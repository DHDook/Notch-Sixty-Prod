import XCTest
@testable import NotchSixty

/// E15 S5 (design note 14): the read-only source-rate probe, and the existing path when another app changes the
/// DAC's nominal rate, over all 56 ordered pairs of the eight standard rates (fake events, no hardware).
/// What these cannot show is whether a real tap ever reports a rate other than the device's: that is bench B-S5 (G11).
@MainActor
final class SourceRateProbeTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private final class MutableCatalog: OutputDeviceCataloging {
        var devices: [AudioOutputDevice]
        init(_ devices: [AudioOutputDevice]) { self.devices = devices }
        func outputDevices() throws -> [AudioOutputDevice] { devices }
    }

    private final class FakeMonitor: AudioHardwareEvents {
        var onDeviceListChanged: (() -> Void)?
        var onSelectedOutputSampleRateChanged: (() -> Void)?
        var onWillSleep: (() -> Void)?
        var onDidWake: (() -> Void)?
        var removedRateMonitors = 0
        func start() throws {}
        func monitorSampleRate(of deviceID: AudioDeviceID?) throws {}
        func removeSelectedOutputSampleRateMonitor() { removedRateMonitors += 1 }
        func stop() {}
    }

    private final class FakeSource: FollowOutputEventSource {
        var onDefaultOutputChanged: ((OutputFollowTarget?) -> Void)?
        var onDataSourceChanged: ((OutputFollowTarget) -> Void)?
        var onDeviceListChanged: (() -> Void)?
        var onWillSleep: (() -> Void)?
        var onDidWake: (() -> Void)?
        func start() throws {}
        func stop() {}
        func monitorDataSource(ofDeviceUID uid: String?) {}
        func currentDefaultTarget() -> OutputFollowTarget? { nil }
        func dataSourceID(forDeviceUID uid: String) -> UInt32? { nil }
        func availableOutputUIDs() -> Set<String> { ["dac"] }
        func ownDeviceUIDs() -> Set<String> { [] }
    }

    private final class IdleClock: FollowScheduling, @unchecked Sendable {
        var scheduled = 0
        func schedule(after delay: TimeInterval, _ block: @escaping @MainActor () -> Void) -> FollowTimerToken {
            scheduled += 1
            return FollowTimerToken {}
        }
    }

    private func device(rate: Double) -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: 41, uid: "dac", name: "DAC", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 8_000, maximum: 384_000)], outputChannelCount: 2)
    }

    private func runningEngine(rate: Double) throws -> (AudioIOEngine, MutableCatalog, FakeMonitor) {
        let catalog = MutableCatalog([device(rate: rate)])
        let monitor = FakeMonitor()
        let engine = AudioIOEngine(deviceCatalog: catalog, eventMonitor: monitor)
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "dac")
        for state in [AudioLifecycleState.creatingTap, .creatingAggregate, .openingOutput, .starting, .running] {
            try engine.setLifecycle(state)
        }
        return (engine, catalog, monitor)
    }

    // MARK: the probe

    func testRecordsOnlyChangesAndCountsATapRateThatDiffersWhileRunning() {
        let probe = SourceRateProbe()
        XCTAssertTrue(probe.record(lifecycle: .running, tapRate: 48_000, deviceRate: 48_000))
        XCTAssertFalse(probe.record(lifecycle: .running, tapRate: 48_000, deviceRate: 48_000))
        XCTAssertTrue(probe.record(lifecycle: .reconfiguring, tapRate: nil, deviceRate: 96_000))
        XCTAssertTrue(probe.record(lifecycle: .running, tapRate: 96_000, deviceRate: 96_000))
        XCTAssertEqual(probe.samples.count, 3)
        XCTAssertEqual(probe.tapDifferedFromDeviceCount, 0)
        XCTAssertTrue(probe.record(lifecycle: .running, tapRate: 44_100, deviceRate: 96_000))
        XCTAssertEqual(probe.tapDifferedFromDeviceCount, 1)
    }

    func testExportListsEverySampleWithBothRatesAndIsBounded() {
        let probe = SourceRateProbe()
        XCTAssertEqual(probe.diagnosticsLines().last, "  no samples")
        for index in 0..<(SourceRateProbe.capacity + 5) {
            probe.record(lifecycle: .running, tapRate: Double(8_000 + index), deviceRate: Double(8_000 + index))
        }
        XCTAssertEqual(probe.samples.count, SourceRateProbe.capacity)
        XCTAssertEqual(probe.droppedSamples, 5)
        let lines = probe.diagnosticsLines()
        XCTAssertTrue(lines[1].contains("0 time(s)"))
        XCTAssertTrue(lines[2].contains("tap 8.0 kHz"), lines[2])
        XCTAssertTrue(lines.last?.contains("5 older") == true)
    }

    func testWiringBuildsNothingWithoutFlagAndDeveloperTools() throws {
        let (engine, _, _) = try runningEngine(rate: 48_000)
        XCTAssertNil(SourceRateProbeWiring.make(engine: engine, flagEnabled: false, developerToolsShown: true))
        XCTAssertNil(SourceRateProbeWiring.make(engine: engine, flagEnabled: true, developerToolsShown: false))
        XCTAssertNotNil(SourceRateProbeWiring.make(engine: engine, flagEnabled: true, developerToolsShown: true))
    }

    // MARK: the existing path, all 56 ordered pairs

    func testNominalRateChangeFromAnotherAppReconfiguresOnceAtTheNewRateForEveryPair() throws {
        var covered = 0
        for from in rates {
            for to in rates where to != from {
                let (engine, catalog, monitor) = try runningEngine(rate: from)
                let built = try XCTUnwrap(SourceRateProbeWiring.make(engine: engine, flagEnabled: true, developerToolsShown: true))
                let recoveryBefore = engine.recoveryAttempts

                // Another app sets the DAC's nominal rate; the monitor reports it twice (a repeat while settling).
                catalog.devices = [device(rate: to)]
                monitor.onSelectedOutputSampleRateChanged?()
                monitor.onSelectedOutputSampleRateChanged?()

                // One teardown and no frame with the old graph: the lifecycle left `.running` at the event.
                XCTAssertEqual(engine.lifecycleState, .reconfiguring, "\(from) to \(to)")
                XCTAssertEqual(monitor.removedRateMonitors, 1, "one teardown for \(from) to \(to)")
                XCTAssertNil(engine.diagnosticsSnapshot().tapSampleRate)

                // The settle window ends: the device list is re-read at the new rate before the rebuild.
                engine.performSampleRateReconfiguration(countsAsSampleRateChange: true)
                XCTAssertEqual(engine.selectedOutputDevice?.nominalSampleRate, to, "\(from) to \(to)")

                // Same UID: no output switch, no recovery.
                XCTAssertEqual(engine.selectedOutputUID, "dac")
                XCTAssertEqual(engine.recoveryAttempts, recoveryBefore)
                XCTAssertNotEqual(engine.lifecycleState, .recoveringOutput)
                built.subscription.cancel()
                covered += 1
            }
        }
        XCTAssertEqual(covered, 56)
    }

    func testFollowModeRateChangeOnTheSameDeviceCausesNoOutputOrProfileSwitch() throws {
        let (engine, catalog, monitor) = try runningEngine(rate: 48_000)
        let source = FakeSource()
        let clock = IdleClock()
        let id = UUID()
        var bindings = OutputProfileBindings()
        bindings.bind(OutputKey(deviceUID: "dac"), to: id)
        var outcomes = 0
        let driver = OutputFollowEventDriver(
            source: source, engine: engine, scheduler: clock, policy: OutputFollowPolicy(now: { Date() }),
            stateProvider: { OutputFollowState(mode: .followSystem, bindings: bindings, existingProfileIDs: [id]) })
        driver.onOutcome = { _ in outcomes += 1 }
        driver.reconcile()
        let scheduledBefore = clock.scheduled

        for rate in [96_000.0, 384_000, 44_100] {
            catalog.devices = [device(rate: rate)]
            monitor.onSelectedOutputSampleRateChanged?()
            engine.performSampleRateReconfiguration(countsAsSampleRateChange: true)
            XCTAssertEqual(engine.selectedOutputUID, "dac")
        }
        XCTAssertEqual(outcomes, 0)
        XCTAssertEqual(clock.scheduled, scheduledBefore, "a rate change is not a default-output event")
    }
}
