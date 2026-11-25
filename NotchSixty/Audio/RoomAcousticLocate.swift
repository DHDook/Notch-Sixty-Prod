import Foundation

// E29 S5 (`e29.room-model`): acoustic locate, the Swift side of `n60_roommodel_locate` (design note 8). Offline and
// control-plane only: it reads impulse responses the project already keeps, never records anything, never arms
// anything and never touches an engine snapshot. The maths is in libn60core.

/// One speaker's impulse response to the seat being located.
struct RoomLocateSource: Equatable, Sendable {
    var speakerName: String
    /// Metres, room frame.
    var speakerPosition: RoomPosition
    var impulseResponse: [Float]
    var sampleRate: Double
    /// True for loopback or reference timing (index 0 is the drive instant).
    var timingTrusted: Bool
    var isSub: Bool = false
    var latencySeconds: Double = 0
}

struct RoomLocateFix: Equatable, Sendable {
    struct SpeakerCheck: Equatable, Sendable {
        var speakerName: String
        /// Flight distance from the arrival time, and the distance from the fitted seat to the entered speaker position.
        var measuredMetres: Double
        var geometricMetres: Double
        var differenceMetres: Double { measuredMetres - geometricMetres }
    }
    var position: RoomPosition
    var residualMetres: Double
    var speakersUsed: Int
    var checks: [SpeakerCheck]
    var excludedSubs: Int
}

enum RoomLocateRefusal: Equatable, Sendable {
    case noLoopbackTiming
    case tooFewSpeakers
    case noArrival
    case degenerate
    case mixedRates
    case failed

    var message: String {
        switch self {
        case .noLoopbackTiming: "Locate needs loopback timing on every speaker measurement of this seat. Measure it again with the loopback or reference timing."
        case .tooFewSpeakers: "Locate needs measurements from at least two full-range speakers at this seat (subwoofers are not used)."
        case .noArrival: "Could not find a clear high-frequency arrival in the measurements."
        case .degenerate: "The speakers need different positions to locate a seat."
        case .mixedRates: "The speaker measurements of this seat use different sample rates. Measure them again at one rate."
        case .failed: "Locate could not run."
        }
    }
}

enum RoomLocateOutcome: Equatable, Sendable {
    case located(RoomLocateFix)
    case refused(RoomLocateRefusal)
}

enum RoomAcousticLocator {
    static let speedOfSound = Double(N60_ROOMMODEL_DEFAULT_SOUND_SPEED)

    /// Locates the microphone from the speakers' impulse responses at an assumed height.
    static func locate(_ sources: [RoomLocateSource], seatHeight: Double) -> RoomLocateOutcome {
        guard let rate = sources.first?.sampleRate, sources.count <= Int(N60_ROOMMODEL_LOCATE_MAX_SPEAKERS) else {
            return .refused(.tooFewSpeakers)
        }
        guard sources.allSatisfy({ $0.sampleRate == rate }) else { return .refused(.mixedRates) }
        var query = n60_roommodel_locate_query()
        query.structSize = UInt32(MemoryLayout<n60_roommodel_locate_query>.size)
        query.speakerCount = UInt32(sources.count)
        query.sampleRate = rate
        query.seatHeightM = seatHeight
        var result = n60_roommodel_locate_result()
        result.structSize = UInt32(MemoryLayout<n60_roommodel_locate_result>.size)

        // Keep every IR alive for the call: the C structs hold raw pointers.
        func run(_ index: Int, _ built: [n60_roommodel_locate_speaker]) -> Int32 {
            if index == sources.count {
                return built.withUnsafeBufferPointer { n60_roommodel_locate(&query, $0.baseAddress, &result) }
            }
            return sources[index].impulseResponse.withUnsafeBufferPointer { ir in
                var s = n60_roommodel_locate_speaker()
                let p = sources[index].speakerPosition
                s.position = (p.x, p.y, p.z)
                s.ir = ir.baseAddress
                s.irFrames = UInt32(ir.count)
                s.timingTrusted = sources[index].timingTrusted ? 1 : 0
                s.isSub = sources[index].isSub ? 1 : 0
                s.latencySeconds = sources[index].latencySeconds
                return run(index + 1, built + [s])
            }
        }
        let status = run(0, [])
        if status == N60_ROOMMODEL_NOT_MEASURED {
            switch result.reason {
            case N60_ROOMMODEL_REASON_NO_LOOPBACK_TIMING: return .refused(.noLoopbackTiming)
            case N60_ROOMMODEL_REASON_TOO_FEW_SPEAKERS: return .refused(.tooFewSpeakers)
            case N60_ROOMMODEL_REASON_NO_ARRIVAL: return .refused(.noArrival)
            case N60_ROOMMODEL_REASON_DEGENERATE: return .refused(.degenerate)
            default: return .refused(.failed)
            }
        }
        guard status == N60_ROOMMODEL_OK else { return .refused(.failed) }

        let distances = withUnsafeBytes(of: result.distanceM) { Array($0.bindMemory(to: Double.self)) }
        let fits = withUnsafeBytes(of: result.fitDistanceM) { Array($0.bindMemory(to: Double.self)) }
        let statuses = withUnsafeBytes(of: result.speakerStatus) { Array($0.bindMemory(to: Int32.self)) }
        var checks: [RoomLocateFix.SpeakerCheck] = []
        var subs = 0
        for (i, source) in sources.enumerated() {
            if statuses[i] == N60_ROOMMODEL_LOCATE_SPEAKER_SUB { subs += 1 }
            guard statuses[i] == N60_ROOMMODEL_LOCATE_SPEAKER_USED else { continue }
            checks.append(.init(speakerName: source.speakerName, measuredMetres: distances[i], geometricMetres: fits[i]))
        }
        let position = RoomPosition(
            x: result.position.0, y: result.position.1, z: result.position.2, source: .acousticLocate,
            uncertaintyMetres: result.uncertaintyM)
        return .located(RoomLocateFix(
            position: position, residualMetres: result.residualRmsM, speakersUsed: Int(result.speakersUsed),
            checks: checks, excludedSubs: subs))
    }

    /// The time alignment the located seat implies, in milliseconds: how much later the nearer feed must play so both
    /// arrive together. Compared with the current feed calibration as a cross-check, never applied.
    static func alignmentDelaysMs(left: Double, right: Double) -> (left: Double, right: Double) {
        let ms = (right - left) / speedOfSound * 1000
        return ms >= 0 ? (ms, 0) : (0, -ms)
    }

    /// Sentence for the delay cross-check, or nil when the feeds agree within 0.1 ms or there is no calibration.
    static func delayCrossCheck(left: Double, right: Double, calibration: StereoBassAlignment?) -> String? {
        guard let calibration else { return nil }
        let wanted = alignmentDelaysMs(left: left, right: right)
        let wantedDiff = wanted.left - wanted.right
        let currentDiff = calibration.left.delayMs - calibration.right.delayMs
        guard abs(wantedDiff - currentDiff) > 0.1 else { return nil }
        return String(
            format: "From this seat the left feed would need %.2f ms more delay than the right; your feed delays differ by %.2f ms.",
            wantedDiff, currentDiff)
    }
}
