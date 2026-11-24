import CoreAudio
import XCTest
@testable import NotchSixty

// E36 S3b: the sessions' driver path. The session constructors need a real output device, so what runs here is everything
// they call: the attachment (ring, pump, steering, IOProc hand-over) at the eight standard rates for each layout, and the
// engine switch through the coordinator. The session constructors on hardware are bench B3 and B8 (G19).
@MainActor
final class DriverSessionWiringTests: XCTestCase {
    typealias Plug = VirtualDeviceCaptureTests.FakePlugIn
    typealias DriverPlug = VirtualDeviceDriverTests.FakePlugIn
    static let rates = VirtualDeviceCaptureTests.rates
    static let group = "ABCDE12345.group.n60vd"

    private var retainedSwitchers: [DriverEngineSwitcher] = []

    // MARK: Fakes

    final class QuietScheduler: LeaseScheduler {
        final class Timer: LeaseTimer { var cancelled = false; func cancel() { cancelled = true } }
        var timer = Timer()
        var intervals: [UInt32] = []
        func schedule(everyMs interval: UInt32, _ handler: @escaping @Sendable () -> Void) -> any LeaseTimer {
            intervals.append(interval)
            return timer
        }
    }

    final class FakeEngine: InputSwitchEngine {
        var running = true
        var startError: Error?
        var log: [String] = []
        let selection: DriverCaptureSelection
        init(selection: DriverCaptureSelection) { self.selection = selection }
        var isRunningForInputSwitch: Bool { running }
        func stopForInputSwitch() { log.append("stop"); running = false }
        func startForInputSwitch() throws {
            log.append("start:\(selection.current == nil ? "tap" : "driver")")
            if let startError { throw startError }
            running = true
        }
    }

    /// Records what the "session" IOProcs are handed. Plain statics: the callbacks are C function pointers.
    enum Recorder {
        nonisolated(unsafe) static var channels: UInt32 = 0
        nonisolated(unsafe) static var captured: [Float] = []
        nonisolated(unsafe) static var outputCalls = 0
        static func reset() { channels = 0; captured = []; outputCalls = 0 }
    }

    private static let captureProc: AudioDeviceIOProc = { _, _, input, _, _, _, _ in
        let buffer = input.pointee.mBuffers
        Recorder.channels = buffer.mNumberChannels
        let count = Int(buffer.mDataByteSize) / 4
        let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
        Recorder.captured.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        return noErr
    }
    private static let outputProc: AudioDeviceIOProc = { _, _, _, _, _, _, _ in
        Recorder.outputCalls += 1
        return noErr
    }

    private func request(_ plug: Plug, ring: VirtualDeviceCaptureTests.MemoryRing?, scheduler: QuietScheduler = QuietScheduler())
        -> DriverCaptureSelection.Request {
        DriverCaptureSelection.Request(
            plugIn: 77, appGroupID: Self.group, access: plug, mapper: VirtualDeviceCaptureTests.FakeMapper(ring: ring),
            scheduler: scheduler, dacRates: { _, _ in Self.rates })
    }

    // MARK: Attachment at the standard rates

    func testRingFeedsTheSessionProcsWithTheLayoutChannelsAtEveryRate() throws {
        for rate in Self.rates {
            for layout in VirtualDeviceLayout.allCases {
                Recorder.reset()
                let channels = layout.channelCount
                let ring = VirtualDeviceCaptureTests.MemoryRing(channels: UInt32(channels), rate: rate)

                let plug = Plug()
                let scheduler = QuietScheduler()
                var token = 0
                let attachment = try DriverCaptureAttachment.open(
                    request(plug, ring: ring, scheduler: scheduler), outputUID: "dac", outputDeviceID: 5, dacRate: rate,
                    maxCallbackFrames: 512, channelCount: channels, clientData: &token, captureProc: Self.captureProc,
                    outputProc: Self.outputProc)
                // The reader attaches at the live edge, so the driver's frames arrive after the app has attached.
                var block = [Float](repeating: 0, count: 4096 * channels)
                for frame in 0..<4096 { for channel in 0..<channels { block[frame * channels + channel] = Float(channel + 1) / 16 } }
                _ = block.withUnsafeBufferPointer { n60_vd_ring_write(ring.storage, $0.baseAddress, 4096, 1) }
                XCTAssertEqual(scheduler.intervals, [VirtualDeviceProtocol.leaseRenewMs], "steering runs on the control timer")
                XCTAssertEqual(plug.writes.filter { $0.selector == N60_VD_PROP_LAYOUT }.count, 1)

                var list = AudioBufferList()
                var out = [Float](repeating: 0, count: 512 * channels)
                var time = AudioTimeStamp()
                out.withUnsafeMutableBytes { raw in
                    list.mNumberBuffers = 1
                    list.mBuffers.mNumberChannels = UInt32(channels)
                    list.mBuffers.mDataByteSize = UInt32(raw.count)
                    list.mBuffers.mData = raw.baseAddress
                    var inList = list
                    for _ in 0..<4 {
                        XCTAssertEqual(N60VirtualRingOutputIOProc(5, &time, &inList, &time, &list, &time, attachment.outputClientData), noErr)
                    }
                }
                XCTAssertEqual(Recorder.channels, UInt32(channels), "\(layout) at \(rate)")
                XCTAssertEqual(Recorder.outputCalls, 4)
                XCTAssertEqual(Recorder.captured.count, 4 * 512 * channels)
                // Once primed the last block carries the ring's per-channel values, in channel order.
                let tail = Array(Recorder.captured.suffix(channels))
                XCTAssertEqual(tail, (0..<channels).map { Float($0 + 1) / 16 }, "\(layout) at \(rate)")
                attachment.close()
                XCTAssertTrue(scheduler.timer.cancelled)
            }
        }
    }

    func testRefusalsAndMissingDriverThrow() {
        var token = 0
        let plug = Plug()
        XCTAssertThrowsError(try DriverCaptureAttachment.open(
            request(plug, ring: nil), outputUID: "dac", outputDeviceID: 5, dacRate: 48_000, maxCallbackFrames: 512,
            channelCount: 2, clientData: &token, captureProc: Self.captureProc, outputProc: Self.outputProc),
            "no driver publishing a ring: no silent fallback") {
            guard case DriverCaptureError.open = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try DriverCaptureAttachment.open(
            request(plug, ring: nil), outputUID: "dac", outputDeviceID: 5, dacRate: 48_000, maxCallbackFrames: 512,
            channelCount: 3, clientData: &token, captureProc: Self.captureProc, outputProc: Self.outputProc)) {
            XCTAssertEqual($0 as? DriverCaptureError, .unsupportedChannelCount(3))
        }
        XCTAssertThrowsError(try DriverCaptureAttachment.open(
            request(plug, ring: VirtualDeviceCaptureTests.MemoryRing(channels: 2, rate: 48_000)), outputUID: N60_VD_DEVICE_UID,
            outputDeviceID: 5, dacRate: 48_000, maxCallbackFrames: 512, channelCount: 2, clientData: &token,
            captureProc: Self.captureProc, outputProc: Self.outputProc), "the virtual device is never the output")
    }

    func testLayoutLabelsResolveToDistinctProgramRoles() {
        for layout in VirtualDeviceLayout.allCases {
            XCTAssertEqual(layout.channelLabels.count, layout.channelCount)
            let roles = layout.channelDescriptions.map { OutputProgramRole(realtime: N60ProgramChannelRoleFromAudioChannelLabel($0.mChannelLabel)) }
            XCTAssertFalse(roles.contains { $0 == nil }, "\(layout)")
            XCTAssertEqual(Set(roles.compactMap { $0 }.map(\.hashValue)).count, layout.channelCount, "\(layout) roles are distinct")
            let format = layout.streamFormat(sampleRate: 96_000)
            XCTAssertTrue(format.isSupportedFloat32TransportFormat)
            XCTAssertEqual(format.channelCount, UInt32(layout.channelCount))
            XCTAssertEqual(format.isSupportedStereoTransportFormat, layout == .stereo)
        }
    }

    func testAppGroupComesFromTheEntitlementAndFitsTheShmName() {
        XCTAssertEqual(DriverCaptureAttachment.appGroupID(entitlementGroups: ["ABCDE12345.group.other", Self.group]), Self.group)
        XCTAssertNil(DriverCaptureAttachment.appGroupID(entitlementGroups: ["ABCDE12345.group.other"]))
        XCTAssertNil(DriverCaptureAttachment.appGroupID(entitlementGroups: nil))
    }

    // MARK: The switch, through the coordinator and the engine

    private func makeSwitch(plug: DriverPlug = DriverPlug())
        -> (DriverInputCoordinator, FakeEngine, DriverCaptureSelection, DriverPlug, DriverEngineSwitcher) {
        let selection = DriverCaptureSelection()
        let fake = FakeEngine(selection: selection)
        let switcher = DriverEngineSwitcher(selection: selection, request: { [plug] in
            DriverCaptureSelection.Request(plugIn: 77, appGroupID: Self.group, access: plug)
        })
        switcher.attach(fake)
        retainedSwitchers.append(switcher)  // the hooks hold it weakly
        let lease = DriverLeaseWriter(access: plug, scheduler: VirtualDeviceDriverTests.ManualScheduler(), sessionToken: 3)
        let driver = DriverStatusModel(discovery: DriverDiscovery(access: plug), lease: lease)
        let output = DriverInputCoordinatorTests.FakeOutput()
        let coordinator = DriverInputCoordinator(
            driver: driver, output: output, store: DriverInputCoordinatorTests.FakeStore(), hooks: switcher.hooks)
        return (coordinator, fake, selection, plug, switcher)
    }

    func testSwitchStopsFadesBuildsTheNextSessionOnTheNewSourceAndBack() {
        let (coordinator, engine, selection, _, _) = makeSwitch()
        XCTAssertNil(selection.current, "the tap is the default")
        coordinator.switchTo(.virtualDriver)
        XCTAssertEqual(engine.log, ["stop", "start:driver"], "fade-out stop, then the new session reads the ring source")
        XCTAssertEqual(selection.current?.plugIn, 77)
        XCTAssertEqual(selection.current?.appGroupID, Self.group)
        XCTAssertEqual(coordinator.lifecycle.state, .running)
        coordinator.switchTo(.processTap)
        XCTAssertEqual(engine.log, ["stop", "start:driver", "stop", "start:tap"])
        XCTAssertNil(selection.current)
        XCTAssertEqual(coordinator.path, .processTap)
    }

    func testStoppedEngineIsNotStartedBySwitching() {
        let (coordinator, engine, selection, _, _) = makeSwitch()
        engine.running = false
        coordinator.switchTo(.virtualDriver)
        XCTAssertEqual(engine.log, [])
        XCTAssertNotNil(selection.current, "the next Start builds the ring session")
    }

    func testEngineThatCannotStartOnTheRingWaitsAndNeverFallsBackToTheTap() {
        let (coordinator, engine, selection, _, switcher) = makeSwitch()
        engine.startError = DriverCaptureError.open("ring unavailable")
        coordinator.switchTo(.virtualDriver)
        XCTAssertEqual(coordinator.lifecycle.state, .waitingForInputDevice)
        XCTAssertEqual(coordinator.path, .virtualDriver)
        XCTAssertNotNil(selection.current, "the choice stands: no quiet switch to the tap")
        XCTAssertNotNil(switcher.failure)
        XCTAssertTrue(coordinator.statusMessage?.contains("ring unavailable") == true)
        engine.startError = nil
        coordinator.reconcile()
        XCTAssertEqual(coordinator.lifecycle.state, .running, "the poll retries and recovers")
        XCTAssertEqual(engine.log.suffix(1), ["start:driver"])
    }

    func testMissingDriverNeverTouchesTheEngineSource() {
        let plug = DriverPlug()
        plug.installed = false
        let (coordinator, engine, selection, _, _) = makeSwitch(plug: plug)
        coordinator.switchTo(.virtualDriver)
        XCTAssertEqual(coordinator.lifecycle.state, .waitingForInputDevice)
        XCTAssertNil(selection.current)
        XCTAssertEqual(engine.log, ["stop"], "stopped for the fade, not restarted on a tap")
    }
}
