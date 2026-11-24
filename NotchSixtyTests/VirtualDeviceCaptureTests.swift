import CoreAudio
import XCTest
@testable import NotchSixty

// E36 S3: the app side of the driver's programme ring, on a fake plug-in and in-memory rings, at the eight standard rates.
final class VirtualDeviceCaptureTests: XCTestCase {
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    final class FakePlugIn: DriverPluginAccess {
        var writes: [(selector: UInt32, data: Data)] = []
        var failSelector: UInt32?
        func pluginObject(forBundleID bundleID: String) -> AudioObjectID? { 77 }
        func readUInt32(object: AudioObjectID, selector: UInt32) -> (status: OSStatus, value: UInt32) { (noErr, N60_VD_PROTOCOL_VERSION) }
        func writeData(object: AudioObjectID, selector: UInt32, data: Data) -> OSStatus {
            if selector == failSelector { return kAudioHardwareUnknownPropertyError }
            writes.append((selector, data))
            return noErr
        }
        func scalars() -> [Double] {
            writes.filter { $0.selector == N60_VD_PROP_CLOCK_SCALAR }.map { $0.data.withUnsafeBytes { $0.loadUnaligned(as: Double.self) } }
        }
    }

    /// Plain memory standing in for the shared-memory object the driver writes.
    final class MemoryRing: VirtualRingMapping {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(N60_VD_RING_BYTES), alignment: 4096)
        var base: UnsafeRawPointer { UnsafeRawPointer(storage) }
        var bytes: Int { Int(N60_VD_RING_BYTES) }
        init(channels: UInt32, rate: Double) {
            memset(storage, 0, bytes)
            XCTAssertEqual(n60_vd_ring_writer_init(storage, bytes, channels, UInt32(rate)), N60_VD_OK)
        }
        deinit { storage.deallocate() }
        func write(frames: Int, channels: Int, value: Float) {
            let block = [Float](repeating: value, count: frames * channels)
            _ = block.withUnsafeBufferPointer { n60_vd_ring_write(storage, $0.baseAddress, UInt32(frames), 1) }
        }
    }

    struct FakeMapper: VirtualRingMapper {
        var ring: MemoryRing?
        var errorCode: Int32 = ENOENT
        var requestedNames: Box = Box()
        final class Box { var names: [String] = [] }
        func map(name: String) -> Result<any VirtualRingMapping, VirtualRingMapError> {
            requestedNames.names.append(name)
            if let ring { return .success(ring) }
            return .failure(.unavailable(errorCode))
        }
    }

    private func configuration(rate: Double = 48_000, layout: VirtualDeviceLayout = .stereo, output: String = "dac-uid") -> VirtualDeviceCaptureSource.Configuration {
        .init(outputUID: output, dacRate: rate, dacRates: Self.rates, layout: layout, maxCallbackFrames: 512,
              appGroupID: "ABCDE12345.group.n60vd", plugIn: 77)
    }

    func testLayoutCodesMatchTheProtocolHeader() {
        XCTAssertEqual(VirtualDeviceLayout.stereo.rawValue, N60_VD_LAYOUT_STEREO)
        XCTAssertEqual(VirtualDeviceLayout.surround51.rawValue, N60_VD_LAYOUT_5_1)
        XCTAssertEqual(VirtualDeviceLayout.surround71.rawValue, N60_VD_LAYOUT_7_1)
        XCTAssertEqual(VirtualDeviceLayout.surround514.rawValue, N60_VD_LAYOUT_5_1_4)
        XCTAssertEqual(VirtualDeviceLayout.surround714.rawValue, N60_VD_LAYOUT_7_1_4)
        XCTAssertEqual(VirtualDeviceLayout.allCases.map(\.channelCount), [2, 6, 8, 10, 12])
        for layout in VirtualDeviceLayout.allCases {
            XCTAssertLessThanOrEqual(layout.channelCount, Int(N60_VD_RING_MAX_CHANNELS))
        }
    }

    func testRingNameStaysWithinThePosixLimit() {
        XCTAssertEqual(VirtualRingNaming.shmName(appGroupID: "ABCDE12345.group.n60vd"), "ABCDE12345.group.n60vd/n60vd")
        XCTAssertNil(VirtualRingNaming.shmName(appGroupID: "ABCDE12345.group.com.dhdook.notchsixty"))
        XCTAssertNil(VirtualRingNaming.shmName(appGroupID: ""))
    }

    func testRefusesTheVirtualDeviceAsOutput() {
        let source = VirtualDeviceCaptureSource(mapper: FakeMapper(ring: MemoryRing(channels: 2, rate: 48_000)), access: FakePlugIn())
        let bridge = N60RealtimeAudioBridgeCreate(4096)!
        defer { N60RealtimeAudioBridgeDestroy(bridge) }
        XCTAssertThrowsError(try source.open(configuration(output: N60_VD_DEVICE_UID), bridge: bridge)) {
            XCTAssertEqual($0 as? VirtualDeviceCaptureSource.OpenError, .outputIsVirtualDevice)
        }
        XCTAssertFalse(source.isOpen)
    }

    func testOpenPinsRateAndLayoutAndMapsTheNamedRing() throws {
        let plugIn = FakePlugIn()
        let mapper = FakeMapper(ring: MemoryRing(channels: 12, rate: 384_000))
        let source = VirtualDeviceCaptureSource(mapper: mapper, access: plugIn)
        let bridge = N60RealtimeAudioBridgeCreate(4096)!
        defer { source.close(); N60RealtimeAudioBridgeDestroy(bridge) }
        try source.open(configuration(rate: 384_000, layout: .surround714), bridge: bridge)
        XCTAssertEqual(mapper.requestedNames.names, ["ABCDE12345.group.n60vd/n60vd"])
        XCTAssertEqual(source.captureDeviceID, AudioDeviceID(kAudioObjectUnknown), "no input stream, no capture device")
        let rates = plugIn.writes.first { $0.selector == N60_VD_PROP_DAC_RATES }!.data
        let decoded = rates.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        XCTAssertEqual(decoded, Self.rates, "ascending and de-duplicated, the DAC's own rate included")
        let layout = plugIn.writes.first { $0.selector == N60_VD_PROP_LAYOUT }!.data
        XCTAssertEqual(layout.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, N60_VD_LAYOUT_7_1_4)
        XCTAssertThrowsError(try source.open(configuration(), bridge: bridge)) {
            XCTAssertEqual($0 as? VirtualDeviceCaptureSource.OpenError, .alreadyOpen)
        }
    }

    func testMissingOrInvalidRingAndFailedControlReportWithoutFallback() {
        let bridge = N60RealtimeAudioBridgeCreate(4096)!
        defer { N60RealtimeAudioBridgeDestroy(bridge) }
        var source = VirtualDeviceCaptureSource(mapper: FakeMapper(ring: nil), access: FakePlugIn())
        XCTAssertThrowsError(try source.open(configuration(), bridge: bridge)) {
            XCTAssertEqual($0 as? VirtualDeviceCaptureSource.OpenError, .ringUnavailable(ENOENT))
        }
        let blank = MemoryRing(channels: 2, rate: 48_000)
        memset(blank.storage, 0, 64)  // wipes the magic
        source = VirtualDeviceCaptureSource(mapper: FakeMapper(ring: blank), access: FakePlugIn())
        XCTAssertThrowsError(try source.open(configuration(), bridge: bridge)) {
            XCTAssertEqual($0 as? VirtualDeviceCaptureSource.OpenError, .ringInvalid(N60_VD_ERR_MAGIC))
        }
        let refusing = FakePlugIn()
        refusing.failSelector = N60_VD_PROP_LAYOUT
        source = VirtualDeviceCaptureSource(mapper: FakeMapper(ring: MemoryRing(channels: 2, rate: 48_000)), access: refusing)
        XCTAssertThrowsError(try source.open(configuration(), bridge: bridge)) {
            XCTAssertEqual($0 as? VirtualDeviceCaptureSource.OpenError, .controlFailed(kAudioHardwareUnknownPropertyError))
        }
        XCTAssertFalse(source.isOpen)
    }

    func testClockScalarIsClampedToTheProtocolRange() {
        let plugIn = FakePlugIn()
        let writer = DriverControlWriter(access: plugIn)
        writer.writeClockScalar(plugIn: 77, 1.5)
        writer.writeClockScalar(plugIn: 77, 0.5)
        writer.writeClockScalar(plugIn: 77, 1.0002)
        XCTAssertEqual(plugIn.scalars(), [1.001, 0.999, 1.0002])
    }

    /// The pump hands ring frames to the bridge through the same entry the tap's capture proc uses, at every rate and
    /// channel count; a 12-channel ring at 384 kHz fits the fixed ring.
    func testPumpFeedsTheBridgeAtEveryRateAndLayout() throws {
        for rate in Self.rates {
            for layout in VirtualDeviceLayout.allCases {
                let ring = MemoryRing(channels: UInt32(layout.channelCount), rate: rate)
                let source = VirtualDeviceCaptureSource(mapper: FakeMapper(ring: ring), access: FakePlugIn())
                let bridge = N60RealtimeAudioBridgeCreate(UInt32(rate))!
                defer { source.close(); N60RealtimeAudioBridgeDestroy(bridge) }
                try source.open(configuration(rate: rate, layout: layout), bridge: bridge)
                let pump = try XCTUnwrap(source.pump)
                ring.write(frames: 4096, channels: layout.channelCount, value: 0.25)
                for _ in 0..<4 { N60VirtualRingPumpProcess(pump, 512) }
                let snapshot = N60RealtimeAudioBridgeGetSnapshot(bridge)
                XCTAssertEqual(snapshot.capturedFrames, 2048, "\(rate) Hz, \(layout)")
                XCTAssertEqual(snapshot.unsupportedBufferLayouts, 0)
                XCTAssertEqual(source.counters?.underrunFrames, 0)
            }
        }
    }

    /// Closed loop: a simulated driver whose clock is off by up to 200 ppm writes into a real ring, the pump reads it, and the
    /// steering step writes the scalar back through the fake plug-in. Converges inside 10 s with the fill in bounds.
    func testSteeringLoopConvergesAtEveryRate() throws {
        for rate in Self.rates {
            for ppm in [-200.0, 200.0] {
                let plugIn = FakePlugIn()
                let ring = MemoryRing(channels: 2, rate: rate)
                let source = VirtualDeviceCaptureSource(mapper: FakeMapper(ring: ring), access: plugIn)
                let bridge = N60RealtimeAudioBridgeCreate(UInt32(rate))!
                defer { source.close(); N60RealtimeAudioBridgeDestroy(bridge) }
                try source.open(configuration(rate: rate), bridge: bridge)
                let pump = try XCTUnwrap(source.pump)
                let block = 512
                let target = Double(max(1024, 2 * 512))
                ring.write(frames: Int(target), channels: 2, value: 0.1)
                var scalar = 1.0
                var carry = 0.0
                var elapsed = 0.0
                var sinceSteer = 0.0
                var worstFill = 0.0
                var maxAfterSettle = 0.0
                while elapsed < 20 {
                    carry += Double(block) * (1 + ppm * 1e-6) * scalar
                    let written = Int(carry)
                    carry -= Double(written)
                    ring.write(frames: written, channels: 2, value: 0.1)
                    N60VirtualRingPumpProcess(pump, UInt32(block))
                    let dt = Double(block) / rate
                    elapsed += dt
                    sinceSteer += dt
                    if sinceSteer >= 0.25 {
                        if let value = source.steerOnce(dt: sinceSteer) { scalar = value }
                        sinceSteer = 0
                    }
                    let fill = Double(source.counters?.fillFrames ?? 0)
                    worstFill = max(worstFill, abs(fill - target))
                    if elapsed > 10 { maxAfterSettle = max(maxAfterSettle, abs(fill - target)) }
                }
                XCTAssertEqual((scalar - 1) * 1e6, -ppm, accuracy: 25, "\(rate) Hz \(ppm) ppm")
                XCTAssertLessThan(maxAfterSettle, 600, "fill settled near the target after 10 s at \(rate) Hz")
                XCTAssertLessThan(worstFill, Double(ring.bytes) / 8 / 4, "bounded throughout")
                XCTAssertEqual(source.counters?.underrunFrames, 0, "no drops at \(rate) Hz")
                XCTAssertEqual(source.counters?.droppedFrames, 0)
            }
        }
    }

    func testSteeringTimerWritesOnlyWhileOpenAndCloseResetsTheClock() throws {
        final class Timer: LeaseTimer { var cancelled = false; func cancel() { cancelled = true } }
        final class Scheduler: LeaseScheduler {
            var timer = Timer(); var interval: UInt32 = 0
            func schedule(everyMs interval: UInt32, _ handler: @escaping @Sendable () -> Void) -> any LeaseTimer { self.interval = interval; return timer }
        }
        let plugIn = FakePlugIn()
        let ring = MemoryRing(channels: 2, rate: 48_000)
        let source = VirtualDeviceCaptureSource(mapper: FakeMapper(ring: ring), access: plugIn)
        let bridge = N60RealtimeAudioBridgeCreate(48_000)!
        defer { N60RealtimeAudioBridgeDestroy(bridge) }
        let scheduler = Scheduler()
        source.startSteering(scheduler: scheduler)
        XCTAssertEqual(scheduler.interval, 0, "nothing to steer before open")
        try source.open(configuration(), bridge: bridge)
        source.startSteering(scheduler: scheduler)
        XCTAssertEqual(scheduler.interval, VirtualDeviceProtocol.leaseRenewMs)
        XCTAssertNil(source.steerOnce(dt: 0.25), "no running reads yet, so the clock is left alone")
        source.close()
        XCTAssertTrue(scheduler.timer.cancelled)
        XCTAssertEqual(plugIn.scalars().last, 1.0)
        source.close()  // safe twice
        XCTAssertFalse(source.isOpen)
    }
}
