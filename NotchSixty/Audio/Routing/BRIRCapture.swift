import Accelerate
import Foundation

// E13 S6 (design note 11): personal BRIR capture, control plane only.
//
// One sweep per speaker and head yaw is played while two in-ear microphones (left and right ear
// of one interface, so one clock) record. Each pass goes through the E11 multi-microphone runner,
// is deconvolved (Farina 2000), trimmed to a common onset so the interaural delay survives,
// windowed, optionally convolved with a headphone compensation inverse (Kirkeby and Nelson 1999
// style regularisation: smoothed magnitude, bounded boost, minimum phase) and stored as a
// schema-2 `BinauralProfileAsset` whose measurements carry `channelRole` and `headYawDegrees`.
//
// Realtime impact: none. Everything here allocates and runs on a task, never in an audio
// callback. Rates: all device rates to 384 kHz; every length is derived from the sample rate.

enum BRIRCaptureError: Error, Equatable, LocalizedError {
    case invalidPlan
    case responseTooShort
    case silentResponse
    case incompleteCapture
    case compensationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPlan:
            "The capture needs both ear microphones on one interface and at least one speaker."
        case .responseTooShort: "The recording is too short for the requested impulse response length."
        case .silentResponse: "An ear microphone recorded no usable response."
        case .incompleteCapture: "The capture does not cover every speaker and head position."
        case .compensationFailed: "The headphone compensation could not be designed from the reseat measurements."
        }
    }
}

/// How many head yaws are captured per speaker.
enum BRIRHeadPositions: Int, Equatable, Sendable, CaseIterable {
    case one = 1
    case three = 3
    case five = 5

    /// Degrees relative to facing the speaker layout, same sign convention as `N60HeadPose.yawDegrees`.
    var yawDegrees: [Double] {
        switch self {
        case .one: [0]
        case .three: [-30, 0, 30]
        case .five: [-60, -30, 0, 30, 60]
        }
    }
}

/// Head pitches captured per speaker and yaw (E13 S8, G16). Tilting the head gives role-tagged assets elevation sets,
/// so head tracking can interpolate pitch from them instead of holding the level capture.
enum BRIRHeadTilt: Int, Equatable, Sendable, CaseIterable {
    case level = 1
    case threePitches = 3

    /// Degrees, positive looking up, same sign convention as `N60HeadPose.pitchDegrees`.
    var pitchDegrees: [Double] {
        switch self {
        case .level: [0]
        case .threePitches: [-30, 0, 30]
        }
    }
}

struct BRIRCaptureStep: Equatable, Sendable {
    var role: OutputProgramRole
    var headYawDegrees: Double
    var headPitchDegrees: Double = 0
}

struct BRIRCapturePlan: Equatable, Sendable {
    /// Headphone compensation: reseats of the headphone averaged (design note 11).
    static let compensationReseatCount = 5
    /// Pre-onset margin kept in every BRIR.
    static let preRollSeconds = 0.001

    var speakers: [OutputProgramRole]
    var headPositions: BRIRHeadPositions = .three
    var headTilt: BRIRHeadTilt = .level
    var sampleRate: Double
    var tapCount: Int
    var leftEar: MeasurementSeat
    var rightEar: MeasurementSeat

    func validate() throws {
        var seat = MeasurementSeatPlan()
        guard sampleRate.isFinite, sampleRate > 0,
              tapCount > 0, tapCount <= BinauralProfileAsset.maxTapCount(sampleRate: sampleRate),
              !speakers.isEmpty,
              Set(speakers).count == speakers.count,
              !speakers.contains(.lowFrequencyEffects),
              (try? seat.add(leftEar)) != nil, (try? seat.add(rightEar)) != nil,
              seat.mode == .sharedClock else { throw BRIRCaptureError.invalidPlan }
    }

    /// Pitch, then yaw, are the outer loops: the listener moves their head once per position, not once per speaker.
    var steps: [BRIRCaptureStep] {
        headTilt.pitchDegrees.flatMap { pitch in
            headPositions.yawDegrees.flatMap { yaw in
                speakers.map { BRIRCaptureStep(role: $0, headYawDegrees: yaw, headPitchDegrees: pitch) }
            }
        }
    }

    /// Left ear is seat 0, right ear is seat 1.
    func earPlan() throws -> MeasurementSeatPlan {
        try validate()
        return try MeasurementSeatPlan(seats: [leftEar, rightEar])
    }

    var preRollFrames: Int { Int((Self.preRollSeconds * sampleRate).rounded()) }
}

/// One captured speaker at one head yaw: left and right ear impulse responses, `tapCount` long.
struct BRIRCaptureResult: Equatable, Sendable {
    var role: OutputProgramRole
    var headYawDegrees: Double
    var headPitchDegrees: Double = 0
    var leftIR: [Float]
    var rightIR: [Float]
}

enum BRIRCaptureProcessor {
    /// Turns the two ear records of one pass into trimmed, windowed responses. The common onset is
    /// the earlier ear's direct arrival minus the pre-roll, so the interaural delay is kept.
    static func process(
        records: [MultiMicSeatRecord], tapCount: Int, sampleRate: Double
    ) throws -> (left: [Float], right: [Float]) {
        guard records.count == 2, tapCount > 0, sampleRate > 0 else { throw BRIRCaptureError.invalidPlan }
        let preRoll = Int((BRIRCapturePlan.preRollSeconds * sampleRate).rounded())
        let onset = min(records[0].directArrivalFrames, records[1].directArrivalFrames)
        let start = max(0, Int(onset.rounded()) - preRoll)
        func extract(_ record: MultiMicSeatRecord) throws -> [Float] {
            let response = record.impulseResponse
            // The second half of the circular result holds negative time (harmonic distortion).
            guard start + tapCount <= response.count / 2 else { throw BRIRCaptureError.responseTooShort }
            let taps = Array(response[start..<(start + tapCount)])
            guard taps.contains(where: { $0 != 0 }), taps.allSatisfy(\.isFinite) else {
                throw BRIRCaptureError.silentResponse
            }
            return taps
        }
        var left = try extract(records[0])
        var right = try extract(records[1])
        applyWindow(&left, preRollFrames: preRoll)
        applyWindow(&right, preRollFrames: preRoll)
        return (left, right)
    }

    /// Half-Hann fade-in over half the pre-roll and fade-out over the last quarter.
    static func applyWindow(_ taps: inout [Float], preRollFrames: Int) {
        let n = taps.count
        let fadeIn = min(preRollFrames / 2, n / 4)
        for i in 0..<fadeIn {
            taps[i] *= Float(0.5 - 0.5 * cos(Double.pi * (Double(i) + 0.5) / Double(fadeIn)))
        }
        let fadeOut = n / 4
        guard fadeOut > 0 else { return }
        for i in 0..<fadeOut {
            let w = 0.5 + 0.5 * cos(Double.pi * (Double(i) + 0.5) / Double(fadeOut))
            taps[n - fadeOut + i] *= Float(w)
        }
    }

    /// Runs one pass (a speaker at a head yaw, or one headphone reseat) through the E11 runner
    /// and returns the trimmed ear responses. The runner cancels the transport on failure.
    static func capture(
        plan: BRIRCapturePlan,
        pass: MultiMicPass,
        tapCount: Int? = nil,
        timeoutSeconds: Double,
        makeTransport: MultiMicTransportFactory
    ) async throws -> (left: [Float], right: [Float]) {
        let seats = try plan.earPlan()
        let records = try await MultiMicMeasurementRunner.run(
            plan: seats, pass: pass, sampleRate: plan.sampleRate,
            timeoutSeconds: timeoutSeconds, makeTransport: makeTransport
        )
        return try process(records: records, tapCount: tapCount ?? plan.tapCount, sampleRate: plan.sampleRate)
    }
}

/// Minimum-phase inverse of the headphone-to-ear response, per ear (design note 11).
struct BRIRHeadphoneCompensation: Equatable, Sendable {
    static let maximumBoostDB = 12.0
    static let maximumCutDB = 24.0

    var left: [Float]
    var right: [Float]

    /// `leftReseats` and `rightReseats` are ear responses to a sweep played through the headphone,
    /// one per reseat. Power is averaged over reseats, smoothed to 1/6 octave, inverted about the
    /// 200 Hz-2 kHz level and limited to +12 / -24 dB; the correction fades to 0 dB outside the
    /// band so the inverse stays well behaved at the extremes.
    static func design(
        leftReseats: [[Float]], rightReseats: [[Float]], sampleRate: Double
    ) throws -> BRIRHeadphoneCompensation {
        guard !leftReseats.isEmpty, leftReseats.count == rightReseats.count, sampleRate > 0 else {
            throw BRIRCaptureError.compensationFailed
        }
        let tapCount = min(Int(N60_BINAURAL_MAX_TAPS) * 4, max(256, 1 << Int(ceil(log2(0.1 * sampleRate)))))
        return BRIRHeadphoneCompensation(
            left: try inverse(reseats: leftReseats, sampleRate: sampleRate, tapCount: tapCount),
            right: try inverse(reseats: rightReseats, sampleRate: sampleRate, tapCount: tapCount)
        )
    }

    private static func inverse(reseats: [[Float]], sampleRate: Double, tapCount: Int) throws -> [Float] {
        let longest = reseats.map(\.count).max() ?? 0
        guard longest > 0 else { throw BRIRCaptureError.compensationFailed }
        let size = 1 << Int(ceil(log2(Double(max(longest, Int(sampleRate / 2))))))
        var power = [Double](repeating: 0, count: size / 2)
        for response in reseats {
            guard response.contains(where: { $0 != 0 }) else { throw BRIRCaptureError.compensationFailed }
            let spectrum = try powerSpectrum(response, size: size)
            for k in 1..<(size / 2) { power[k] += spectrum[k] / Double(reseats.count) }
        }
        let binHz = sampleRate / Double(size)
        let highEdge = min(20_000, 0.45 * sampleRate)
        let highFull = min(14_000, 0.4 * sampleRate)
        var frequencies = [Double]()
        var f = 20.0
        while f <= highEdge { frequencies.append(f); f *= pow(2, 1.0 / 12.0) }
        let halfWidth = pow(2, 1.0 / 12.0)
        let levels: [Double] = frequencies.map { centre in
            let lo = max(1, Int((centre / halfWidth / binHz).rounded(.up)))
            let hi = min(size / 2 - 1, Int((centre * halfWidth / binHz).rounded(.down)))
            guard lo <= hi else { return -300 }
            var sum = 0.0
            for k in lo...hi { sum += power[k] }
            return 10 * log10(max(sum / Double(hi - lo + 1), 1e-30))
        }
        let referenceBand = zip(frequencies, levels).filter { $0.0 >= 200 && $0.0 <= 2_000 }.map(\.1)
        guard !referenceBand.isEmpty, referenceBand.allSatisfy({ $0 > -250 }) else {
            throw BRIRCaptureError.compensationFailed
        }
        let reference = referenceBand.reduce(0, +) / Double(referenceBand.count)
        func fade(_ x: Double) -> Double { 0.5 - 0.5 * cos(Double.pi * min(max(x, 0), 1)) }
        let gains: [Double] = zip(frequencies, levels).map { frequency, level in
            let raw = min(max(reference - level, -maximumCutDB), maximumBoostDB)
            let low = fade(log2(frequency / 20))                      // 0 dB at 20 Hz, full from 40 Hz
            let high = fade(log2(highEdge / frequency) / log2(highEdge / highFull))
            return raw * low * high
        }
        do {
            return try RoomCorrectionCore.minimumPhaseTaps(
                sampleRate: sampleRate, tapCount: tapCount,
                frequenciesHz: frequencies, gainDB: gains,
                lowHz: frequencies[0] * 0.5, highHz: min(highEdge * 1.1, 0.495 * sampleRate)
            )
        } catch {
            throw BRIRCaptureError.compensationFailed
        }
    }

    private static func powerSpectrum(_ x: [Float], size n: Int) throws -> [Double] {
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw BRIRCaptureError.compensationFailed
        }
        defer { vDSP_destroy_fftsetup(setup) }
        var padded = [Float](repeating: 0, count: n)
        for i in 0..<min(n, x.count) { padded[i] = x[i] }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                padded.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        return (0..<(n / 2)).map { Double(real[$0]) * Double(real[$0]) + Double(imag[$0]) * Double(imag[$0]) }
    }

    /// First `count` samples of `signal` convolved with `filter`.
    static func convolve(_ signal: [Float], with filter: [Float], count: Int) -> [Float] {
        guard !filter.isEmpty, count > 0 else { return Array(signal.prefix(count)) }
        var padded = [Float](repeating: 0, count: filter.count - 1)
        padded.append(contentsOf: signal.prefix(count))
        if padded.count < count + filter.count - 1 {
            padded.append(contentsOf: [Float](repeating: 0, count: count + filter.count - 1 - padded.count))
        }
        let reversed = Array(filter.reversed())
        var result = [Float](repeating: 0, count: count)
        vDSP_conv(padded, 1, reversed, 1, &result, 1, vDSP_Length(count), vDSP_Length(filter.count))
        return result
    }
}

enum BRIRCaptureAssembler {
    /// Nominal speaker direction for display and for HRTF fall-back tools; BRIR selection uses the role.
    static func nominalPosition(of role: OutputProgramRole) -> (azimuth: Double, elevation: Double) {
        switch role {
        case .frontLeft: (-30, 0)
        case .frontRight: (30, 0)
        case .frontCenter, .lowFrequencyEffects: (0, 0)
        case .sideLeft: (-90, 0)
        case .sideRight: (90, 0)
        case .rearLeft: (-135, 0)
        case .rearRight: (135, 0)
        case .wideLeft: (-60, 0)
        case .wideRight: (60, 0)
        case .topFrontLeft: (-30, 35)
        case .topFrontRight: (30, 35)
        case .topMiddleLeft: (-90, 45)
        case .topMiddleRight: (90, 45)
        case .topRearLeft: (-135, 35)
        case .topRearRight: (135, 35)
        }
    }

    /// Builds the schema-2 asset. Fails (no partial asset) unless `results` covers every step of
    /// the plan exactly once. The set is scaled by one common gain so the loudest ear has unit
    /// energy, which keeps the speakers' relative levels and the interaural level difference.
    static func makeAsset(
        displayName: String,
        plan: BRIRCapturePlan,
        results: [BRIRCaptureResult],
        compensation: BRIRHeadphoneCompensation? = nil
    ) throws -> BinauralProfileAsset {
        try plan.validate()
        let expected = Set(plan.steps.map { "\($0.role.rawValue)@\($0.headYawDegrees)/\($0.headPitchDegrees)" })
        let got = results.map { "\($0.role.rawValue)@\($0.headYawDegrees)/\($0.headPitchDegrees)" }
        guard got.count == expected.count, Set(got) == expected else { throw BRIRCaptureError.incompleteCapture }

        var compensated = results
        if let compensation {
            for i in compensated.indices {
                guard compensated[i].leftIR.count == plan.tapCount, compensated[i].rightIR.count == plan.tapCount else {
                    throw BRIRCaptureError.incompleteCapture
                }
                compensated[i].leftIR = BRIRHeadphoneCompensation.convolve(
                    compensated[i].leftIR, with: compensation.left, count: plan.tapCount)
                compensated[i].rightIR = BRIRHeadphoneCompensation.convolve(
                    compensated[i].rightIR, with: compensation.right, count: plan.tapCount)
                // The inverse can ring past the BRIR length: fade the end again.
                BRIRCaptureProcessor.applyWindow(&compensated[i].leftIR, preRollFrames: 0)
                BRIRCaptureProcessor.applyWindow(&compensated[i].rightIR, preRollFrames: 0)
            }
        }
        func energy(_ x: [Float]) -> Double { sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) }) }
        let loudest = compensated.map { max(energy($0.leftIR), energy($0.rightIR)) }.max() ?? 0
        guard loudest > 0, loudest.isFinite else { throw BRIRCaptureError.silentResponse }
        let gain = Float(1.0 / loudest)

        let measurements = compensated.map { result -> BinauralMeasurement in
            let position = nominalPosition(of: result.role)
            return BinauralMeasurement(
                azimuthDegrees: position.azimuth,
                elevationDegrees: position.elevation,
                distanceMeters: 1,
                leftIR: result.leftIR.map { $0 * gain },
                rightIR: result.rightIR.map { $0 * gain },
                channelRole: result.role,
                headYawDegrees: result.headYawDegrees,
                headPitchDegrees: plan.headTilt == .level ? nil : result.headPitchDegrees
            )
        }
        let asset = BinauralProfileAsset(
            displayName: displayName,
            originalSourceName: nil,
            sampleRate: plan.sampleRate,
            tapCount: plan.tapCount,
            kind: .brir,
            measurements: measurements
        )
        try asset.validate()
        return asset
    }
}
