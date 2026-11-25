import Observation
import CoreAudio
import Foundation

struct DSPGainConfiguration: Equatable, Codable, Sendable {
    static let inputPreampRange = -60.0...24.0
    static let headroomAttenuationRange = -48.0...0.0
    static let outputGainRange = -60.0...12.0

    var inputPreampDB: Double = 0
    var headroomAttenuationDB: Double = 0
    var outputGainDB: Double = 0

    static func linearGain(forDB db: Double) -> Float {
        Float(pow(10.0, db / 20.0))
    }
}

enum DSPGainConfigurationError: Error, LocalizedError, Equatable {
    case invalidInputPreamp(Double)
    case invalidHeadroomAttenuation(Double)
    case invalidOutputGain(Double)

    var errorDescription: String? {
        switch self {
        case .invalidInputPreamp(let value):
            return "Input preamp \(value) dB is outside the supported -60...+24 dB range."
        case .invalidHeadroomAttenuation(let value):
            return "Headroom attenuation \(value) dB is outside the supported -48...0 dB range."
        case .invalidOutputGain(let value):
            return "Output gain \(value) dB is outside the supported -60...+12 dB range."
        }
    }
}
