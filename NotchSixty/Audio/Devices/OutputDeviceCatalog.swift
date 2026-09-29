import AVFoundation
import CoreAudio
import CoreFoundation
import Foundation

protocol OutputDeviceCataloging {
    func outputDevices() throws -> [AudioOutputDevice]
}

protocol InputDeviceCataloging {
    func inputDevices() throws -> [AudioInputDevice]
}

struct CoreAudioOutputDeviceCatalog: OutputDeviceCataloging {
    func outputDevices() throws -> [AudioOutputDevice] {
        try CoreAudioDeviceCatalogSupport.allDeviceIDs()
            .filter { try CoreAudioDeviceCatalogSupport.hasOutputStreams($0) }
            .map { try CoreAudioDeviceCatalogSupport.makeOutputDevice(deviceID: $0) }
            .sorted { lhs, rhs in
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if comparison == .orderedSame {
                    return lhs.uid < rhs.uid
                }
                return comparison == .orderedAscending
            }
    }
}

struct CoreAudioInputDeviceCatalog: InputDeviceCataloging {
    func inputDevices() throws -> [AudioInputDevice] {
        try CoreAudioDeviceCatalogSupport.allDeviceIDs()
            .filter { try CoreAudioDeviceCatalogSupport.hasInputStreams($0) }
            .map { try CoreAudioDeviceCatalogSupport.makeInputDevice(deviceID: $0) }
            .sorted { lhs, rhs in
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if comparison == .orderedSame {
                    return lhs.uid < rhs.uid
                }
                return comparison == .orderedAscending
            }
    }
}

enum MicrophonePermissionStatus: String, Codable, Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized

    init(_ authorizationStatus: AVAuthorizationStatus) {
        switch authorizationStatus {
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        @unknown default:
            self = .denied
        }
    }
}

protocol MicrophonePermissionRequesting: Sendable {
    func currentStatus() -> MicrophonePermissionStatus
    func requestAccess() async -> MicrophonePermissionStatus
}

struct AVFoundationMicrophonePermissionClient: MicrophonePermissionRequesting {
    func currentStatus() -> MicrophonePermissionStatus {
        MicrophonePermissionStatus(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    func requestAccess() async -> MicrophonePermissionStatus {
        let current = currentStatus()
        guard current == .notDetermined else { return current }

        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .authorized : currentStatus()
    }
}

enum RoomCorrectionMicrophoneCalibrationError: Error, Equatable, LocalizedError {
    case empty
    case malformedLine(Int)
    case invalidFrequency(line: Int)
    case invalidGain(line: Int)
    case insufficientUniquePoints
    case invalidInterpolationFrequency
    case invalidStoredCurve

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The microphone calibration file does not contain any calibration points."
        case .malformedLine(let line):
            return "Microphone calibration line \(line) must contain exactly two numeric columns: frequency in Hz and gain in dB."
        case .invalidFrequency(let line):
            return "Microphone calibration line \(line) contains an invalid frequency."
        case .invalidGain(let line):
            return "Microphone calibration line \(line) contains an invalid gain value."
        case .insufficientUniquePoints:
            return "Microphone calibration requires at least two unique frequency points."
        case .invalidInterpolationFrequency:
            return "Microphone calibration can only be evaluated at a finite positive frequency."
        case .invalidStoredCurve:
            return "Stored microphone calibration points are not finite and strictly increasing in frequency."
        }
    }
}

struct RoomCorrectionMicrophoneCalibrationParser: Sendable {
    func parse(_ text: String, sourceName: String? = nil) throws -> RoomCorrectionMicrophoneCalibration {
        var pointsByFrequency: [Double: (sum: Double, count: Int)] = [:]
        var sawDataLine = false

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("*") || line.hasPrefix("//") {
                continue
            }

            for marker in ["//", "#", ";"] {
                if let range = line.range(of: marker) {
                    line = String(line[..<range.lowerBound])
                }
            }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            sawDataLine = true
            let normalized = line.replacingOccurrences(of: ",", with: " ")
            let fields = normalized.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2 else {
                throw RoomCorrectionMicrophoneCalibrationError.malformedLine(lineNumber)
            }
            guard let frequency = Double(fields[0]), frequency.isFinite, frequency > 0 else {
                throw RoomCorrectionMicrophoneCalibrationError.invalidFrequency(line: lineNumber)
            }
            guard let gain = Double(fields[1]), gain.isFinite else {
                throw RoomCorrectionMicrophoneCalibrationError.invalidGain(line: lineNumber)
            }

            let previous = pointsByFrequency[frequency] ?? (sum: 0, count: 0)
            pointsByFrequency[frequency] = (previous.sum + gain, previous.count + 1)
        }

        guard sawDataLine else {
            throw RoomCorrectionMicrophoneCalibrationError.empty
        }
        guard pointsByFrequency.count >= 2 else {
            throw RoomCorrectionMicrophoneCalibrationError.insufficientUniquePoints
        }

        let points = pointsByFrequency
            .map { frequency, aggregate in
                RoomCorrectionCalibrationPoint(
                    frequencyHz: frequency,
                    gainDB: aggregate.sum / Double(aggregate.count)
                )
            }
            .sorted { $0.frequencyHz < $1.frequencyHz }

        return RoomCorrectionMicrophoneCalibration(sourceName: sourceName, points: points)
    }
}

extension RoomCorrectionMicrophoneCalibration {
    func gainDB(at frequencyHz: Double) throws -> Double {
        guard frequencyHz.isFinite, frequencyHz > 0 else {
            throw RoomCorrectionMicrophoneCalibrationError.invalidInterpolationFrequency
        }
        guard points.count >= 2 else {
            throw RoomCorrectionMicrophoneCalibrationError.invalidStoredCurve
        }

        var previousFrequency = 0.0
        for point in points {
            guard point.frequencyHz.isFinite,
                  point.frequencyHz > previousFrequency,
                  point.gainDB.isFinite else {
                throw RoomCorrectionMicrophoneCalibrationError.invalidStoredCurve
            }
            previousFrequency = point.frequencyHz
        }

        if frequencyHz <= points[0].frequencyHz { return points[0].gainDB }
        if frequencyHz >= points[points.count - 1].frequencyHz { return points[points.count - 1].gainDB }

        for upperIndex in 1..<points.count {
            let upper = points[upperIndex]
            guard frequencyHz <= upper.frequencyHz else { continue }
            let lower = points[upperIndex - 1]
            let logLower = log(lower.frequencyHz)
            let logUpper = log(upper.frequencyHz)
            let position = (log(frequencyHz) - logLower) / (logUpper - logLower)
            return lower.gainDB + position * (upper.gainDB - lower.gainDB)
        }

        return points[points.count - 1].gainDB
    }
}

private enum CoreAudioDeviceCatalogSupport {
    static func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            ),
            operation: .enumerateDevices,
            objectID: AudioObjectID(kAudioObjectSystemObject)
        )

        guard dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)

        let status = deviceIDs.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }

        try check(
            status,
            operation: .enumerateDevices,
            objectID: AudioObjectID(kAudioObjectSystemObject)
        )

        return deviceIDs
    }

    static func hasOutputStreams(_ deviceID: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),
            operation: .readOutputStreams,
            objectID: deviceID
        )

        return dataSize > 0
    }

    static func hasInputStreams(_ deviceID: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == 0 else {
            throw CoreAudioTransportError.operationFailed(
                operation: "read input streams for device \(deviceID)",
                status: status
            )
        }
        return dataSize > 0
    }

    static func makeOutputDevice(deviceID: AudioDeviceID) throws -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: deviceID,
            uid: try readString(
                deviceID: deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                operation: .readDeviceUID
            ),
            name: try readString(
                deviceID: deviceID,
                selector: kAudioObjectPropertyName,
                operation: .readDeviceName
            ),
            nominalSampleRate: try readNominalSampleRate(deviceID: deviceID),
            availableSampleRateRanges: try readAvailableSampleRateRanges(deviceID: deviceID)
        )
    }

    static func makeInputDevice(deviceID: AudioDeviceID) throws -> AudioInputDevice {
        AudioInputDevice(
            deviceID: deviceID,
            uid: try readString(
                deviceID: deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                operation: .readDeviceUID
            ),
            name: try readString(
                deviceID: deviceID,
                selector: kAudioObjectPropertyName,
                operation: .readDeviceName
            ),
            nominalSampleRate: try readNominalSampleRate(deviceID: deviceID),
            availableSampleRateRanges: try readAvailableSampleRateRanges(deviceID: deviceID)
        )
    }

    static func readString(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        operation: CoreAudioOperation
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.stride)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }

        try check(status, operation: operation, objectID: deviceID)
        return value as String
    }

    static func readNominalSampleRate(deviceID: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)

        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate),
            operation: .readNominalSampleRate,
            objectID: deviceID
        )

        return sampleRate
    }

    static func readAvailableSampleRateRanges(deviceID: AudioDeviceID) throws -> [AudioSampleRateRange] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),
            operation: .readAvailableSampleRates,
            objectID: deviceID
        )

        guard dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioValueRange>.stride
        var ranges = [AudioValueRange](
            repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
            count: count
        )

        let status = ranges.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }

        try check(status, operation: .readAvailableSampleRates, objectID: deviceID)

        return ranges
            .map { AudioSampleRateRange(minimum: $0.mMinimum, maximum: $0.mMaximum) }
            .sorted {
                if $0.minimum == $1.minimum {
                    return $0.maximum < $1.maximum
                }
                return $0.minimum < $1.minimum
            }
    }

    static func check(
        _ status: OSStatus,
        operation: CoreAudioOperation,
        objectID: AudioObjectID
    ) throws {
        guard status == 0 else {
            throw CoreAudioError(operation: operation, status: status, objectID: objectID)
        }
    }
}
