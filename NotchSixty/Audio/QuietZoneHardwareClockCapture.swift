import CoreAudio
import Foundation

/// A diagnostic capture cannot establish DAC, ADC or acoustic propagation
/// latency. PR97 stores only bounded callback timestamps, never microphone
/// audio, and cannot grant permission to arm feed-forward ANC.
enum QuietZoneHardwareClockCaptureError: Error, Equatable {
    case incompatibleRoute
    case invalidTimestamp
    case discontinuousClock
    case tooManyObservations
    case callbackFault
    case insufficientEvidence
    case alreadyFinished
}

/// Immutable route identifier for a single running transport. UIDs alone
/// are insufficient: every transport reinitialization issues a new lease.
struct QuietZoneHardwareClockRouteLease: Equatable, Sendable {
    let outputID: String
    let routeID: String
    let sampleRate: Double

    func permits(outputID: String, routeID: String, sampleRate: Double) -> Bool {
        self.outputID == outputID && !self.outputID.isEmpty &&
        self.routeID == routeID && !self.routeID.isEmpty &&
        self.sampleRate.isFinite && sampleRate.isFinite &&
        abs(self.sampleRate - sampleRate) < 0.5
    }
}

struct QuietZoneHardwareClockEvidence: Sendable {
    let trace: QuietZoneHALClockTrace
    let health: QuietZoneHALClockHealth
    let outputCallbackCount: UInt64
    let inputCallbackCount: UInt64
    let liveANCQualified: Bool = false
}

/// One owner, control-thread-only storage. A callback does NOT mutate this.
/// Input and output share host-time SECONDS converted from Core Audio host ticks.
/// This is sample-clock consistency, not ADC/DAC round-trip latency.
struct QuietZoneHardwareClockAccumulator: Sendable {
    static let maximumObservations = 4_096

    let microphoneID: String
    let outputID: String
    let sampleRate: Double
    private(set) var input: [QuietZoneHALClockObservation] = []
    private(set) var output: [QuietZoneHALClockObservation] = []

    init(microphoneID: String, outputID: String, sampleRate: Double) throws {
        guard !microphoneID.isEmpty, !outputID.isEmpty,
              sampleRate.isFinite, (8_000...192_000).contains(sampleRate)
        else { throw QuietZoneHardwareClockCaptureError.incompatibleRoute }
        self.microphoneID = microphoneID
        self.outputID = outputID
        self.sampleRate = sampleRate
    }

    mutating func addInput(hostSeconds: Double, sampleFrame: Double) throws {
        try Self.append(hostSeconds: hostSeconds, sampleFrame: sampleFrame, to: &input)
    }

    mutating func addOutput(hostSeconds: Double, sampleFrame: Double) throws {
        try Self.append(hostSeconds: hostSeconds, sampleFrame: sampleFrame, to: &output)
    }

    private static func append(
        hostSeconds: Double, sampleFrame: Double,
        to samples: inout [QuietZoneHALClockObservation]
    ) throws {
        guard hostSeconds.isFinite, sampleFrame.isFinite,
              hostSeconds > 0, sampleFrame >= 0
        else { throw QuietZoneHardwareClockCaptureError.invalidTimestamp }
        guard samples.count < maximumObservations else {
            throw QuietZoneHardwareClockCaptureError.tooManyObservations
        }
        if let previous = samples.last {
            guard hostSeconds > previous.hostTimeSeconds,
                  sampleFrame > previous.sampleFrame else {
                throw QuietZoneHardwareClockCaptureError.discontinuousClock
            }
        }
        samples.append(.init(hostTimeSeconds: hostSeconds, sampleFrame: sampleFrame))
    }

    func qualify() throws -> QuietZoneHardwareClockEvidence {
        let trace = QuietZoneHALClockTrace(
            inputDeviceID: microphoneID, outputDeviceID: outputID,
            nominalSampleRate: sampleRate,
            inputObservations: input, outputObservations: output
        )
        let health: QuietZoneHALClockHealth
        do { health = try QuietZoneHALClockAnalyzer().analyze(trace) }
        catch { throw QuietZoneHardwareClockCaptureError.insufficientEvidence }
        return QuietZoneHardwareClockEvidence(
            trace: trace, health: health,
            outputCallbackCount: 0, inputCallbackCount: 0
        )
    }
}

/// Bridges the existing PR96 input HAL ring and PASSIVE output witness.
/// It must be polled exclusively by one control-plane owner while the real
/// physical output callback is active; no simulated trigger or speaker output.
/// The route provider must return the CURRENT stable hardware identity.
@MainActor
final class QuietZoneHardwareHALClockAcquisition {
    typealias Route = (outputID: String, routeID: String, sampleRate: Double)

    private let reference: FeedForwardReferenceTransport
    private let routeLease: QuietZoneHardwareClockRouteLease
    private let currentRoute: () -> Route?
    private let outputWitness: () -> N60FeedForwardOutputTimingSnapshot?
    private var accumulator: QuietZoneHardwareClockAccumulator
    private var running = false
    private var finished = false
    private var lastOutputCallback: UInt64?
    private var lastInputCallbacks: UInt64 = 0
    private var lastOutputInvalid: UInt64 = 0
    private var lastOutputCallbacks: UInt64 = 0

    init(
        reference: FeedForwardReferenceTransport,
        microphoneID: String,
        outputID: String,
        routeID: String,
        sampleRate: Double,
        currentRoute: @escaping () -> Route?,
        outputWitness: @escaping () -> N60FeedForwardOutputTimingSnapshot?
    ) throws {
        guard abs(reference.sampleRate - sampleRate) < 0.5,
              !routeID.isEmpty else {
            throw QuietZoneHardwareClockCaptureError.incompatibleRoute
        }
        self.reference = reference
        routeLease = QuietZoneHardwareClockRouteLease(
            outputID: outputID, routeID: routeID, sampleRate: sampleRate
        )
        self.currentRoute = currentRoute
        self.outputWitness = outputWitness
        accumulator = try QuietZoneHardwareClockAccumulator(
            microphoneID: microphoneID, outputID: outputID,
            sampleRate: sampleRate
        )
    }

    private func verifyRoute() throws {
        guard let route = currentRoute(),
              routeLease.permits(
                outputID: route.outputID, routeID: route.routeID,
                sampleRate: route.sampleRate
              )
        else { throw QuietZoneHardwareClockCaptureError.incompatibleRoute }
    }

    func start() throws {
        guard !running, !finished else {
            throw QuietZoneHardwareClockCaptureError.alreadyFinished
        }
        try verifyRoute()
        // The existing reference transport alone owns microphone HAL start.
        // The production output is observed, never started or modified here.
        try reference.start()
        running = true
    }

    /// Poll frequently from the control plane; no 250 ms ambient-analysis hop.
    /// A ring overrun or invalid callback makes the entire trace unusable.
    func poll() throws {
        guard running, !finished else {
            throw QuietZoneHardwareClockCaptureError.alreadyFinished
        }
        do {
            try verifyRoute()
            guard let snapshot = reference.snapshot(),
                  snapshot.droppedFrames == 0,
                  snapshot.invalidTimestamps == 0,
                  snapshot.unsupportedBufferLayouts == 0
            else { throw QuietZoneHardwareClockCaptureError.callbackFault }

            let frames = try reference.read(maximumFrames: 4_096)
            for frame in frames where frame.frameOffset == 0 {
                try accumulator.addInput(
                    hostSeconds: Self.hostSeconds(frame.firstFrameHostTime),
                    sampleFrame: frame.firstFrameSampleTime
                )
            }
            lastInputCallbacks = snapshot.callbacks

            guard let output = outputWitness(), output.valid,
                  output.firstFrameHostTime > 0,
                  output.renderedFrames > 0,
                  output.invalidCount == 0,
                  output.callbackCount > 0,
                  output.firstFrameSampleTime.isFinite
            else { throw QuietZoneHardwareClockCaptureError.callbackFault }
            guard output.invalidCount == lastOutputInvalid else {
                throw QuietZoneHardwareClockCaptureError.callbackFault
            }
            if let last = lastOutputCallback {
                guard output.callbackCount >= last else {
                    throw QuietZoneHardwareClockCaptureError.discontinuousClock
                }
            }
            if lastOutputCallback != output.callbackCount {
                try accumulator.addOutput(
                    hostSeconds: Self.hostSeconds(output.firstFrameHostTime),
                    sampleFrame: output.firstFrameSampleTime
                )
                lastOutputCallback = output.callbackCount
                lastOutputCallbacks = output.callbackCount
            }
        } catch {
            reference.stop()
            running = false
            finished = true
            throw error
        }
    }

    func finish() throws -> QuietZoneHardwareClockEvidence {
        guard running, !finished else {
            throw QuietZoneHardwareClockCaptureError.alreadyFinished
        }
        defer {
            reference.stop()
            running = false
            finished = true
        }
        try poll()
        let base = try accumulator.qualify()
        return QuietZoneHardwareClockEvidence(
            trace: base.trace, health: base.health,
            outputCallbackCount: lastOutputCallbacks,
            inputCallbackCount: lastInputCallbacks
        )
    }

    func cancel() {
        if running { reference.stop() }
        running = false
        finished = true
    }

    private static func hostSeconds(_ ticks: UInt64) -> Double {
        // Both callbacks publish mach/Core Audio host ticks. Do not confuse
        // them with callback wall time or assume ticks are nanoseconds.
        Double(AudioConvertHostTimeToNanos(ticks)) * 1.0e-9
    }
}
