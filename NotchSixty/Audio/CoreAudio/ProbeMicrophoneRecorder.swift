import CoreAudio
import Foundation

/// E19 S12c: records one microphone channel into memory on the microphone's own clock, with an input-only IOProc and the
/// monitor ring (the `MeasurementInputMonitor` pattern: the callback only pushes into the SPSC ring, a 50 ms timer drains it).
@MainActor
final class ProbeMicrophoneRecorder: ProbeMicrophoneRecording {
    let sampleRate: Double
    private let deviceID: AudioDeviceID
    private let ring: MonitorSampleRing
    private var context: OpaquePointer?
    private var ioProc: AudioDeviceIOProcID?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "notchsixty.probe.recorder", qos: .userInitiated)
    private let store = Store()

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        func append(_ chunk: [Float]) { lock.lock(); samples.append(contentsOf: chunk); lock.unlock() }
        func take() -> [Float] { lock.lock(); defer { lock.unlock() }; let out = samples; samples = []; return out }
    }

    init(microphone: AudioInputDevice, channel: Int) throws {
        var stream = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(microphone.deviceID, &stream, 0, nil, &size, &asbd)
        guard status == noErr else { throw MeasurementInputMonitorError.coreAudioFailure("read the input format", status) }
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, asbd.mSampleRate >= 8_000 else { throw MeasurementInputMonitorError.unsupportedFormat }
        guard channel >= 0, channel < Int(asbd.mChannelsPerFrame) else { throw MeasurementInputMonitorError.channelUnavailable }
        sampleRate = asbd.mSampleRate
        deviceID = microphone.deviceID
        do { ring = try MonitorSampleRing(capacityFrames: MeasurementInputMonitor.ringFrames(sampleRate: asbd.mSampleRate)) } catch {
            throw MeasurementInputMonitorError.allocationFailed
        }
        guard let context = N60MeasurementMonitorContextCreate(ring.handle, UInt32(channel)) else {
            throw MeasurementInputMonitorError.allocationFailed
        }
        self.context = context
    }

    deinit {
        // An abandoned recorder (dropped between `begin` and `finish`) stops its callback before the context goes.
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        if let context { N60MeasurementMonitorContextDestroy(context) }
    }

    func begin() throws {
        ring.reset()
        _ = store.take()
        guard let context else { throw MeasurementInputMonitorError.allocationFailed }
        var status = AudioDeviceCreateIOProcID(deviceID, N60MeasurementMonitorIOProc, UnsafeMutableRawPointer(context), &ioProc)
        guard status == noErr, ioProc != nil else { throw MeasurementInputMonitorError.coreAudioFailure("register the recorder", status) }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        let ring = self.ring
        let store = self.store
        source.setEventHandler { store.append(ring.pop(maximum: ring.availableFrames)) }
        timer = source
        source.resume()
        status = AudioDeviceStart(deviceID, ioProc)
        guard status == noErr else {
            _ = finish()
            throw MeasurementInputMonitorError.coreAudioFailure("start the recorder", status)
        }
    }

    func finish() -> [Float] {
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        ioProc = nil
        timer?.cancel()
        timer = nil
        queue.sync {}
        store.append(ring.pop(maximum: ring.availableFrames))
        return store.take()
    }
}
