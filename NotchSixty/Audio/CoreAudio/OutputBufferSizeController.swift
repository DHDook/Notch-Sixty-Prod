import CoreAudio
import Foundation

/// E4 S7: reads and sets an output device's I/O buffer size. The HAL keeps
/// this per process, so changing it affects only this app's I/O on the device.
protocol OutputBufferSizeControlling: AnyObject {
    func bufferFrameSizeRange(deviceID: AudioDeviceID) throws -> ClosedRange<UInt32>
    func bufferFrameSize(deviceID: AudioDeviceID) throws -> UInt32
    func setBufferFrameSize(_ frames: UInt32, deviceID: AudioDeviceID) throws
}

enum OutputBufferSizeError: Error, Equatable, LocalizedError {
    case coreAudio(operation: String, status: OSStatus)
    case invalidRange

    var errorDescription: String? {
        switch self {
        case let .coreAudio(operation, status):
            return "Could not \(operation) (Core Audio status \(status))."
        case .invalidRange:
            return "The output device reported an invalid buffer size range."
        }
    }
}

final class CoreAudioOutputBufferSizeController: OutputBufferSizeControlling {
    func bufferFrameSizeRange(deviceID: AudioDeviceID) throws -> ClosedRange<UInt32> {
        var address = Self.address(kAudioDevicePropertyBufferFrameSizeRange)
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &range)
        guard status == noErr else {
            throw OutputBufferSizeError.coreAudio(operation: "read the buffer size range", status: status)
        }
        guard range.mMinimum.isFinite, range.mMaximum.isFinite,
              range.mMinimum >= 1, range.mMaximum >= range.mMinimum,
              range.mMaximum <= Double(UInt32.max) else {
            throw OutputBufferSizeError.invalidRange
        }
        return UInt32(range.mMinimum.rounded(.up))...UInt32(range.mMaximum.rounded(.down))
    }

    func bufferFrameSize(deviceID: AudioDeviceID) throws -> UInt32 {
        var address = Self.address(kAudioDevicePropertyBufferFrameSize)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames)
        guard status == noErr else {
            throw OutputBufferSizeError.coreAudio(operation: "read the buffer size", status: status)
        }
        return frames
    }

    func setBufferFrameSize(_ frames: UInt32, deviceID: AudioDeviceID) throws {
        var address = Self.address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        )
        guard status == noErr else {
            throw OutputBufferSizeError.coreAudio(operation: "set the buffer size", status: status)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

/// The lowest-latency output buffer for Quiet Zone, with the size it replaced
/// recorded per device so it can be put back.
///
/// Size chosen: the device's minimum, but never below 32 frames or 0.25 ms
/// (96 frames at 384 kHz: smaller buffers spend more time in callback overhead
/// than in audio), and never above the current size or the audio-unit rack's
/// maximum slice.
final class LowLatencyOutputBufferProfile {
    static let floorFrames: UInt32 = 32
    static let floorSeconds = 0.000_25

    static func floor(sampleRate: Double) -> UInt32 {
        guard sampleRate.isFinite, sampleRate > 0 else { return floorFrames }
        return max(floorFrames, UInt32(min((sampleRate * floorSeconds).rounded(.up), 65_536)))
    }

    private let controller: any OutputBufferSizeControlling
    private(set) var isActive = false
    /// Device UID → buffer size in use before the profile changed it.
    private(set) var originalFrames: [String: UInt32] = [:]
    /// Device UID → buffer size the profile set.
    private(set) var appliedFrames: [String: UInt32] = [:]

    init(controller: any OutputBufferSizeControlling) {
        self.controller = controller
    }

    static func lowestFrames(
        range: ClosedRange<UInt32>,
        current: UInt32,
        sampleRate: Double,
        maximumFramesPerSlice: UInt32?
    ) -> UInt32 {
        var frames = max(range.lowerBound, floor(sampleRate: sampleRate))
        frames = min(frames, range.upperBound)
        if let maximumFramesPerSlice { frames = min(frames, maximumFramesPerSlice) }
        return min(frames, max(current, range.lowerBound))
    }

    func activate() { isActive = true }

    /// Applies the profile to a device about to be opened. Returns the size
    /// set, or nil when the profile is off.
    @discardableResult
    func apply(
        to deviceID: AudioDeviceID,
        uid: String,
        sampleRate: Double,
        maximumFramesPerSlice: UInt32? = nil
    ) throws -> UInt32? {
        guard isActive else { return nil }
        let current = try controller.bufferFrameSize(deviceID: deviceID)
        if originalFrames[uid] == nil { originalFrames[uid] = current }
        let target = Self.lowestFrames(
            range: try controller.bufferFrameSizeRange(deviceID: deviceID),
            current: originalFrames[uid] ?? current,
            sampleRate: sampleRate,
            maximumFramesPerSlice: maximumFramesPerSlice
        )
        if target != current {
            try controller.setBufferFrameSize(target, deviceID: deviceID)
        }
        appliedFrames[uid] = target
        return target
    }

    /// Turns the profile off and restores every recorded device that is
    /// present (`deviceID(uid)` returns nil for an absent one). A device that
    /// is absent or fails to restore keeps its record, so a later call retries
    /// it. Call only while no transport is open on these devices. Returns the
    /// UIDs restored and the errors for those that failed.
    @discardableResult
    func deactivate(deviceID: (String) -> AudioDeviceID?) -> (restored: [String], failures: [Error]) {
        isActive = false
        var restored: [String] = []
        var failures: [Error] = []
        for (uid, frames) in originalFrames.sorted(by: { $0.key < $1.key }) {
            guard let id = deviceID(uid) else { continue }
            do {
                try controller.setBufferFrameSize(frames, deviceID: id)
                restored.append(uid)
                originalFrames[uid] = nil
            } catch {
                failures.append(error)
            }
        }
        appliedFrames = [:]
        return (restored, failures)
    }
}
