import CryptoKit
import Foundation

// E29 S1: the shared room position model, read-only. Points (speakers, subs, seats, ears, microphones) and the
// measured paths between them, built as an index over records that already exist. Measured data stays authoritative;
// positions are optional. Pure value types on the control plane: no engine access, nothing realtime, nothing here
// arms or enables anything, and no derived (interpolated) path exists yet (S3 adds those, never persisted).

enum RoomPointKind: String, Codable, CaseIterable, Sendable {
    case speakerFeed, subLane, seat, ear, referenceMic, surveyPoint
}

enum RoomPositionSource: String, Codable, Sendable {
    case typed, acousticLocate, camera, unknown
}

/// Metres in the room frame: origin front-left floor corner, x across, y into the room, z up.
struct RoomPosition: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double
    var source: RoomPositionSource
    /// One-sigma uncertainty, metres; nil when unknown.
    var uncertaintyMetres: Double?

    func distance(to other: RoomPosition) -> Double {
        let dx = x - other.x, dy = y - other.y, dz = z - other.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

struct RoomPoint: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: RoomPointKind
    var name: String
    var position: RoomPosition?
}

/// How far a path's timing can be trusted (design note 3). Only `.loopback` and `.reference` carry a usable
/// relative phase between sources.
enum RoomTimingTier: String, Codable, Sendable {
    case loopback, reference, none

    init(storedName: String?) {
        switch storedName?.lowercased() {
        case "loopback": self = .loopback
        case "reference": self = .reference
        default: self = .none
        }
    }

    var carriesPhase: Bool { self != .none }
}

/// Where a path's data lives today. The model never copies or rewrites it.
enum RoomPathOrigin: Codable, Equatable, Hashable, Sendable {
    case roomCorrectionPosition(id: UUID, channel: String)
    case measurementRecord(id: UUID)
    case combinedAncRecord(index: Int)
}

/// What a path was measured under, for the one staleness rule.
struct RoomPathStamps: Codable, Equatable, Sendable {
    var bassFingerprint: AncBassPathFingerprint?
    var arrangementRevision: String?
    var outputDeviceUID: String?
    var outputGainDB: Double?
    var calibrationName: String?
}

/// A measured path from a source point to a receiver point. Derived paths do not exist in S1.
struct RoomPath: Identifiable, Equatable, Sendable {
    var id: UUID
    var source: UUID
    var receiver: UUID
    var origin: RoomPathOrigin
    var sampleRate: Double
    var timingTier: RoomTimingTier
    /// Capture session, when the origin knows it; relative phase across sources needs the same non-nil session.
    var sessionID: String?
    var bandLowHz: Double?
    var bandHighHz: Double?
    var windowSeconds: Double?
    var stamps: RoomPathStamps
    var date: Date?
    var hasImpulseResponse: Bool
    /// The measurement's own pass flag (complete sweep, not clipped); false reads as poor quality, not stale.
    var qualityOK: Bool

    /// Design note 3: the phase between two paths is trusted only when both carry timing, share one rate and one
    /// capture session. Anything else is magnitude-only for cross-source use.
    func phaseComparable(with other: RoomPath) -> Bool {
        timingTier.carriesPhase && other.timingTier.carriesPhase && sampleRate == other.sampleRate
            && sessionID != nil && sessionID == other.sessionID
    }
}

/// What the world looks like now, for the staleness rule. A nil field means "not checked".
struct RoomModelContext: Equatable, Sendable {
    var bassFingerprint: AncBassPathFingerprint?
    /// True when a bass path is in play (a sub in the path): a path with no stored fingerprint then reads stale.
    var bassPathActive: Bool = false
    var arrangementRevision: String?
    var outputDeviceUID: String?
    var outputGainDB: Double?
    var calibrationName: String?

    /// Same tolerance as the device-volume check the E26 stamp uses.
    static let gainToleranceDB = 0.5
}

enum RoomPathStaleReason: String, Codable, CaseIterable, Sendable {
    case bassPath, arrangement, outputDevice, outputGain, calibration
}

enum RoomPathState: Equatable, Sendable {
    case measured
    case stale([RoomPathStaleReason])
}

enum RoomModelRule {
    /// One message for every consumer.
    static let staleMessage = "Your speakers or bass settings changed. Measure this seat again."

    static func staleReasons(of path: RoomPath, in context: RoomModelContext) -> [RoomPathStaleReason] {
        var out: [RoomPathStaleReason] = []
        let s = path.stamps
        if let current = context.bassFingerprint {
            if let stored = s.bassFingerprint { if stored != current { out.append(.bassPath) } }
            else if context.bassPathActive { out.append(.bassPath) }
        } else if s.bassFingerprint == nil, context.bassPathActive {
            out.append(.bassPath)
        }
        if let a = context.arrangementRevision, let b = s.arrangementRevision, a != b { out.append(.arrangement) }
        if let a = context.outputDeviceUID, let b = s.outputDeviceUID, a != b { out.append(.outputDevice) }
        if let a = context.outputGainDB, let b = s.outputGainDB, abs(a - b) > RoomModelContext.gainToleranceDB {
            out.append(.outputGain)
        }
        if let a = context.calibrationName, let b = s.calibrationName, a != b { out.append(.calibration) }
        return out
    }

    static func state(of path: RoomPath, in context: RoomModelContext) -> RoomPathState {
        let r = staleReasons(of: path, in: context)
        return r.isEmpty ? .measured : .stale(r)
    }
}

struct RoomModelCompleteness: Equatable, Sendable {
    var pointCount: Int
    var pathCount: Int
    var unpositionedPointIDs: [UUID]
    var stalePathIDs: [UUID]
    var poorQualityPathIDs: [UUID]
    /// Paths with timing tier none: magnitude-only for any cross-source use.
    var magnitudeOnlyPathIDs: [UUID]
    /// Seats with no measured path into them.
    var seatsWithoutPathIDs: [UUID]
}

/// Points and measured paths. `RoomModel` is a value; build it with `RoomModelAdapter`.
struct RoomModel: Equatable, Sendable {
    private(set) var points: [RoomPoint]
    private(set) var paths: [RoomPath]

    init(points: [RoomPoint] = [], paths: [RoomPath] = []) {
        var seenPoints = Set<UUID>()
        self.points = points.filter { seenPoints.insert($0.id).inserted }
        var seenPaths = Set<UUID>()
        let known = Set(self.points.map(\.id))
        self.paths = paths.filter { known.contains($0.source) && known.contains($0.receiver) && seenPaths.insert($0.id).inserted }
    }

    func point(_ id: UUID) -> RoomPoint? { points.first { $0.id == id } }
    func paths(from source: UUID) -> [RoomPath] { paths.filter { $0.source == source } }
    func paths(to receiver: UUID) -> [RoomPath] { paths.filter { $0.receiver == receiver } }
    func paths(from source: UUID, to receiver: UUID) -> [RoomPath] {
        paths.filter { $0.source == source && $0.receiver == receiver }
    }

    func completeness(in context: RoomModelContext) -> RoomModelCompleteness {
        let receivers = Set(paths.map(\.receiver))
        return RoomModelCompleteness(
            pointCount: points.count, pathCount: paths.count,
            unpositionedPointIDs: points.filter { $0.position == nil }.map(\.id),
            stalePathIDs: paths.filter { RoomModelRule.state(of: $0, in: context) != .measured }.map(\.id),
            poorQualityPathIDs: paths.filter { !$0.qualityOK }.map(\.id),
            magnitudeOnlyPathIDs: paths.filter { !$0.timingTier.carriesPhase }.map(\.id),
            seatsWithoutPathIDs: points.filter { $0.kind == .seat && !receivers.contains($0.id) }.map(\.id))
    }
}

enum RoomModelID {
    /// A stable UUID derived from a namespace and a key, so the same record always maps to the same point or path.
    static func stable(_ namespace: String, _ key: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("n60.roommodel.\(namespace)|\(key)".utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
