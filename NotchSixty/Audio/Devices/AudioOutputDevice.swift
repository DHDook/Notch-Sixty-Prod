import CoreAudio

struct AudioSampleRateRange: Equatable, Hashable, Sendable {
    let minimum: Double
    let maximum: Double

    init(minimum: Double, maximum: Double) {
        self.minimum = Swift.min(minimum, maximum)
        self.maximum = Swift.max(minimum, maximum)
    }

    func contains(_ sampleRate: Double) -> Bool {
        sampleRate >= minimum && sampleRate <= maximum
    }
}

struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    typealias ID = String

    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let nominalSampleRate: Double
    let availableSampleRateRanges: [AudioSampleRateRange]

    var id: String { uid }

    func supports(sampleRate: Double) -> Bool {
        availableSampleRateRanges.contains { $0.contains(sampleRate) }
    }
}
