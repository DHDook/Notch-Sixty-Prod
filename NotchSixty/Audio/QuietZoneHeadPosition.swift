import Foundation

/// E4 S26b: head position selects and interpolates the surveyed virtual-microphone ratios (S26a).
///
/// Pure value maths, offline and not wired to any output: nothing here arms or drives anti-noise.
/// Positions are metres in the room frame set at setup (origin at the monitor microphone). The
/// camera supplies a head position in its own frame; `QuietZoneCameraPlacement` maps it to the room.
/// Interpolation: inverse-distance-squared weights over the nearest surveyed points inside a trust
/// radius, applied to the complex ratio and the two secondary paths. Outside the radius, or with a
/// stale or low-confidence pose, the tracker reports nothing and the caller keeps the fixed seat.
/// Realtime: not used on an audio thread. Sample rate: none, the maths is per tone.
struct QuietZoneHeadPose: Equatable, Sendable {
    /// Room frame, metres.
    var x: Double
    var y: Double
    var z: Double
    /// 0...1 from the pose estimator.
    var confidence: Double
    /// Seconds on any monotonic clock.
    var time: Double

    func distance(to other: QuietZoneHeadPose) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y) + (z - other.z) * (z - other.z)).squareRoot()
    }
}

/// Where the camera sits in the room frame: a position and a yaw about the vertical (z) axis.
struct QuietZoneCameraPlacement: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double
    var yawRadians: Double

    /// Camera frame (x right, y up, z toward the viewer, as Vision's camera-relative joints) to the
    /// room frame: the camera looks along its own -z, which points along the room direction `yaw`.
    func roomPosition(cameraX: Double, cameraY: Double, cameraZ: Double, confidence: Double, time: Double) -> QuietZoneHeadPose {
        let forward = -cameraZ
        let c = cos(yawRadians), s = sin(yawRadians)
        // Room forward axis (cos yaw, sin yaw); room left axis (-sin yaw, cos yaw); camera right = -left.
        let rx = x + forward * c + (-cameraX) * (-s)
        let ry = y + forward * s + (-cameraX) * c
        return QuietZoneHeadPose(x: rx, y: ry, z: z + cameraY, confidence: confidence, time: time)
    }
}

struct QuietZoneSurveyedPosition: Sendable {
    var x: Double
    var y: Double
    var z: Double
    var microphone: QuietZoneVirtualMicrophone
}

enum QuietZoneHeadSurveyError: Error, Equatable {
    case empty
    case mismatchedTones
}

struct QuietZoneHeadSurvey: Sendable {
    /// Beyond this distance from every surveyed point the ratios are not trusted.
    static let trustRadiusMetres = 0.5
    static let neighbourCount = 3

    let points: [QuietZoneSurveyedPosition]

    init(points: [QuietZoneSurveyedPosition]) throws {
        guard let first = points.first else { throw QuietZoneHeadSurveyError.empty }
        let freqs = first.microphone.tones.map(\.frequencyHz)
        for p in points {
            let f = p.microphone.tones.map(\.frequencyHz)
            guard f.count == freqs.count, zip(f, freqs).allSatisfy({ abs($0 - $1) < 0.01 }) else {
                throw QuietZoneHeadSurveyError.mismatchedTones
            }
        }
        self.points = points
    }

    /// Interpolation weights (summing to 1) over the surveyed points near `pose`, or nil when no point is within
    /// the trust radius. A pose on a surveyed point returns that point alone.
    static func weights(positions: [(x: Double, y: Double, z: Double)], at pose: QuietZoneHeadPose) -> [(index: Int, weight: Double)]? {
        let ranked = positions.enumerated().map { (i, p) -> (Int, Double) in
            let dx = p.x - pose.x, dy = p.y - pose.y, dz = p.z - pose.z
            return (i, (dx * dx + dy * dy + dz * dz).squareRoot())
        }.sorted { $0.1 < $1.1 }
        guard let nearest = ranked.first, nearest.1 <= trustRadiusMetres else { return nil }
        if nearest.1 < 1.0e-6 { return [(nearest.0, 1)] }
        let used = ranked.prefix(neighbourCount).filter { $0.1 <= trustRadiusMetres }
        let raw = used.map { 1 / ($0.1 * $0.1) }
        let total = raw.reduce(0, +)
        return zip(used, raw).map { ($0.0, $1 / total) }
    }

    /// The virtual microphone for a head at `pose`, or nil when no surveyed point is within the trust radius.
    func microphone(at pose: QuietZoneHeadPose) -> QuietZoneVirtualMicrophone? {
        guard let blend = Self.weights(positions: points.map { ($0.x, $0.y, $0.z) }, at: pose),
              let first = blend.first else { return nil }
        if blend.count == 1 { return points[first.index].microphone }
        let nearest = points[first.index]
        let used = blend.map { (points[$0.index], $0.weight) }
        let weights = blend.map(\.weight)
        var tones: [QuietZoneVirtualMicTone] = []
        for t in nearest.microphone.tones.indices {
            var ratio = ActiveQuietZoneComplex.zero
            var eff = ActiveQuietZoneComplex.zero
            var ear = ActiveQuietZoneComplex.zero
            for (k, entry) in used.enumerated() {
                let w = weights[k]
                let tone = entry.0.microphone.tones[t]
                ratio = ratio + tone.ratio * w
                eff = eff + tone.effectiveSecondary * w
                ear = ear + tone.earSecondary * w
            }
            tones.append(QuietZoneVirtualMicTone(
                frequencyHz: nearest.microphone.tones[t].frequencyHz,
                ratio: ratio, effectiveSecondary: eff, earSecondary: ear))
        }
        return QuietZoneVirtualMicrophone(tones: tones)
    }
}

/// Smooths camera poses and rejects bad ones. A jump larger than `maximumJumpMetres` is accepted only
/// after `jumpConfirmations` consecutive frames agree, so a single mis-detection cannot move the zone.
struct QuietZoneHeadTracker: Sendable {
    static let minimumConfidence = 0.5
    static let staleSeconds = 1.0
    static let smoothingSeconds = 0.3
    static let maximumJumpMetres = 0.4
    static let jumpConfirmations = 3

    private(set) var smoothed: QuietZoneHeadPose?
    private var candidate: QuietZoneHeadPose?
    private var candidateCount = 0

    mutating func reset() {
        smoothed = nil
        candidate = nil
        candidateCount = 0
    }

    mutating func update(_ pose: QuietZoneHeadPose) {
        guard pose.confidence >= Self.minimumConfidence,
              pose.x.isFinite, pose.y.isFinite, pose.z.isFinite else { return }
        guard var current = smoothed else {
            smoothed = pose
            return
        }
        if pose.distance(to: current) > Self.maximumJumpMetres {
            if let cand = candidate, pose.distance(to: cand) <= Self.maximumJumpMetres {
                candidateCount += 1
            } else {
                candidateCount = 1
            }
            candidate = pose
            if candidateCount >= Self.jumpConfirmations {
                smoothed = pose
                candidate = nil
                candidateCount = 0
            }
            return
        }
        candidate = nil
        candidateCount = 0
        let dt = max(pose.time - current.time, 0)
        let a = 1 - exp(-dt / Self.smoothingSeconds)
        current.x += a * (pose.x - current.x)
        current.y += a * (pose.y - current.y)
        current.z += a * (pose.z - current.z)
        current.confidence = pose.confidence
        current.time = pose.time
        smoothed = current
    }

    /// The pose to use at `now`, or nil when none has arrived within the stale limit.
    func pose(at now: Double) -> QuietZoneHeadPose? {
        guard let p = smoothed, now - p.time <= Self.staleSeconds else { return nil }
        return p
    }
}
