import Foundation

enum ActiveQuietZoneStatus: String, Codable, Equatable, Sendable {
    case observe
    case eligible
    case probing
    case cancelling
    case hold
    case fault

    var displayName: String {
        switch self {
        case .observe: return "Observe"
        case .eligible: return "Eligible"
        case .probing: return "Probing"
        case .cancelling: return "Cancelling"
        case .hold: return "Hold"
        case .fault: return "Fault"
        }
    }
}

enum ActiveQuietZoneHoldReason: String, Codable, Equatable, Sendable {
    case disabled
    case ambientEvidenceUnavailable
    case playbackSeparationUntrusted
    case noiseNotStationary
    case noEligibleTone
    case toneNotPersistent
    case acousticModelRequired
    case insufficientOutputHeadroom
    case verificationPending
    case protectionActive
    case unsupportedRoute
}

struct ActiveQuietZoneConfiguration: Codable, Equatable, Sendable {
    static let hardMaximumToneCount = 4
    static let hardMinimumFrequencyHz = 20.0
    static let hardMaximumFrequencyHz = 150.0

    var enabled = false
    var minimumFrequencyHz = 25.0
    var maximumFrequencyHz = 150.0
    var maximumToneCount = 4

    var minimumSeparationConfidence = 0.85
    var minimumStationarity = 0.80
    var minimumTonalProminenceDB = 12.0
    var requiredStableWindows = 4
    var stableFrequencyToleranceHz = 0.75

    var regularization = 0.02
    var probePeakDBFS = -42.0
    var maximumPerSourceTonePeakDBFS = -24.0
    var maximumAggregateSourcePeakDBFS = -18.0

    var minimumProbeImprovementDB = 1.0
    var maximumAllowedRegressionDB = 1.0
    var targetReductionDB = 6.0

    var armRampMilliseconds = 500.0
    var faultFadeMilliseconds = 100.0

    func validated() throws -> ActiveQuietZoneConfiguration {
        guard minimumFrequencyHz.isFinite,
              maximumFrequencyHz.isFinite,
              minimumFrequencyHz
                >= Self.hardMinimumFrequencyHz,
              maximumFrequencyHz
                <= Self.hardMaximumFrequencyHz,
              maximumFrequencyHz > minimumFrequencyHz,
              maximumToneCount > 0,
              maximumToneCount <= Self.hardMaximumToneCount,
              minimumSeparationConfidence.isFinite,
              (0.5...0.99).contains(
                minimumSeparationConfidence
              ),
              minimumStationarity.isFinite,
              (0.5...0.99).contains(minimumStationarity),
              minimumTonalProminenceDB.isFinite,
              (6.0...40.0).contains(
                minimumTonalProminenceDB
              ),
              requiredStableWindows >= 2,
              requiredStableWindows <= 12,
              stableFrequencyToleranceHz.isFinite,
              stableFrequencyToleranceHz > 0,
              stableFrequencyToleranceHz <= 3,
              regularization.isFinite,
              regularization > 0,
              regularization <= 1,
              probePeakDBFS.isFinite,
              probePeakDBFS <= -30,
              probePeakDBFS >= -72,
              maximumPerSourceTonePeakDBFS.isFinite,
              maximumPerSourceTonePeakDBFS <= -12,
              maximumPerSourceTonePeakDBFS >= -48,
              maximumAggregateSourcePeakDBFS.isFinite,
              maximumAggregateSourcePeakDBFS <= -9,
              maximumAggregateSourcePeakDBFS >= -36,
              maximumAggregateSourcePeakDBFS
                >= maximumPerSourceTonePeakDBFS,
              minimumProbeImprovementDB.isFinite,
              (0.25...6).contains(
                minimumProbeImprovementDB
              ),
              maximumAllowedRegressionDB.isFinite,
              (0.25...6).contains(
                maximumAllowedRegressionDB
              ),
              targetReductionDB.isFinite,
              (1...15).contains(targetReductionDB),
              armRampMilliseconds.isFinite,
              (100...5_000).contains(
                armRampMilliseconds
              ),
              faultFadeMilliseconds.isFinite,
              (20...1_000).contains(
                faultFadeMilliseconds
              ) else {
            throw ActiveQuietZoneError.invalidConfiguration
        }
        return self
    }
}

struct ActiveQuietZoneComplex:
    Equatable, Codable, Sendable
{
    var real: Double
    var imaginary: Double

    static let zero = ActiveQuietZoneComplex(
        real: 0,
        imaginary: 0
    )

    var magnitude: Double {
        hypot(real, imaginary)
    }

    var magnitudeDB: Double {
        20 * log10(max(magnitude, 1.0e-15))
    }

    var phaseRadians: Double {
        atan2(imaginary, real)
    }

    var conjugate: ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(
            real: real,
            imaginary: -imaginary
        )
    }

    static func + (
        lhs: ActiveQuietZoneComplex,
        rhs: ActiveQuietZoneComplex
    ) -> ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(
            real: lhs.real + rhs.real,
            imaginary: lhs.imaginary + rhs.imaginary
        )
    }

    static func - (
        lhs: ActiveQuietZoneComplex,
        rhs: ActiveQuietZoneComplex
    ) -> ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(
            real: lhs.real - rhs.real,
            imaginary: lhs.imaginary - rhs.imaginary
        )
    }

    static prefix func - (
        value: ActiveQuietZoneComplex
    ) -> ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(
            real: -value.real,
            imaginary: -value.imaginary
        )
    }

    static func * (
        lhs: ActiveQuietZoneComplex,
        rhs: ActiveQuietZoneComplex
    ) -> ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(
            real:
                lhs.real * rhs.real
                - lhs.imaginary * rhs.imaginary,
            imaginary:
                lhs.real * rhs.imaginary
                + lhs.imaginary * rhs.real
        )
    }

    static func * (
        lhs: ActiveQuietZoneComplex,
        rhs: Double
    ) -> ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(
            real: lhs.real * rhs,
            imaginary: lhs.imaginary * rhs
        )
    }

    static func / (
        lhs: ActiveQuietZoneComplex,
        rhs: Double
    ) -> ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(
            real: lhs.real / rhs,
            imaginary: lhs.imaginary / rhs
        )
    }

    func scaled(toMaximumMagnitude maximum: Double)
        -> ActiveQuietZoneComplex
    {
        guard maximum.isFinite,
              maximum >= 0,
              magnitude > maximum,
              magnitude > 0 else {
            return self
        }
        return self * (maximum / magnitude)
    }
}

struct ActiveQuietZoneRuntimeTone:
    Equatable, Sendable, Identifiable
{
    let frequencyHz: Double
    let leftOutput: ActiveQuietZoneComplex
    let rightOutput: ActiveQuietZoneComplex

    var id: Double { frequencyHz }
}

struct ActiveQuietZoneRuntimeTarget: Equatable, Sendable {
    var tones: [ActiveQuietZoneRuntimeTone]
    var transitionMilliseconds: Double

    static let bypassed = ActiveQuietZoneRuntimeTarget(
        tones: [],
        transitionMilliseconds: 100
    )

    var active: Bool { !tones.isEmpty }

    func validated(
        configuration:
            ActiveQuietZoneConfiguration =
                ActiveQuietZoneConfiguration()
    ) throws -> ActiveQuietZoneRuntimeTarget {
        let configuration = try configuration.validated()
        guard tones.count <= configuration.maximumToneCount,
              transitionMilliseconds.isFinite,
              transitionMilliseconds >= 20,
              transitionMilliseconds <= 5_000 else {
            throw ActiveQuietZoneError.invalidConfiguration
        }

        let maximumPerTone = pow(
            10,
            configuration.maximumPerSourceTonePeakDBFS / 20
        )
        let maximumAggregate = pow(
            10,
            configuration.maximumAggregateSourcePeakDBFS / 20
        )
        var leftAggregate = 0.0
        var rightAggregate = 0.0
        var seen: [Double] = []

        for tone in tones {
            guard tone.frequencyHz.isFinite,
                  tone.frequencyHz >= configuration.minimumFrequencyHz,
                  tone.frequencyHz <= configuration.maximumFrequencyHz,
                  tone.leftOutput.real.isFinite,
                  tone.leftOutput.imaginary.isFinite,
                  tone.rightOutput.real.isFinite,
                  tone.rightOutput.imaginary.isFinite,
                  tone.leftOutput.magnitude
                    <= maximumPerTone + 1.0e-9,
                  tone.rightOutput.magnitude
                    <= maximumPerTone + 1.0e-9,
                  !seen.contains(where: {
                      abs($0 - tone.frequencyHz) < 0.001
                  }) else {
                throw ActiveQuietZoneError.invalidConfiguration
            }
            seen.append(tone.frequencyHz)
            leftAggregate += tone.leftOutput.magnitude
            rightAggregate += tone.rightOutput.magnitude
        }
        guard leftAggregate <= maximumAggregate + 1.0e-9,
              rightAggregate <= maximumAggregate + 1.0e-9 else {
            throw ActiveQuietZoneError.invalidConfiguration
        }
        return self
    }

    var maximumSourceMagnitude: Double {
        max(
            tones.reduce(0.0) {
                $0 + $1.leftOutput.magnitude
            },
            tones.reduce(0.0) {
                $0 + $1.rightOutput.magnitude
            }
        )
    }

    func sameFrequencies(
        as other: ActiveQuietZoneRuntimeTarget
    ) -> Bool {
        guard tones.count == other.tones.count else {
            return false
        }
        return zip(tones, other.tones).allSatisfy {
            abs($0.frequencyHz - $1.frequencyHz) < 0.001
        }
    }
}

struct ActiveQuietZoneCandidateTone:
    Equatable, Sendable, Identifiable
{
    let frequencyHz: Double
    let levelDBFS: Double
    let prominenceDB: Double

    var id: Double { frequencyHz }
}

struct ActiveQuietZoneStereoSolution: Equatable, Sendable {
    let frequencyHz: Double
    let disturbance: ActiveQuietZoneComplex
    let leftSecondaryPath: ActiveQuietZoneComplex
    let rightSecondaryPath: ActiveQuietZoneComplex
    let leftOutput: ActiveQuietZoneComplex
    let rightOutput: ActiveQuietZoneComplex
    let safetyScale: Double
    let predictedResidual: ActiveQuietZoneComplex
    let predictedReductionDB: Double
    let availableInjectionPeak: Double
}

struct ActiveQuietZoneVerification:
    Equatable, Sendable
{
    enum Decision: String, Equatable, Sendable {
        case accept
        case continueProbe
        case faultRegression
        case invalid
    }

    let decision: Decision
    let beforeLevelDBFS: Double
    let afterLevelDBFS: Double
    let measuredReductionDB: Double
}

enum ActiveQuietZoneError:
    Error, Equatable, LocalizedError
{
    case invalidConfiguration
    case invalidSampleRate(Double)
    case invalidFrequency(Double)
    case invalidImpulseResponse
    case invalidDisturbance
    case unusableSecondaryPath
    case insufficientOutputHeadroom
    case runtimeUnsupported
    case frequencyChangeRequiresDisarm
    case nonFiniteSolution

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Active Quiet Zone settings are invalid."
        case .invalidSampleRate(let value):
            return "Active Quiet Zone sample rate \(value) Hz is invalid."
        case .invalidFrequency(let value):
            return "Active Quiet Zone frequency \(value) Hz is outside the supported low-frequency range."
        case .invalidImpulseResponse:
            return "Active Quiet Zone requires finite measured speaker-to-monitor impulse responses."
        case .invalidDisturbance:
            return "Active Quiet Zone disturbance estimate is invalid."
        case .unusableSecondaryPath:
            return "The measured speaker-to-monitor path cannot support a stable cancellation solution at this frequency."
        case .insufficientOutputHeadroom:
            return "The active Content Preset does not reserve enough output headroom for bounded anti-noise injection."
        case .runtimeUnsupported:
            return "Active Quiet Zone currently requires the direct stereo speaker transport."
        case .frequencyChangeRequiresDisarm:
            return "Active Quiet Zone must fade the current tone to silence before changing cancellation frequency."
        case .nonFiniteSolution:
            return "Active Quiet Zone produced a non-finite cancellation candidate."
        }
    }
}

struct ActiveQuietZonePlanner: Sendable {
    func eligibleTones(
        snapshot: AmbientAnalysisSnapshot,
        allowMicrophoneOnly: Bool,
        configuration rawConfiguration:
            ActiveQuietZoneConfiguration
    ) throws -> [ActiveQuietZoneCandidateTone] {
        let configuration = try rawConfiguration.validated()

        switch snapshot.separationMode {
        case .modeledPlaybackSubtraction:
            guard snapshot.separationConfidence
                    >= configuration
                        .minimumSeparationConfidence else {
                return []
            }
        case .microphoneOnly:
            guard allowMicrophoneOnly else { return [] }
        case .playbackModelUnavailable:
            return []
        }

        guard snapshot.stationarityScore
                >= configuration.minimumStationarity,
              snapshot.character != .nonstationary else {
            return []
        }

        return snapshot.tonalComponents
            .filter {
                $0.frequencyHz
                    >= configuration.minimumFrequencyHz
                    && $0.frequencyHz
                        <= configuration.maximumFrequencyHz
                    && $0.prominenceDB
                        >= configuration
                            .minimumTonalProminenceDB
                    && $0.levelDBFS.isFinite
            }
            .prefix(configuration.maximumToneCount)
            .map {
                ActiveQuietZoneCandidateTone(
                    frequencyHz: $0.frequencyHz,
                    levelDBFS: $0.levelDBFS,
                    prominenceDB: $0.prominenceDB
                )
            }
    }

    /// Complex transfer H(e^jw) from a measured FIR secondary path.
    func secondaryPath(
        impulseResponse: [Float],
        frequencyHz: Double,
        sampleRate: Double
    ) throws -> ActiveQuietZoneComplex {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw ActiveQuietZoneError.invalidSampleRate(
                sampleRate
            )
        }
        guard frequencyHz.isFinite,
              frequencyHz
                >= ActiveQuietZoneConfiguration
                    .hardMinimumFrequencyHz,
              frequencyHz
                <= ActiveQuietZoneConfiguration
                    .hardMaximumFrequencyHz,
              frequencyHz < sampleRate * 0.5 else {
            throw ActiveQuietZoneError.invalidFrequency(
                frequencyHz
            )
        }
        guard !impulseResponse.isEmpty,
              impulseResponse.count <= 32_768,
              impulseResponse.allSatisfy({
                  $0.isFinite
              }) else {
            throw ActiveQuietZoneError.invalidImpulseResponse
        }

        let omega =
            2 * Double.pi * frequencyHz / sampleRate
        var real = 0.0
        var imaginary = 0.0
        for (index, value) in impulseResponse.enumerated() {
            let phase = omega * Double(index)
            let sample = Double(value)
            real += sample * cos(phase)
            imaginary -= sample * sin(phase)
        }
        let result = ActiveQuietZoneComplex(
            real: real,
            imaginary: imaginary
        )
        guard result.real.isFinite,
              result.imaginary.isFinite else {
            throw ActiveQuietZoneError.invalidImpulseResponse
        }
        return result
    }

    /// Exact-frequency peak phasor using a Hann-weighted complex projection.
    ///
    /// A real sinusoid A*cos(w*n+phi) returns approximately
    /// A*exp(j*phi). This is control-plane only.
    func tonePhasor(
        samples: [Float],
        frequencyHz: Double,
        sampleRate: Double
    ) throws -> ActiveQuietZoneComplex {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw ActiveQuietZoneError.invalidSampleRate(
                sampleRate
            )
        }
        guard frequencyHz.isFinite,
              frequencyHz > 0,
              frequencyHz < sampleRate * 0.5 else {
            throw ActiveQuietZoneError.invalidFrequency(
                frequencyHz
            )
        }
        guard samples.count >= 256,
              samples.allSatisfy({ $0.isFinite }) else {
            throw ActiveQuietZoneError.invalidDisturbance
        }

        let omega =
            2 * Double.pi * frequencyHz / sampleRate
        let denominator = Double(samples.count - 1)
        var real = 0.0
        var imaginary = 0.0
        var windowSum = 0.0
        for index in samples.indices {
            let window =
                0.5
                - 0.5
                    * cos(
                        2 * Double.pi * Double(index)
                            / denominator
                    )
            let sample = Double(samples[index]) * window
            let phase = omega * Double(index)
            real += sample * cos(phase)
            imaginary -= sample * sin(phase)
            windowSum += window
        }
        guard windowSum > 1.0e-12 else {
            throw ActiveQuietZoneError.invalidDisturbance
        }
        let scale = 2.0 / windowSum
        let result = ActiveQuietZoneComplex(
            real: real * scale,
            imaginary: imaginary * scale
        )
        guard result.real.isFinite,
              result.imaginary.isFinite else {
            throw ActiveQuietZoneError.invalidDisturbance
        }
        return result
    }

    /// Single-error-point, two-source regularized least-energy inverse.
    ///
    /// Minimize |d + H_L*w_L + H_R*w_R|^2 + lambda*||w||^2.
    func solveStereo(
        frequencyHz: Double,
        disturbance: ActiveQuietZoneComplex,
        leftSecondaryPath: ActiveQuietZoneComplex,
        rightSecondaryPath: ActiveQuietZoneComplex,
        availableInjectionPeak: Double,
        configuration rawConfiguration:
            ActiveQuietZoneConfiguration
    ) throws -> ActiveQuietZoneStereoSolution {
        let configuration = try rawConfiguration.validated()
        guard frequencyHz
                >= configuration.minimumFrequencyHz,
              frequencyHz
                <= configuration.maximumFrequencyHz else {
            throw ActiveQuietZoneError.invalidFrequency(
                frequencyHz
            )
        }
        guard disturbance.real.isFinite,
              disturbance.imaginary.isFinite,
              disturbance.magnitude > 1.0e-12 else {
            throw ActiveQuietZoneError.invalidDisturbance
        }
        guard availableInjectionPeak.isFinite,
              availableInjectionPeak > 0 else {
            throw ActiveQuietZoneError
                .insufficientOutputHeadroom
        }

        let pathPower =
            pow(leftSecondaryPath.magnitude, 2)
            + pow(rightSecondaryPath.magnitude, 2)
        guard pathPower.isFinite,
              pathPower > 1.0e-12 else {
            throw ActiveQuietZoneError.unusableSecondaryPath
        }

        let lambda =
            max(
                pathPower * configuration.regularization,
                1.0e-12
            )
        let denominator = pathPower + lambda
        var left =
            -(leftSecondaryPath.conjugate * disturbance)
            / denominator
        var right =
            -(rightSecondaryPath.conjugate * disturbance)
            / denominator

        let perToneMaximum = Self.linearPeak(
            dbfs: configuration
                .maximumPerSourceTonePeakDBFS
        )
        let aggregateMaximum = min(
            Self.linearPeak(
                dbfs: configuration
                    .maximumAggregateSourcePeakDBFS
            ),
            availableInjectionPeak
        )
        guard aggregateMaximum > 0 else {
            throw ActiveQuietZoneError
                .insufficientOutputHeadroom
        }

        let candidateMaximum = max(
            left.magnitude,
            right.magnitude
        )
        let permittedMaximum = min(
            perToneMaximum,
            aggregateMaximum
        )
        let safetyScale = candidateMaximum > permittedMaximum
            ? permittedMaximum / candidateMaximum
            : 1.0
        left = left * safetyScale
        right = right * safetyScale

        let cancellationContribution =
            leftSecondaryPath * left
            + rightSecondaryPath * right

        // Do not chase theoretical silence. If the regularized/headroom-bounded
        // solution can exceed the requested reduction, scale it back to the
        // smallest injection that reaches the configured target. This preserves
        // reserve for program peaks and reduces sensitivity to model error.
        let targetMagnitude =
            disturbance.magnitude
            * pow(10, -configuration.targetReductionDB / 20)
        var targetScale = 1.0
        let fullResidual =
            disturbance + cancellationContribution
        if fullResidual.magnitude < targetMagnitude {
            var low = 0.0
            var high = 1.0
            for _ in 0..<48 {
                let middle = (low + high) * 0.5
                let residual =
                    disturbance
                    + cancellationContribution * middle
                if residual.magnitude <= targetMagnitude {
                    high = middle
                } else {
                    low = middle
                }
            }
            targetScale = high
            left = left * targetScale
            right = right * targetScale
        }

        let predictedResidual =
            disturbance
            + leftSecondaryPath * left
            + rightSecondaryPath * right
        let predictedReductionDB =
            20
            * log10(
                max(disturbance.magnitude, 1.0e-15)
                    / max(
                        predictedResidual.magnitude,
                        1.0e-15
                    )
            )
        let combinedScale = safetyScale * targetScale

        guard left.real.isFinite,
              left.imaginary.isFinite,
              right.real.isFinite,
              right.imaginary.isFinite,
              predictedResidual.real.isFinite,
              predictedResidual.imaginary.isFinite,
              predictedReductionDB.isFinite,
              combinedScale.isFinite,
              combinedScale > 0,
              combinedScale <= 1 else {
            throw ActiveQuietZoneError.nonFiniteSolution
        }

        return ActiveQuietZoneStereoSolution(
            frequencyHz: frequencyHz,
            disturbance: disturbance,
            leftSecondaryPath: leftSecondaryPath,
            rightSecondaryPath: rightSecondaryPath,
            leftOutput: left,
            rightOutput: right,
            safetyScale: combinedScale,
            predictedResidual: predictedResidual,
            predictedReductionDB: predictedReductionDB,
            availableInjectionPeak: aggregateMaximum
        )
    }

    func availableInjectionPeak(
        headroomAttenuationDB: Double,
        ambientLevelRecoveryDB: Double,
        configuration rawConfiguration:
            ActiveQuietZoneConfiguration
    ) throws -> Double {
        let configuration = try rawConfiguration.validated()
        guard headroomAttenuationDB.isFinite,
              headroomAttenuationDB <= 0,
              ambientLevelRecoveryDB.isFinite,
              ambientLevelRecoveryDB >= 0 else {
            throw ActiveQuietZoneError.invalidConfiguration
        }

        let effectiveProgramDB =
            headroomAttenuationDB
            + ambientLevelRecoveryDB
        let programPeak = pow(
            10,
            min(effectiveProgramDB, 0) / 20
        )
        let fullScaleMargin = max(1 - programPeak, 0)
        let hardAggregate = Self.linearPeak(
            dbfs: configuration
                .maximumAggregateSourcePeakDBFS
        )
        return min(fullScaleMargin, hardAggregate)
    }

    func verify(
        beforeLevelDBFS: Double,
        afterLevelDBFS: Double,
        configuration rawConfiguration:
            ActiveQuietZoneConfiguration
    ) throws -> ActiveQuietZoneVerification {
        let configuration = try rawConfiguration.validated()
        guard beforeLevelDBFS.isFinite,
              afterLevelDBFS.isFinite else {
            return ActiveQuietZoneVerification(
                decision: .invalid,
                beforeLevelDBFS: beforeLevelDBFS,
                afterLevelDBFS: afterLevelDBFS,
                measuredReductionDB: -.infinity
            )
        }

        let reduction =
            beforeLevelDBFS - afterLevelDBFS
        let decision: ActiveQuietZoneVerification.Decision
        if reduction
            >= configuration.minimumProbeImprovementDB {
            decision = .accept
        } else if reduction
                    <= -configuration
                        .maximumAllowedRegressionDB {
            decision = .faultRegression
        } else {
            decision = .continueProbe
        }

        return ActiveQuietZoneVerification(
            decision: decision,
            beforeLevelDBFS: beforeLevelDBFS,
            afterLevelDBFS: afterLevelDBFS,
            measuredReductionDB: reduction
        )
    }

    private static func linearPeak(
        dbfs: Double
    ) -> Double {
        pow(10, dbfs / 20)
    }
}

struct ActiveQuietZoneTonePersistenceTracker:
    Equatable, Sendable
{
    private(set) var frequencyHz: Double?
    private(set) var stableWindowCount = 0

    mutating func reset() {
        frequencyHz = nil
        stableWindowCount = 0
    }

    mutating func observe(
        frequencyHz newFrequency: Double?,
        configuration: ActiveQuietZoneConfiguration
    ) throws -> Bool {
        let configuration = try configuration.validated()
        guard let newFrequency,
              newFrequency.isFinite,
              newFrequency
                >= configuration.minimumFrequencyHz,
              newFrequency
                <= configuration.maximumFrequencyHz else {
            reset()
            return false
        }

        if let frequencyHz,
           abs(frequencyHz - newFrequency)
                <= configuration
                    .stableFrequencyToleranceHz {
            stableWindowCount += 1
            self.frequencyHz =
                (
                    frequencyHz
                    * Double(stableWindowCount - 1)
                    + newFrequency
                )
                / Double(stableWindowCount)
        } else {
            self.frequencyHz = newFrequency
            stableWindowCount = 1
        }

        return stableWindowCount
            >= configuration.requiredStableWindows
    }
}
