import CoreAudio
import Foundation

enum CoreAudioOperation: String, Equatable, Sendable {
    case enumerateDevices
    case readOutputStreams
    case readDeviceUID
    case readDeviceName
    case readNominalSampleRate
    case readAvailableSampleRates
}

struct CoreAudioError: Error, Equatable, Sendable, LocalizedError {
    let operation: CoreAudioOperation
    let status: OSStatus
    let objectID: AudioObjectID

    var errorDescription: String? {
        "Core Audio \(operation.rawValue) failed for object \(objectID) with status \(formattedStatus)."
    }

    private var formattedStatus: String {
        let code = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]

        if bytes.allSatisfy({ (32...126).contains($0) }),
           let fourCC = String(bytes: bytes, encoding: .ascii) {
            return "'\(fourCC)' (\(status))"
        }

        return String(status)
    }
}
