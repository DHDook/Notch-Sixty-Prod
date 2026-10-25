import CoreAudio
import Foundation

/// E11 S8, design note 7: the RTA and SPL meter's input. An input-only IOProc on the microphone device (no
/// aggregate, no output, no tap) copies one channel into the core's SPSC ring (`N60MeasurementMonitorProc.c`);
/// a worker queue drains the ring through the SPL meter and the RTA every 50 ms and publishes readings to the
/// main actor. The audio callback never waits: a slow worker shows up as counted overrun frames.
enum MeasurementInputMonitorError: Error, LocalizedError, Equatable {
    case channelUnavailable
    case unsupportedFormat
    case allocationFailed
    case coreAudioFailure(String, Int32)

    var errorDescription: String? {
        switch self {
        case .channelUnavailable: "The selected microphone channel is unavailable."
        case .unsupportedFormat: "The monitor needs a 32-bit floating-point input stream."
        case .allocationFailed: "The monitor could not allocate its analysis buffers."
        case .coreAudioFailure(let action, let code): "Core Audio could not \(action) (\(code))."
        }
    }
}

@MainActor
final class MeasurementInputMonitor: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var reading: SPLReading?
    @Published private(set) var spectrum: RTASpectrum?
    @Published private(set) var overrunFrames: UInt64 = 0
    @Published private(set) var isCalibrated = false
    @Published private(set) var lastError: String?
    @Published private(set) var log = MeasurementLevelLog(calibrated: false, weighting: .a)

    var weighting = SPLWeighting.a
    var rtaSettings = RTASettings()
    var isLogging = false

    private let queue = DispatchQueue(label: "notchsixty.measurement.monitor", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var ring: MonitorSampleRing?
    private var context: OpaquePointer?
    private var ioProc: AudioDeviceIOProcID?
    private var deviceID: AudioDeviceID = 0
    private var pipeline: MeasurementMonitorPipeline?
    private var calibrationOffset = 0.0
    private var startedAt = Date()

    func start(microphone: AudioInputDevice, channel: Int) {
        guard !isRunning else { return }
        lastError = nil
        do {
            try openAndStart(microphone: microphone, channel: channel)
            isRunning = true
        } catch {
            teardown()
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func stop() {
        guard isRunning else { return }
        teardown()
        isRunning = false
    }

    /// Sets the meter so the tone now playing (an acoustic calibrator: 94 or 114 dB at 1 kHz) reads `referenceSPL`.
    func calibrate(toReferenceSPL referenceSPL: Double) {
        guard let pipeline else { return }
        queue.async { [weak self] in
            guard let offset = pipeline.calibrate(toReferenceSPL: referenceSPL) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.calibrationOffset = offset
                    self?.isCalibrated = true
                }
            }
        }
    }

    func resetReadings() {
        guard let pipeline else { return }
        queue.async { pipeline.reset() }
    }

    func writeLog(named name: String, in directory: URL) throws -> URL {
        try log.write(named: name, in: directory)
    }

    // MARK: - Core Audio

    private func openAndStart(microphone: AudioInputDevice, channel: Int) throws {
        var stream = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioObjectGetPropertyData(microphone.deviceID, &stream, 0, nil, &size, &asbd), "read the input format")
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, asbd.mSampleRate >= 8_000 else {
            throw MeasurementInputMonitorError.unsupportedFormat
        }
        guard channel >= 0, channel < Int(asbd.mChannelsPerFrame) else { throw MeasurementInputMonitorError.channelUnavailable }

        let sampleRate = asbd.mSampleRate
        let ring: MonitorSampleRing
        let pipeline: MeasurementMonitorPipeline
        do {
            ring = try MonitorSampleRing(capacityFrames: Self.ringFrames(sampleRate: sampleRate))
            pipeline = try MeasurementMonitorPipeline(
                ring: ring, sampleRate: sampleRate, weighting: weighting, rta: rtaSettings, calibrationOffsetDB: calibrationOffset)
        } catch {
            throw MeasurementInputMonitorError.allocationFailed
        }
        guard let context = N60MeasurementMonitorContextCreate(ring.handle, UInt32(channel)) else {
            throw MeasurementInputMonitorError.allocationFailed
        }
        self.ring = ring
        self.pipeline = pipeline
        self.context = context
        self.deviceID = microphone.deviceID
        log = MeasurementLevelLog(calibrated: isCalibrated, weighting: weighting)

        try Self.check(
            AudioDeviceCreateIOProcID(microphone.deviceID, N60MeasurementMonitorIOProc, UnsafeMutableRawPointer(context), &ioProc),
            "register the monitor callback")
        guard ioProc != nil else { throw MeasurementInputMonitorError.coreAudioFailure("register the monitor callback", -1) }
        startedAt = Date()
        startTimer(pipeline: pipeline)
        try Self.check(AudioDeviceStart(microphone.deviceID, ioProc), "start the monitor")
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        ioProc = nil
        queue.sync {}  // let a drain in flight finish before the analysers go
        if let context { N60MeasurementMonitorContextDestroy(context) }
        context = nil
        pipeline = nil
        ring = nil
    }

    private func startTimer(pipeline: MeasurementMonitorPipeline) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        source.setEventHandler { [weak self] in
            pipeline.drain()
            let reading = pipeline.meter.read()
            let spectrum = pipeline.rta.read()
            let overruns = pipeline.ring.overrunFrames
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    self.reading = reading
                    self.spectrum = spectrum
                    self.overrunFrames = overruns
                    if self.isLogging, Int(reading.elapsedSeconds) > Int(self.log.rows.last?.seconds ?? -1) {
                        self.log.append(seconds: reading.elapsedSeconds.rounded(.down), reading: reading)
                    }
                }
            }
        }
        timer = source
        source.resume()
    }

    /// About two seconds of audio, a power of two, so a stalled worker overruns instead of growing.
    nonisolated static func ringFrames(sampleRate: Double) -> Int {
        var n = 1 << 14
        while Double(n) < sampleRate * 2, n < (1 << 20) { n <<= 1 }
        return n
    }

    private static func check(_ code: OSStatus, _ action: String) throws {
        guard code == noErr else { throw MeasurementInputMonitorError.coreAudioFailure(action, code) }
    }
}
