import CoreAudio
import Foundation

// E15 S2: the engine's view of hardware events, as a protocol so tests inject a fake monitor instead of Core Audio.
// The production monitor is `AudioHardwareEventMonitor` (device list, sample rate, sleep, wake).

protocol AudioHardwareEvents: AnyObject {
    var onDeviceListChanged: (() -> Void)? { get set }
    var onSelectedOutputSampleRateChanged: (() -> Void)? { get set }
    var onWillSleep: (() -> Void)? { get set }
    var onDidWake: (() -> Void)? { get set }
    func start() throws
    func monitorSampleRate(of deviceID: AudioDeviceID?) throws
    func removeSelectedOutputSampleRateMonitor()
    func stop()
}

extension AudioHardwareEventMonitor: AudioHardwareEvents {}
