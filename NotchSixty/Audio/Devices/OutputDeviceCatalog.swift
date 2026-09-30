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

// MARK: - Room Correction Measurement Foundation

/// Control-plane representation of the deterministic excitation used by the
/// dedicated room-measurement transport. These arrays are prepared before an
/// IOProc starts; the realtime transport must consume preallocated storage only.
struct RoomCorrectionSweepProgram: Equatable, Sendable {
    var sampleRate: Double
    var sweepSamples: [Float]
    var inverseFilter: [Float]
    var leadInFrames: Int
    var tailFrames: Int

    var captureFrameCount: Int {
        leadInFrames + sweepSamples.count + tailFrames
    }
}

enum RoomCorrectionSweepGenerationError: Error, Equatable, LocalizedError {
    case invalidSettings
    case frameCountOverflow

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            return "Room-measurement sweep settings are invalid or unsafe for the selected sample rate."
        case .frameCountOverflow:
            return "Room-measurement sweep settings require an unsupported number of frames."
        }
    }
}

struct RoomCorrectionSweepGenerator: Sendable {
    static let maximumDurationSeconds = 30.0
    static let nyquistSafetyFactor = 0.98

    func makeProgram(settings: RoomCorrectionSweepSettings) throws -> RoomCorrectionSweepProgram {
        let sampleRate = settings.sampleRate
        let startFrequency = settings.startFrequencyHz
        let endFrequency = settings.endFrequencyHz
        let duration = settings.durationSeconds
        let fade = settings.fadeSeconds

        guard sampleRate.isFinite, sampleRate > 0,
              startFrequency.isFinite, startFrequency > 0,
              endFrequency.isFinite, endFrequency > startFrequency,
              endFrequency < sampleRate * 0.5 * Self.nyquistSafetyFactor,
              duration.isFinite, duration > 0, duration <= Self.maximumDurationSeconds,
              settings.levelDBFS.isFinite, settings.levelDBFS <= 0,
              settings.leadInSeconds.isFinite, settings.leadInSeconds >= 0,
              settings.tailSeconds.isFinite, settings.tailSeconds >= 0,
              fade.isFinite, fade >= 0, fade <= duration * 0.5 else {
            throw RoomCorrectionSweepGenerationError.invalidSettings
        }

        let sweepFrameCount = try frameCount(seconds: duration, sampleRate: sampleRate, minimum: 2)
        let leadInFrames = try frameCount(seconds: settings.leadInSeconds, sampleRate: sampleRate)
        let tailFrames = try frameCount(seconds: settings.tailSeconds, sampleRate: sampleRate)
        let fadeFrames = min(
            try frameCount(seconds: fade, sampleRate: sampleRate),
            sweepFrameCount / 2
        )
        guard leadInFrames <= Int.max - sweepFrameCount,
              leadInFrames + sweepFrameCount <= Int.max - tailFrames else {
            throw RoomCorrectionSweepGenerationError.frameCountOverflow
        }

        let logRatio = log(endFrequency / startFrequency)
        let timeScale = duration / logRatio
        let linearAmplitude = pow(10.0, settings.levelDBFS / 20.0)

        var sweep = [Float](repeating: 0, count: sweepFrameCount)
        for index in 0..<sweepFrameCount {
            let time = Double(index) / sampleRate
            let phase = 2.0 * Double.pi * startFrequency * timeScale
                * (exp(time / timeScale) - 1.0)
            var envelope = 1.0
            if fadeFrames > 1, index < fadeFrames {
                let position = Double(index) / Double(fadeFrames - 1)
                envelope *= 0.5 - 0.5 * cos(Double.pi * position)
            }
            if fadeFrames > 1, index >= sweepFrameCount - fadeFrames {
                let reverseIndex = sweepFrameCount - 1 - index
                let position = Double(reverseIndex) / Double(fadeFrames - 1)
                envelope *= 0.5 - 0.5 * cos(Double.pi * position)
            }
            sweep[index] = Float(linearAmplitude * envelope * sin(phase))
        }

        // Farina-style ESS inverse: time-reverse the excitation and compensate
        // its exponential energy distribution. Normalize only the inverse so
        // downstream deconvolution owns any absolute calibration scaling.
        var inverse = [Float](repeating: 0, count: sweepFrameCount)
        var inversePeak = 0.0
        for index in 0..<sweepFrameCount {
            let sourceIndex = sweepFrameCount - 1 - index
            let time = Double(index) / sampleRate
            let weighting = exp(-time * logRatio / duration)
            let value = Double(sweep[sourceIndex]) * weighting
            inverse[index] = Float(value)
            inversePeak = max(inversePeak, abs(value))
        }
        if inversePeak > 0 {
            let normalization = Float(1.0 / inversePeak)
            for index in inverse.indices {
                inverse[index] *= normalization
            }
        }

        return RoomCorrectionSweepProgram(
            sampleRate: sampleRate,
            sweepSamples: sweep,
            inverseFilter: inverse,
            leadInFrames: leadInFrames,
            tailFrames: tailFrames
        )
    }

    private func frameCount(
        seconds: Double,
        sampleRate: Double,
        minimum: Int = 0
    ) throws -> Int {
        let raw = seconds * sampleRate
        guard raw.isFinite, raw >= 0, raw <= Double(Int.max) else {
            throw RoomCorrectionSweepGenerationError.frameCountOverflow
        }
        return max(minimum, Int(raw.rounded()))
    }
}

enum RoomCorrectionMeasurementPass: String, Codable, Equatable, Sendable {
    case left
    case right
}

struct RoomCorrectionMeasurementPassPlan: Equatable, Sendable {
    var pass: RoomCorrectionMeasurementPass
    var captureStartFrame: Int
    var sweepStartFrame: Int
    var sweepEndFrameExclusive: Int
    var captureEndFrameExclusive: Int

    var captureFrameCount: Int {
        captureEndFrameExclusive - captureStartFrame
    }
}

struct RoomCorrectionCaptureDestination: Equatable, Sendable {
    var pass: RoomCorrectionMeasurementPass
    var frameIndex: Int
}

struct RoomCorrectionStereoOutputFrame: Equatable, Sendable {
    var left: Float
    var right: Float
}

/// Immutable control-plane timeline for one named listening position. It keeps
/// the left and right acoustic measurements independent while placing both
/// passes on one deterministic device timeline.
struct RoomCorrectionMeasurementPlan: Equatable, Sendable {
    var program: RoomCorrectionSweepProgram
    var settlingFrames: Int
    var leftPass: RoomCorrectionMeasurementPassPlan
    var rightPass: RoomCorrectionMeasurementPassPlan
    var totalFrameCount: Int

    init(
        program: RoomCorrectionSweepProgram,
        settlingSeconds: Double = 0.5
    ) throws {
        guard settlingSeconds.isFinite, settlingSeconds >= 0 else {
            throw RoomCorrectionSweepGenerationError.invalidSettings
        }
        let rawSettlingFrames = settlingSeconds * program.sampleRate
        guard rawSettlingFrames.isFinite,
              rawSettlingFrames <= Double(Int.max) else {
            throw RoomCorrectionSweepGenerationError.frameCountOverflow
        }

        let settlingFrames = Int(rawSettlingFrames.rounded())
        let captureFrames = program.captureFrameCount
        guard captureFrames >= program.sweepSamples.count,
              captureFrames <= Int.max - settlingFrames,
              captureFrames <= (Int.max - settlingFrames) / 2 else {
            throw RoomCorrectionSweepGenerationError.frameCountOverflow
        }

        let leftCaptureStart = 0
        let leftSweepStart = leftCaptureStart + program.leadInFrames
        let leftSweepEnd = leftSweepStart + program.sweepSamples.count
        let leftCaptureEnd = leftCaptureStart + captureFrames
        let rightCaptureStart = leftCaptureEnd + settlingFrames
        let rightSweepStart = rightCaptureStart + program.leadInFrames
        let rightSweepEnd = rightSweepStart + program.sweepSamples.count
        let rightCaptureEnd = rightCaptureStart + captureFrames

        self.program = program
        self.settlingFrames = settlingFrames
        self.leftPass = RoomCorrectionMeasurementPassPlan(
            pass: .left,
            captureStartFrame: leftCaptureStart,
            sweepStartFrame: leftSweepStart,
            sweepEndFrameExclusive: leftSweepEnd,
            captureEndFrameExclusive: leftCaptureEnd
        )
        self.rightPass = RoomCorrectionMeasurementPassPlan(
            pass: .right,
            captureStartFrame: rightCaptureStart,
            sweepStartFrame: rightSweepStart,
            sweepEndFrameExclusive: rightSweepEnd,
            captureEndFrameExclusive: rightCaptureEnd
        )
        self.totalFrameCount = rightCaptureEnd
    }

    func outputFrame(at frame: Int) -> RoomCorrectionStereoOutputFrame {
        if frame >= leftPass.sweepStartFrame, frame < leftPass.sweepEndFrameExclusive {
            let index = frame - leftPass.sweepStartFrame
            return RoomCorrectionStereoOutputFrame(
                left: program.sweepSamples[index],
                right: 0
            )
        }
        if frame >= rightPass.sweepStartFrame, frame < rightPass.sweepEndFrameExclusive {
            let index = frame - rightPass.sweepStartFrame
            return RoomCorrectionStereoOutputFrame(
                left: 0,
                right: program.sweepSamples[index]
            )
        }
        return RoomCorrectionStereoOutputFrame(left: 0, right: 0)
    }

    func captureDestination(at frame: Int) -> RoomCorrectionCaptureDestination? {
        if frame >= leftPass.captureStartFrame, frame < leftPass.captureEndFrameExclusive {
            return RoomCorrectionCaptureDestination(
                pass: .left,
                frameIndex: frame - leftPass.captureStartFrame
            )
        }
        if frame >= rightPass.captureStartFrame, frame < rightPass.captureEndFrameExclusive {
            return RoomCorrectionCaptureDestination(
                pass: .right,
                frameIndex: frame - rightPass.captureStartFrame
            )
        }
        return nil
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
            mScope: kAudioObjectPropertyScopeOutput,
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
            mScope: kAudioObjectPropertyScopeInput,
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
