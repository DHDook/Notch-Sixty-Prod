import Foundation

/// A one-channel timestamped capture (E4 S23): the reference or the seat monitor on its own device.
protocol QuietZoneFeedForwardSingleCapturing: AnyObject {
    var sampleRate: Double { get }
    func start() throws
    func readFrames(maximumFrames: Int) throws -> [N60FeedForwardReferenceFrame]
    func close()
}

extension FeedForwardReferenceTransport: QuietZoneFeedForwardSingleCapturing {
    func readFrames(maximumFrames: Int) throws -> [N60FeedForwardReferenceFrame] {
        try read(maximumFrames: maximumFrames)
    }
}

enum CrossDeviceCaptureError: Error, LocalizedError, Equatable {
    case clockRefused(String)
    case monitorGap

    var errorDescription: String? {
        switch self {
        case .clockRefused(let reason): return "The two microphones' clocks cannot be joined: \(reason)."
        case .monitorGap: return "The seat monitor lost samples; measure again."
        }
    }
}

/// E4 S23: joins a reference microphone and a seat monitor on two devices into the pair the survey and
/// the shadow already consume. The monitor is resampled onto the reference clock and rate by 4-point
/// Lagrange interpolation (only content up to a few hundred Hz matters), using straight-line fits of host
/// time against each device's frame counter. The pair is refused when the relative drift exceeds 100 ppm
/// or either fit's residual exceeds 0.5 ms (the clock-monitor limits). Control plane only: one queue.
final class CrossDevicePairCapture: QuietZoneFeedForwardPairCapturing {
    static let maximumDriftPPM = FeedForwardDriveAligner.maximumDriftPPM
    static let maximumResidualSeconds = FeedForwardDriveAligner.maximumResidualSeconds

    /// Samples kept behind the next sound, so a refit that moves the mapping a little never reaches a dropped one.
    private static let trimMargin: Int64 = 16

    let sampleRate: Double
    private let reference: QuietZoneFeedForwardSingleCapturing
    private let monitor: QuietZoneFeedForwardSingleCapturing
    private let hostSeconds: (UInt64) -> Double
    /// Seconds the monitor's host timestamps trail the reference's for the same sound
    /// (monitor input latency minus reference input latency).
    private let monitorLeadSeconds: Double
    private var referenceFit = FeedForwardClockFit()
    private var monitorFit = FeedForwardClockFit()
    private var pending: [N60FeedForwardReferenceFrame] = []
    private var pendingHead = 0
    private var samples: [Float] = []
    private var baseIndex: Int64 = 0
    private var started = false
    private var monitorTrimmed = false

    /// - Parameters:
    ///   - referenceLatencySeconds / monitorLatencySeconds: each device's reported input latency plus safety offset.
    ///   - hostSeconds: converts a Core Audio host time to seconds.
    init(
        reference: QuietZoneFeedForwardSingleCapturing, monitor: QuietZoneFeedForwardSingleCapturing,
        referenceLatencySeconds: Double = 0, monitorLatencySeconds: Double = 0,
        hostSeconds: @escaping (UInt64) -> Double = CrossDevicePairCapture.machSeconds
    ) {
        self.reference = reference
        self.monitor = monitor
        self.hostSeconds = hostSeconds
        sampleRate = reference.sampleRate
        // Sound heard at acoustic time a was stamped a + latency; so stamp_m = stamp_r - lr + lm.
        monitorLeadSeconds = monitorLatencySeconds - referenceLatencySeconds
    }

    static func machSeconds(_ hostTime: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(hostTime) * Double(info.numer) / Double(info.denom) * 1.0e-9
    }

    func start() throws {
        guard !started else { return }
        try reference.start()
        try monitor.start()
        started = true
    }

    func close() {
        reference.close()
        monitor.close()
    }

    func readPair(maximumFrames: Int) throws -> (reference: [N60FeedForwardReferenceFrame], error: [Float]) {
        let newReference = try reference.readFrames(maximumFrames: maximumFrames)
        let newMonitor = try monitor.readFrames(maximumFrames: maximumFrames)
        for frame in newReference where frame.frameOffset == 0 {
            referenceFit.add(index: frame.firstFrameSampleTime, seconds: hostSeconds(frame.firstFrameHostTime))
        }
        pending.append(contentsOf: newReference)
        try ingestMonitor(newMonitor)

        guard let refLine = referenceFit.line(), let monLine = monitorFit.line() else { return ([], []) }
        let residual = max(refLine.maximumResidualSeconds, monLine.maximumResidualSeconds)
        guard residual <= Self.maximumResidualSeconds else {
            throw CrossDeviceCaptureError.clockRefused(
                String(format: "clock fit residual %.2f ms over 0.5 ms", residual * 1000))
        }
        let relative = ((1 / monLine.slope) / monitor.sampleRate) / ((1 / refLine.slope) / reference.sampleRate)
        let driftPPM = (relative - 1) * 1.0e6
        guard abs(driftPPM) <= Self.maximumDriftPPM else {
            throw CrossDeviceCaptureError.clockRefused(
                String(format: "relative drift %.0f ppm over %.0f ppm", driftPPM, Self.maximumDriftPPM))
        }

        var outFrames: [N60FeedForwardReferenceFrame] = []
        var outError: [Float] = []
        let lastAvailable = baseIndex + Int64(samples.count) - 1
        while pendingHead < pending.count {
            let frame = pending[pendingHead]
            let index = frame.firstFrameSampleTime + Double(frame.frameOffset)
            let stamp = refLine.seconds(at: index) + monitorLeadSeconds
            let position = monLine.index(at: stamp)
            let j = Int64(position.rounded(.down))
            if j + 2 > lastAvailable { break }  // the monitor has not reached this sound yet
            if j - 1 < baseIndex {
                // Before the monitor started: no pair yet. After samples were dropped it is a real gap.
                if monitorTrimmed { throw CrossDeviceCaptureError.monitorGap }
                pendingHead += 1
                continue
            }
            outFrames.append(frame)
            outError.append(Self.lagrange(samples, base: baseIndex, j: j, mu: Float(position - Double(j))))
            pendingHead += 1
        }
        if pendingHead > 0 {
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
        if let next = pending.first {
            let stamp = refLine.seconds(at: next.firstFrameSampleTime + Double(next.frameOffset)) + monitorLeadSeconds
            trimMonitor(before: Int64(monLine.index(at: stamp).rounded(.down)) - Self.trimMargin)
        } else if let lastOut = outFrames.last {
            let stamp = refLine.seconds(at: lastOut.firstFrameSampleTime + Double(lastOut.frameOffset)) + monitorLeadSeconds
            trimMonitor(before: Int64(monLine.index(at: stamp).rounded(.down)) - Self.trimMargin)
        }
        return (outFrames, outError)
    }

    private func ingestMonitor(_ frames: [N60FeedForwardReferenceFrame]) throws {
        for frame in frames {
            let index = Int64((frame.firstFrameSampleTime + Double(frame.frameOffset)).rounded())
            if samples.isEmpty {
                baseIndex = index
            } else if index != baseIndex + Int64(samples.count) {
                throw CrossDeviceCaptureError.monitorGap
            }
            if frame.frameOffset == 0 {
                monitorFit.add(index: Double(index), seconds: hostSeconds(frame.firstFrameHostTime))
            }
            samples.append(frame.sample)
        }
    }

    private func trimMonitor(before index: Int64) {
        let drop = Int(min(max(index - baseIndex, 0), Int64(samples.count)))
        if drop > 0 {
            monitorTrimmed = true
            samples.removeFirst(drop)
            baseIndex += Int64(drop)
        }
    }

    /// 4-point Lagrange through samples j-1...j+2 at fraction mu in [0, 1).
    static func lagrange(_ x: [Float], base: Int64, j: Int64, mu: Float) -> Float {
        let k = Int(j - base)
        let y0 = x[k - 1], y1 = x[k], y2 = x[k + 1], y3 = x[k + 2]
        let c0 = -mu * (mu - 1) * (mu - 2) / 6
        let c1 = (mu + 1) * (mu - 1) * (mu - 2) / 2
        let c2 = -(mu + 1) * mu * (mu - 2) / 2
        let c3 = (mu + 1) * mu * (mu - 1) / 6
        return c0 * y0 + c1 * y1 + c2 * y2 + c3 * y3
    }
}
