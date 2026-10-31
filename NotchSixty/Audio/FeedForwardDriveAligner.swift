import Foundation

/// E4 S22b2: least-squares fit of host time (seconds) against a frame counter over a sliding
/// window. Control plane only.
struct FeedForwardClockFit: Equatable, Sendable {
    static let windowSeconds = 10.0
    static let minimumPoints = 8
    static let minimumSpanSeconds = 2.0

    private var indices: [Double] = []
    private var seconds: [Double] = []

    var count: Int { indices.count }

    mutating func add(index: Double, seconds time: Double) {
        guard index.isFinite, time.isFinite else { return }
        if let last = seconds.last, time <= last { return }
        indices.append(index)
        seconds.append(time)
        let cutoff = time - Self.windowSeconds
        if let first = seconds.firstIndex(where: { $0 >= cutoff }), first > 0 {
            indices.removeFirst(first)
            seconds.removeFirst(first)
        }
    }

    mutating func reset() {
        indices.removeAll(keepingCapacity: true)
        seconds.removeAll(keepingCapacity: true)
    }

    struct Line: Equatable, Sendable {
        var baseIndex: Double
        var baseSeconds: Double
        /// Host seconds per frame.
        var slope: Double
        var maximumResidualSeconds: Double

        func seconds(at index: Double) -> Double { baseSeconds + slope * (index - baseIndex) }
        func index(at seconds: Double) -> Double { baseIndex + (seconds - baseSeconds) / slope }
    }

    /// nil until enough points span enough time.
    func line() -> Line? {
        guard count >= Self.minimumPoints, let i0 = indices.first, let t0 = seconds.first,
              let tLast = seconds.last, tLast - t0 >= Self.minimumSpanSeconds
        else { return nil }
        let n = Double(count)
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for k in 0..<count {
            let x = indices[k] - i0, y = seconds[k] - t0
            sx += x; sy += y; sxx += x * x; sxy += x * y
        }
        let denominator = n * sxx - sx * sx
        guard denominator > 0 else { return nil }
        let slope = (n * sxy - sx * sy) / denominator
        let intercept = (sy - slope * sx) / n
        guard slope > 0, slope.isFinite else { return nil }
        var worst = 0.0
        for k in 0..<count {
            worst = max(worst, abs(seconds[k] - t0 - (intercept + slope * (indices[k] - i0))))
        }
        return Line(baseIndex: i0, baseSeconds: t0 + intercept, slope: slope, maximumResidualSeconds: worst)
    }
}

/// Maps the microphone's frame counter onto the speaker-drive frame counter through host time.
struct FeedForwardDriveAligner: Equatable, Sendable {
    static let maximumDriftPPM = 100.0
    static let maximumResidualSeconds = 0.0005

    enum Result: Equatable, Sendable {
        case aligning
        case stopped(String)
        /// `driveFrame` coincides with microphone frame `micFrame`.
        case aligned(driveFrame: Double, ratio: Double, driftPPM: Double)
    }

    var micRate: Double
    var driveRate: Double
    private(set) var mic = FeedForwardClockFit()
    private(set) var drive = FeedForwardClockFit()

    init(micRate: Double, driveRate: Double) {
        self.micRate = micRate
        self.driveRate = driveRate
    }

    mutating func addMic(frame: UInt64, hostSeconds: Double) { mic.add(index: Double(frame), seconds: hostSeconds) }
    mutating func addDrive(frame: UInt64, hostSeconds: Double) { drive.add(index: Double(frame), seconds: hostSeconds) }

    /// A gap in either stream: the old fit no longer describes it.
    mutating func resetDrive() { drive.reset() }
    mutating func resetAll() { mic.reset(); drive.reset() }

    func evaluate(micFrame: UInt64) -> Result {
        guard let m = mic.line(), let d = drive.line() else { return .aligning }
        let residual = max(m.maximumResidualSeconds, d.maximumResidualSeconds)
        guard residual <= Self.maximumResidualSeconds else {
            return .stopped(String(format: "clock fit residual %.2f ms over 0.5 ms", residual * 1000))
        }
        // Relative rate error of the two clocks against their nominal rates.
        let measuredRatio = d.slope == 0 ? 0 : (1 / d.slope) / (1 / m.slope)
        let nominalRatio = driveRate / micRate
        let drift = (measuredRatio / nominalRatio - 1) * 1.0e6
        guard abs(drift) <= Self.maximumDriftPPM else {
            return .stopped(String(format: "clock drift %.0f ppm over %.0f ppm", drift, Self.maximumDriftPPM))
        }
        let time = m.seconds(at: Double(micFrame))
        return .aligned(driveFrame: d.index(at: time), ratio: m.slope / d.slope, driftPPM: drift)
    }
}

/// What the render bridge's speaker-drive rings held at one read (E4 S22b1 rings).
struct FeedForwardDriveChunk: Sendable {
    var anchors: [N60SpeakerDriveAnchor]
    var left: [Float]
    var right: [Float]
    /// Absolute index of the first frame in `left`.
    var firstFrame: UInt64
    var droppedFrames: UInt64
    var droppedAnchors: UInt64
}

/// Where the shadow reads the speaker drive. Main actor only: the control plane is the rings'
/// only consumer.
@MainActor
protocol FeedForwardDriveSource: AnyObject {
    /// The output's rate, nil when the transport has no drive tap.
    var driveSampleRate: Double? { get }
    /// Bass management or a speaker-bus split is active: the sweep cannot describe the programme.
    var subwooferActive: Bool { get }
    func setDriveDemand(_ requested: Bool)
    func readDrive(maximumFrames: Int) -> FeedForwardDriveChunk?
}

@MainActor
extension AudioIOEngine: FeedForwardDriveSource {
    var driveSampleRate: Double? { ambientPlaybackReferenceSampleRate }
    var subwooferActive: Bool { bassManagementConfiguration.enabled }

    func setDriveDemand(_ requested: Bool) { setSpeakerDriveDemand(requested) }

    func readDrive(maximumFrames: Int) -> FeedForwardDriveChunk? {
        guard let before = speakerDriveSnapshot(), before.enabled else { return nil }
        let first = before.capturedFrames &- UInt64(before.availableFrames)
        let anchors = readSpeakerDriveAnchors()
        let frames = readSpeakerDriveFrames(maximumFrames: maximumFrames)
        return FeedForwardDriveChunk(
            anchors: anchors, left: frames.map(\.left), right: frames.map(\.right), firstFrame: first,
            droppedFrames: before.droppedFrames, droppedAnchors: before.droppedAnchors
        )
    }
}
