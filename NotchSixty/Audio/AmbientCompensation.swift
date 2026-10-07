import Foundation

enum ActiveAcousticsPlaybackAdaptationMode:
    String, CaseIterable, Codable, Equatable, Sendable
{
    case off
    case musicFocus
    case conversationFocus

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .musicFocus: return "Music Focus"
        case .conversationFocus: return "Conversation Focus"
        }
    }
}

enum AmbientActivityClass: String, CaseIterable, Codable, Equatable, Sendable {
    case quiet
    case normal
    case busy
    case party

    var displayName: String {
        switch self {
        case .quiet: return "Quiet"
        case .normal: return "Normal"
        case .busy: return "Busy"
        case .party: return "Party"
        }
    }
}

enum AmbientCompensationHoldReason: String, Codable, Equatable, Sendable {
    case disabled
    case baselineRequired
    case playbackModelRequired
    case lowSeparationConfidence
    case nonstationaryTransient
    case invalidEvidence
    case noAvailableHeadroom
}

struct ConversationPreservationConfiguration:
    Codable, Equatable, Sendable
{
    static let attenuationRangeDB = 0.0...6.0
    static let presenceCutRangeDB = 0.0...3.0
    static let restorationRangeDB = 0.0...2.0
    static let evidenceThresholdRange = 0.20...0.90
    static let timeRangeSeconds = 0.25...60.0

    var maximumOverallAttenuationDB = 4.0
    var maximumPresenceCutDB = 3.0
    var maximumLowRestorationDB = 1.75
    var maximumDetailRestorationDB = 0.75
    var minimumConversationEvidence = 0.42
    var attackSeconds = 1.5
    var releaseSeconds = 8.0

    func validated() throws -> ConversationPreservationConfiguration {
        guard maximumOverallAttenuationDB.isFinite,
              Self.attenuationRangeDB.contains(maximumOverallAttenuationDB),
              maximumPresenceCutDB.isFinite,
              Self.presenceCutRangeDB.contains(maximumPresenceCutDB),
              maximumLowRestorationDB.isFinite,
              Self.restorationRangeDB.contains(maximumLowRestorationDB),
              maximumDetailRestorationDB.isFinite,
              Self.restorationRangeDB.contains(maximumDetailRestorationDB),
              minimumConversationEvidence.isFinite,
              Self.evidenceThresholdRange.contains(minimumConversationEvidence),
              attackSeconds.isFinite,
              Self.timeRangeSeconds.contains(attackSeconds),
              releaseSeconds.isFinite,
              Self.timeRangeSeconds.contains(releaseSeconds) else {
            throw AmbientCompensationError.invalidConfiguration
        }
        return self
    }
}

struct AmbientCompensationConfiguration: Codable, Equatable, Sendable {
    static let hardMaximumLevelCompensationDB = 6.0
    static let strengthRange = 0.0...1.0
    static let minimumConfidenceRange = 0.50...0.98
    static let timeRangeSeconds = 1.0...120.0

    var enabled = false
    /// Optional for backward-compatible decoding of PR89/PR90 saved profiles.
    /// Nil maps legacy enabled=true to Music Focus and enabled=false to Off.
    var playbackAdaptationMode:
        ActiveAcousticsPlaybackAdaptationMode?
    var conversationPreservation:
        ConversationPreservationConfiguration?
    var strength = 0.75
    var levelCompensationEnabled = true
    var maximumLevelCompensationDB = 3.0
    var baselineAmbientLevelDBFS: Double?
    var optionalDBSPLAt0DBFS: Double?
    var playbackModelPositionID: UUID?
    var minimumSeparationConfidence = 0.75
    var attackSeconds = 6.0
    var releaseSeconds = 20.0
    var transientHoldSeconds = 3.0

    var effectivePlaybackAdaptationMode:
        ActiveAcousticsPlaybackAdaptationMode {
        playbackAdaptationMode ?? (enabled ? .musicFocus : .off)
    }

    var effectiveConversationPreservation:
        ConversationPreservationConfiguration {
        conversationPreservation
            ?? ConversationPreservationConfiguration()
    }

    func validated() throws -> AmbientCompensationConfiguration {
        guard strength.isFinite,
              Self.strengthRange.contains(strength),
              maximumLevelCompensationDB.isFinite,
              maximumLevelCompensationDB >= 0,
              maximumLevelCompensationDB <= Self.hardMaximumLevelCompensationDB,
              minimumSeparationConfidence.isFinite,
              Self.minimumConfidenceRange.contains(minimumSeparationConfidence),
              attackSeconds.isFinite,
              Self.timeRangeSeconds.contains(attackSeconds),
              releaseSeconds.isFinite,
              Self.timeRangeSeconds.contains(releaseSeconds),
              transientHoldSeconds.isFinite,
              transientHoldSeconds >= 0,
              transientHoldSeconds <= 30,
              baselineAmbientLevelDBFS?.isFinite ?? true,
              optionalDBSPLAt0DBFS?.isFinite ?? true else {
            throw AmbientCompensationError.invalidConfiguration
        }
        _ = try effectiveConversationPreservation.validated()
        return self
    }
}

struct AmbientCompensationTarget: Equatable, Sendable {
    static let unity = AmbientCompensationTarget(
        activity: .quiet,
        levelDB: 0,
        lowSupportDB: 0,
        presenceSupportDB: 0,
        detailSupportDB: 0,
        confidence: 0,
        ambientDeltaDB: 0,
        holdReason: nil
    )

    var activity: AmbientActivityClass
    var levelDB: Double
    var lowSupportDB: Double
    var presenceSupportDB: Double
    var detailSupportDB: Double
    var confidence: Double
    var ambientDeltaDB: Double
    var holdReason: AmbientCompensationHoldReason?
    var mode: ActiveAcousticsPlaybackAdaptationMode = .musicFocus
    var conversationEvidence: Double = 0
    var estimatedClearanceDB: Double = 0

    var active: Bool {
        holdReason == nil
            && (
                abs(levelDB) > 0.001
                || abs(lowSupportDB) > 0.001
                || abs(presenceSupportDB) > 0.001
                || abs(detailSupportDB) > 0.001
            )
    }
}

enum AmbientCompensationError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case invalidAvailableHeadroom(Double)
    case nonFiniteSnapshot
    case runtimeUnsupported
    case insufficientDigitalHeadroom(requested: Double, available: Double)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Ambient Compensation settings are invalid."
        case .invalidAvailableHeadroom(let value):
            return "Ambient Compensation available headroom \(value) dB is invalid."
        case .nonFiniteSnapshot:
            return "Ambient Compensation received non-finite ambient-analysis evidence."
        case .runtimeUnsupported:
            return "Ambient Compensation is available only on the stereo speaker transport."
        case .insufficientDigitalHeadroom(let requested, let available):
            return "Ambient Compensation requested \(requested) dB of level recovery with only \(available) dB of digital headroom available."
        }
    }
}

struct AmbientCompensationResponsePoint: Equatable, Sendable {
    let frequencyHz: Double
    let gainDB: Double
}

/// Control-plane response model for the exact PR89 realtime overlay topology.
///
/// Frequencies/Q values intentionally mirror
/// N60DSPGraphSnapshotSetAmbientCompensation. Coefficients are designed through
/// the same N60BiquadDesign implementation consumed by the render snapshot, so
/// the UI curve is an acoustic transfer-function view of the applied overlay,
/// not a decorative interpolation between the three control values.
enum AmbientCompensationResponseModel {
    static let lowShelfFrequencyHz = 120.0
    static let lowShelfQ = 0.707
    static let presenceFrequencyHz = 2_200.0
    static let presenceQ = 0.85
    static let detailShelfFrequencyHz = 6_500.0
    static let detailShelfQ = 0.707

    static func response(
        target: AmbientCompensationTarget,
        sampleRate: Double,
        pointCount: Int = 160
    ) -> [AmbientCompensationResponsePoint] {
        guard sampleRate.isFinite,
              sampleRate > detailShelfFrequencyHz * 2,
              pointCount >= 8 else {
            return []
        }

        guard let low = coefficients(
                  type: N60BiquadFilterTypeLowShelf,
                  frequencyHz: lowShelfFrequencyHz,
                  gainDB: target.lowSupportDB,
                  q: lowShelfQ,
                  sampleRate: sampleRate
              ),
              let presence = coefficients(
                  type: N60BiquadFilterTypePeaking,
                  frequencyHz: presenceFrequencyHz,
                  gainDB: target.presenceSupportDB,
                  q: presenceQ,
                  sampleRate: sampleRate
              ),
              let detail = coefficients(
                  type: N60BiquadFilterTypeHighShelf,
                  frequencyHz: detailShelfFrequencyHz,
                  gainDB: target.detailSupportDB,
                  q: detailShelfQ,
                  sampleRate: sampleRate
              ) else {
            return []
        }

        let lowHz = 20.0
        let highHz = min(20_000.0, sampleRate * 0.48)
        guard highHz > lowHz else { return [] }
        let ratio = highHz / lowHz

        return (0..<pointCount).map { index in
            let fraction = pointCount == 1
                ? 0
                : Double(index) / Double(pointCount - 1)
            let frequency = lowHz * pow(ratio, fraction)
            let spectralGain =
                magnitudeDB(
                    low,
                    frequencyHz: frequency,
                    sampleRate: sampleRate
                )
                + magnitudeDB(
                    presence,
                    frequencyHz: frequency,
                    sampleRate: sampleRate
                )
                + magnitudeDB(
                    detail,
                    frequencyHz: frequency,
                    sampleRate: sampleRate
                )
            return AmbientCompensationResponsePoint(
                frequencyHz: frequency,
                gainDB: target.levelDB + spectralGain
            )
        }
    }

    static func minimumAppliedGainDB(
        target: AmbientCompensationTarget,
        sampleRate: Double
    ) -> Double {
        response(
            target: target,
            sampleRate: sampleRate,
            pointCount: 256
        )
        .map(\.gainDB)
        .min()
        ?? target.levelDB
    }

    static func maximumAppliedGainDB(
        target: AmbientCompensationTarget,
        sampleRate: Double
    ) -> Double {
        response(
            target: target,
            sampleRate: sampleRate,
            pointCount: 256
        )
        .map(\.gainDB)
        .max()
        ?? target.levelDB
    }

    private static func coefficients(
        type: N60BiquadFilterType,
        frequencyHz: Double,
        gainDB: Double,
        q: Double,
        sampleRate: Double
    ) -> N60BiquadCoefficients? {
        if abs(gainDB) <= 0.000_1 {
            return N60BiquadCoefficientsMakeIdentity()
        }
        var result = N60BiquadCoefficients()
        guard N60BiquadDesign(
            type,
            sampleRate,
            frequencyHz,
            gainDB,
            q,
            &result
        ) else {
            return nil
        }
        return result
    }

    private static func magnitudeDB(
        _ coefficients: N60BiquadCoefficients,
        frequencyHz: Double,
        sampleRate: Double
    ) -> Double {
        let omega = 2.0 * Double.pi * frequencyHz / sampleRate
        let cosine = cos(omega)
        let sine = sin(omega)
        let cosine2 = cos(2.0 * omega)
        let sine2 = sin(2.0 * omega)

        let numeratorReal =
            Double(coefficients.b0)
            + Double(coefficients.b1) * cosine
            + Double(coefficients.b2) * cosine2
        let numeratorImaginary =
            -Double(coefficients.b1) * sine
            - Double(coefficients.b2) * sine2
        let denominatorReal =
            1.0
            + Double(coefficients.a1) * cosine
            + Double(coefficients.a2) * cosine2
        let denominatorImaginary =
            -Double(coefficients.a1) * sine
            - Double(coefficients.a2) * sine2

        let numeratorPower =
            numeratorReal * numeratorReal
            + numeratorImaginary * numeratorImaginary
        let denominatorPower =
            denominatorReal * denominatorReal
            + denominatorImaginary * denominatorImaginary
        guard numeratorPower.isFinite,
              denominatorPower.isFinite,
              denominatorPower > 1.0e-30 else {
            return 0
        }
        return 10.0 * log10(
            max(numeratorPower / denominatorPower, 1.0e-30)
        )
    }
}

/// Slow, bounded control-plane policy for converting trusted ambient analysis
/// into a small playback compensation request. It never mutates DSP state.
struct AmbientCompensationPlanner: Sendable {
    static let quietThresholdDB = 3.0
    static let normalThresholdDB = 8.0
    static let busyThresholdDB = 15.0
    static let activityHysteresisDB = 1.5
    static let maximumLowSupportDB = 2.0
    static let maximumPresenceSupportDB = 2.0
    static let maximumDetailSupportDB = 1.5
    static let minimumStationarity = 0.45
    static let levelResponseSlope = 0.22

    func plan(
        snapshot: AmbientAnalysisSnapshot,
        configuration rawConfiguration: AmbientCompensationConfiguration,
        availableHeadroomDB: Double,
        previousActivity: AmbientActivityClass? = nil
    ) throws -> AmbientCompensationTarget {
        let configuration = try rawConfiguration.validated()
        guard availableHeadroomDB.isFinite, availableHeadroomDB >= 0 else {
            throw AmbientCompensationError.invalidAvailableHeadroom(
                availableHeadroomDB
            )
        }
        guard Self.snapshotIsFinite(snapshot) else {
            throw AmbientCompensationError.nonFiniteSnapshot
        }
        guard configuration.enabled else {
            return held(.disabled, snapshot: snapshot)
        }
        guard let baseline = configuration.baselineAmbientLevelDBFS,
              baseline.isFinite else {
            return held(.baselineRequired, snapshot: snapshot)
        }

        if snapshot.separationMode == .playbackModelUnavailable {
            return held(.playbackModelRequired, snapshot: snapshot)
        }
        if snapshot.separationMode == .modeledPlaybackSubtraction,
           snapshot.separationConfidence
                < configuration.minimumSeparationConfidence {
            return held(.lowSeparationConfidence, snapshot: snapshot)
        }
        if snapshot.character == .nonstationary
            || snapshot.stationarityScore < Self.minimumStationarity {
            return held(.nonstationaryTransient, snapshot: snapshot)
        }

        let delta = max(snapshot.ambientLevelDBFS - baseline, 0)
        let activity = Self.activity(
            deltaDB: delta,
            previous: previousActivity
        )
        let activityAmount = Self.clamp01(
            (delta - Self.quietThresholdDB)
                / (Self.busyThresholdDB - Self.quietThresholdDB)
        )
        let confidence = Self.clamp01(snapshot.separationConfidence)
        let evidenceScale = configuration.strength
            * confidence
            * Self.clamp(
                snapshot.stationarityScore,
                low: 0.55,
                high: 1
            )

        let maximumLevel = min(
            configuration.maximumLevelCompensationDB,
            availableHeadroomDB,
            AmbientCompensationConfiguration
                .hardMaximumLevelCompensationDB
        )
        let level: Double
        if configuration.levelCompensationEnabled, maximumLevel > 0 {
            level = min(
                max(
                    (delta - Self.quietThresholdDB)
                        * Self.levelResponseSlope,
                    0
                ) * evidenceScale,
                maximumLevel
            )
        } else {
            level = 0
        }

        let regional = Self.regionalMasking(snapshot.spectrum)
        let lowSupport = min(
            Self.maximumLowSupportDB,
            Self.maximumLowSupportDB
                * activityAmount
                * evidenceScale
                * (0.45 + 0.55 * regional.low)
        )
        let presenceSupport = min(
            Self.maximumPresenceSupportDB,
            Self.maximumPresenceSupportDB
                * activityAmount
                * evidenceScale
                * (0.40 + 0.60 * regional.presence)
        )
        let detailSupport = min(
            Self.maximumDetailSupportDB,
            Self.maximumDetailSupportDB
                * activityAmount
                * evidenceScale
                * (0.35 + 0.65 * regional.high)
        )

        let noHeadroomHold: AmbientCompensationHoldReason?
        if configuration.levelCompensationEnabled,
           maximumLevel <= 0,
           lowSupport < 0.01,
           presenceSupport < 0.01,
           detailSupport < 0.01 {
            noHeadroomHold = .noAvailableHeadroom
        } else {
            noHeadroomHold = nil
        }

        return AmbientCompensationTarget(
            activity: activity,
            levelDB: level,
            lowSupportDB: lowSupport,
            presenceSupportDB: presenceSupport,
            detailSupportDB: detailSupport,
            confidence: confidence,
            ambientDeltaDB: delta,
            holdReason: noHeadroomHold
        )
    }

    private func held(
        _ reason: AmbientCompensationHoldReason,
        snapshot: AmbientAnalysisSnapshot
    ) -> AmbientCompensationTarget {
        AmbientCompensationTarget(
            activity: .quiet,
            levelDB: 0,
            lowSupportDB: 0,
            presenceSupportDB: 0,
            detailSupportDB: 0,
            confidence: Self.clamp01(snapshot.separationConfidence),
            ambientDeltaDB: 0,
            holdReason: reason
        )
    }

    static func activity(
        deltaDB: Double,
        previous: AmbientActivityClass?
    ) -> AmbientActivityClass {
        var quietBoundary = quietThresholdDB
        var normalBoundary = normalThresholdDB
        var busyBoundary = busyThresholdDB

        switch previous {
        case .quiet:
            quietBoundary += activityHysteresisDB
        case .normal:
            quietBoundary -= activityHysteresisDB
            normalBoundary += activityHysteresisDB
        case .busy:
            normalBoundary -= activityHysteresisDB
            busyBoundary += activityHysteresisDB
        case .party:
            busyBoundary -= activityHysteresisDB
        case nil:
            break
        }

        if deltaDB < quietBoundary { return .quiet }
        if deltaDB < normalBoundary { return .normal }
        if deltaDB < busyBoundary { return .busy }
        return .party
    }

    private static func regionalMasking(
        _ spectrum: [AmbientSpectrumBand]
    ) -> (low: Double, presence: Double, high: Double) {
        guard !spectrum.isEmpty else { return (0.5, 0.5, 0.5) }
        let finite = spectrum.filter {
            $0.levelDBFS.isFinite
                && $0.centerFrequencyHz.isFinite
                && $0.centerFrequencyHz > 0
        }
        guard !finite.isEmpty else { return (0.5, 0.5, 0.5) }

        let overall = median(finite.map(\.levelDBFS))
        func mask(low: Double, high: Double) -> Double {
            let values = finite.filter {
                $0.centerFrequencyHz >= low
                    && $0.centerFrequencyHz <= high
            }.map(\.levelDBFS)
            guard !values.isEmpty else { return 0.5 }
            let prominence = median(values) - overall
            return clamp01((prominence + 6.0) / 12.0)
        }

        return (
            mask(low: 30, high: 250),
            mask(low: 800, high: 4_000),
            mask(low: 4_000, high: 16_000)
        )
    }

    private static func snapshotIsFinite(
        _ snapshot: AmbientAnalysisSnapshot
    ) -> Bool {
        snapshot.sampleRate.isFinite
            && snapshot.separationConfidence.isFinite
            && snapshot.microphoneLevelDBFS.isFinite
            && snapshot.ambientLevelDBFS.isFinite
            && snapshot.stationarityScore.isFinite
            && snapshot.periodicityScore.isFinite
            && snapshot.lowFrequencyEnergyFraction.isFinite
            && snapshot.cancellationCandidateScore.isFinite
            && snapshot.spectrum.allSatisfy {
                $0.lowerFrequencyHz.isFinite
                    && $0.centerFrequencyHz.isFinite
                    && $0.upperFrequencyHz.isFinite
                    && $0.levelDBFS.isFinite
            }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }

    private static func clamp01(_ value: Double) -> Double {
        clamp(value, low: 0, high: 1)
    }

    private static func clamp(
        _ value: Double,
        low: Double,
        high: Double
    ) -> Double {
        min(max(value, low), high)
    }
}

/// Explainable social-listening policy. It consumes only the separated
/// environmental residual summarized by AmbientFieldAnalyzer; it never performs
/// speech recognition, transcription, or speaker identification.
struct ConversationPreservationPlanner: Sendable {
    static let minimumAmbientDeltaDB = 2.5

    func plan(
        snapshot: AmbientAnalysisSnapshot,
        configuration rawConfiguration: AmbientCompensationConfiguration,
        previousActivity: AmbientActivityClass? = nil
    ) throws -> AmbientCompensationTarget {
        let configuration = try rawConfiguration.validated()
        let social = try configuration
            .effectiveConversationPreservation.validated()

        guard snapshot.sampleRate.isFinite,
              snapshot.separationConfidence.isFinite,
              snapshot.ambientLevelDBFS.isFinite,
              snapshot.stationarityScore.isFinite,
              snapshot.periodicityScore.isFinite,
              snapshot.spectrum.allSatisfy({
                  $0.centerFrequencyHz.isFinite
                      && $0.levelDBFS.isFinite
              }) else {
            throw AmbientCompensationError.nonFiniteSnapshot
        }

        guard let baseline =
                configuration.baselineAmbientLevelDBFS,
              baseline.isFinite else {
            return held(.baselineRequired, snapshot: snapshot)
        }
        guard snapshot.separationMode
                == .modeledPlaybackSubtraction else {
            return held(.playbackModelRequired, snapshot: snapshot)
        }
        guard snapshot.separationConfidence
                >= configuration.minimumSeparationConfidence else {
            return held(
                .lowSeparationConfidence,
                snapshot: snapshot
            )
        }

        let delta = max(snapshot.ambientLevelDBFS - baseline, 0)
        let activity = AmbientCompensationPlanner.activity(
            deltaDB: delta,
            previous: previousActivity
        )
        let evidence = conversationEvidence(snapshot)
        let threshold = social.minimumConversationEvidence

        guard delta >= Self.minimumAmbientDeltaDB,
              evidence >= threshold else {
            return AmbientCompensationTarget(
                activity: activity,
                levelDB: 0,
                lowSupportDB: 0,
                presenceSupportDB: 0,
                detailSupportDB: 0,
                confidence: snapshot.separationConfidence,
                ambientDeltaDB: delta,
                holdReason: nil,
                mode: .conversationFocus,
                conversationEvidence: evidence,
                estimatedClearanceDB: 0
            )
        }

        let evidenceAmount = clamp01(
            (evidence - threshold)
                / max(1.0 - threshold, 0.001)
        )
        let levelAmount = clamp01(
            (delta - Self.minimumAmbientDeltaDB) / 12.0
        )
        let amount =
            configuration.strength
            * (0.35 + 0.65 * evidenceAmount)
            * levelAmount

        let attenuation =
            social.maximumOverallAttenuationDB * amount
        let presenceCut =
            social.maximumPresenceCutDB
            * amount
            * (0.55 + 0.45 * evidence)

        // Restoration is relative to the full-band attenuation, never a net
        // boost above unity. This preserves musical weight/air while speech
        // receives the largest clearance in its critical band.
        let lowRestore = min(
            social.maximumLowRestorationDB * amount,
            attenuation * 0.72
        )
        let detailRestore = min(
            social.maximumDetailRestorationDB * amount,
            attenuation * 0.40
        )

        return AmbientCompensationTarget(
            activity: activity,
            levelDB: -attenuation,
            lowSupportDB: lowRestore,
            presenceSupportDB: -presenceCut,
            detailSupportDB: detailRestore,
            confidence: snapshot.separationConfidence,
            ambientDeltaDB: delta,
            holdReason: nil,
            mode: .conversationFocus,
            conversationEvidence: evidence,
            estimatedClearanceDB:
                attenuation + presenceCut
        )
    }

    func conversationEvidence(
        _ snapshot: AmbientAnalysisSnapshot
    ) -> Double {
        let speech = energyFraction(
            snapshot.spectrum,
            lowHz: 250,
            highHz: 4_000,
            denominatorLowHz: 100,
            denominatorHighHz: 12_000
        )
        let veryLow = energyFraction(
            snapshot.spectrum,
            lowHz: 20,
            highHz: 180,
            denominatorLowHz: 20,
            denominatorHighHz: 12_000
        )

        // Conversation usually concentrates substantial residual energy in the
        // speech band, varies over time, and is not dominated by one persistent
        // low-frequency periodic component. These are intentionally broad,
        // deterministic acoustic cues rather than semantic inference.
        let speechShape = clamp01(
            (speech - 0.32) / 0.48
        )
        let temporalVariation = clamp01(
            1.0
                - abs(snapshot.stationarityScore - 0.52)
                    / 0.52
        )
        let periodicPenalty =
            1.0 - 0.70 * clamp01(snapshot.periodicityScore)
        let lowFrequencyPenalty =
            1.0 - 0.75 * clamp01(veryLow)

        let strongestProminence =
            snapshot.tonalComponents
                .map(\.prominenceDB)
                .filter(\.isFinite)
                .max()
                ?? 0
        let tonalPenalty = 1.0 - 0.45 * clamp01(
            (strongestProminence - 10.0) / 18.0
        )

        return clamp01(
            speechShape
                * (0.55 + 0.45 * temporalVariation)
                * periodicPenalty
                * lowFrequencyPenalty
                * tonalPenalty
        )
    }

    private func held(
        _ reason: AmbientCompensationHoldReason,
        snapshot: AmbientAnalysisSnapshot
    ) -> AmbientCompensationTarget {
        AmbientCompensationTarget(
            activity: .quiet,
            levelDB: 0,
            lowSupportDB: 0,
            presenceSupportDB: 0,
            detailSupportDB: 0,
            confidence: min(
                max(snapshot.separationConfidence, 0),
                1
            ),
            ambientDeltaDB: 0,
            holdReason: reason,
            mode: .conversationFocus
        )
    }

    private func energyFraction(
        _ spectrum: [AmbientSpectrumBand],
        lowHz: Double,
        highHz: Double,
        denominatorLowHz: Double,
        denominatorHighHz: Double
    ) -> Double {
        var numerator = 0.0
        var denominator = 0.0
        for band in spectrum {
            guard band.centerFrequencyHz.isFinite,
                  band.levelDBFS.isFinite else { continue }
            let power = pow(10.0, band.levelDBFS / 10.0)
            guard power.isFinite else { continue }
            if band.centerFrequencyHz >= denominatorLowHz,
               band.centerFrequencyHz <= denominatorHighHz {
                denominator += power
            }
            if band.centerFrequencyHz >= lowHz,
               band.centerFrequencyHz <= highHz {
                numerator += power
            }
        }
        guard denominator > 1.0e-30 else { return 0 }
        return clamp01(numerator / denominator)
    }

    private func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// Stateful smoothing lives off the audio thread. The same time constants are
/// applied independently to each requested compensation dimension.
struct AmbientCompensationEnvelope: Equatable, Sendable {
    private(set) var current = AmbientCompensationTarget.unity
    private(set) var transientHoldRemainingSeconds = 0.0

    mutating func reset() {
        current = .unity
        transientHoldRemainingSeconds = 0
    }

    mutating func update(
        toward target: AmbientCompensationTarget,
        configuration rawConfiguration: AmbientCompensationConfiguration,
        elapsedSeconds: Double
    ) throws -> AmbientCompensationTarget {
        let configuration = try rawConfiguration.validated()
        guard elapsedSeconds.isFinite, elapsedSeconds >= 0 else {
            throw AmbientCompensationError.invalidConfiguration
        }

        if target.holdReason == .nonstationaryTransient {
            transientHoldRemainingSeconds = max(
                transientHoldRemainingSeconds,
                configuration.transientHoldSeconds
            )
        } else {
            transientHoldRemainingSeconds = max(
                transientHoldRemainingSeconds - elapsedSeconds,
                0
            )
        }

        let resolved: AmbientCompensationTarget
        if transientHoldRemainingSeconds > 0 {
            resolved = AmbientCompensationTarget(
                activity: current.activity,
                levelDB: 0,
                lowSupportDB: 0,
                presenceSupportDB: 0,
                detailSupportDB: 0,
                confidence: target.confidence,
                ambientDeltaDB: target.ambientDeltaDB,
                holdReason: .nonstationaryTransient
            )
        } else {
            resolved = target
        }

        let timing =
            resolved.mode == .conversationFocus
                ? configuration.effectiveConversationPreservation
                : ConversationPreservationConfiguration(
                    attackSeconds: configuration.attackSeconds,
                    releaseSeconds: configuration.releaseSeconds
                )

        current = AmbientCompensationTarget(
            activity: resolved.activity,
            levelDB: Self.smooth(
                current.levelDB,
                resolved.levelDB,
                elapsed: elapsedSeconds,
                rise: timing.attackSeconds,
                fall: timing.releaseSeconds
            ),
            lowSupportDB: Self.smooth(
                current.lowSupportDB,
                resolved.lowSupportDB,
                elapsed: elapsedSeconds,
                rise: timing.attackSeconds,
                fall: timing.releaseSeconds
            ),
            presenceSupportDB: Self.smooth(
                current.presenceSupportDB,
                resolved.presenceSupportDB,
                elapsed: elapsedSeconds,
                rise: timing.attackSeconds,
                fall: timing.releaseSeconds
            ),
            detailSupportDB: Self.smooth(
                current.detailSupportDB,
                resolved.detailSupportDB,
                elapsed: elapsedSeconds,
                rise: timing.attackSeconds,
                fall: timing.releaseSeconds
            ),
            confidence: resolved.confidence,
            ambientDeltaDB: resolved.ambientDeltaDB,
            holdReason: resolved.holdReason,
            mode: resolved.mode,
            conversationEvidence:
                resolved.conversationEvidence,
            estimatedClearanceDB:
                resolved.estimatedClearanceDB
        )
        return current
    }

    private static func smooth(
        _ current: Double,
        _ target: Double,
        elapsed: Double,
        rise: Double,
        fall: Double
    ) -> Double {
        guard elapsed > 0 else { return current }
        let increasingMagnitude =
            abs(target) > abs(current) + 0.000_001
        let timeConstant = increasingMagnitude ? rise : fall
        let alpha = 1 - exp(-elapsed / max(timeConstant, 0.001))
        return current + (target - current) * alpha
    }
}
