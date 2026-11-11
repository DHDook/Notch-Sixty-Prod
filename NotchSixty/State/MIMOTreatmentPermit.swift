import Foundation

/// E19 S7, design note 7 and decision D3: the permit that lets `MIMOGraphTreatment` arm.
///
/// A permit is issued only when all of these hold, and each missing piece is a named refusal:
/// 1. the video latency input is wired and the mode is off (G30: until E19 S8 sets it, no permit);
/// 2. the staged design exists and its predicted decay passes, and the treated repeat measurement passes (decay and the PR75
///    spatial criteria), and the measurement agrees with the prediction (`MIMOTreatmentVerifier`);
/// 3. a hardware acceptance record for this configuration (PR75, unchanged) or a complete class qualification (D3);
/// 4. the fingerprint it binds is the controller's current one (taps hash, sources, support ranges, tau, output UID, rate family,
///    room-correction and downstream-chain digest, per-output trims, lane count); any change of those fields afterwards fails the
///    controller's fingerprint gate.
/// Until E22 fills the qualification table (`MIMOTreatmentQualificationRegistry.production`) and records acceptance, no permit
/// can be issued in production. Nothing here arms; the permit is read by the controller's gate.
enum MIMOVideoLatencyInput: Equatable, Sendable {
    /// Nothing has set it yet (the state until E19 S8 wires the latency mode). No permit is issued.
    case unknown
    case known(videoLatencyMode: Bool)
}

/// What D3 calls the configuration class: source count, rate family, routed or not, in-band ways per speaker.
struct MIMOTreatmentClassKey: Hashable, Sendable {
    var sourceCount: Int
    /// Decimation of the rate family: 16, 32, 64 or 128.
    var decimation: Int
    var routed: Bool
    /// In-band ways per speaker (1 when unrouted).
    var inBandWays: Int
}

struct MIMOTreatmentClassQualification: Equatable, Sendable {
    var key: MIMOTreatmentClassKey
    var qualifiedAt: Date
    var longRunThermalPassed: Bool
    var protectionChainPassed: Bool
    var stopStartPassed: Bool
    var unplugReplugPassed: Bool
    var sleepWakePassed: Bool
    var audibleArtifactCheckPassed: Bool

    var isComplete: Bool {
        longRunThermalPassed && protectionChainPassed && stopStartPassed && unplugReplugPassed && sleepWakePassed
            && audibleArtifactCheckPassed
    }
}

/// The class qualifications recorded on the bench. Hardware work is E22's: the production table is empty until it files records
/// there, so a product build cannot issue a permit before then.
struct MIMOTreatmentQualificationRegistry: Equatable, Sendable {
    var records: [MIMOTreatmentClassQualification]

    static let production = MIMOTreatmentQualificationRegistry(records: [])

    func qualification(for key: MIMOTreatmentClassKey) -> MIMOTreatmentClassQualification? {
        records.last { $0.key == key && $0.isComplete }
    }
}

enum MIMOTreatmentPermitRefusal: Error, Equatable, Sendable {
    case videoLatencyInputNotWired
    case videoLatencyMode
    case noStagedDesign
    case verificationFailed([MIMOTreatmentVerificationFailure])
    case hardwareAcceptanceRequired

    var reason: String {
        switch self {
        case .videoLatencyInputNotWired: return "Room treatment cannot be approved yet: the video latency setting is not available."
        case .videoLatencyMode: return "Room treatment is not available in video latency mode."
        case .noStagedDesign: return "No room treatment design is staged."
        case .verificationFailed(let failures): return failures.map(\.reason).joined(separator: " ")
        case .hardwareAcceptanceRequired:
            return "This configuration has no hardware acceptance record and no bench qualification; room treatment cannot be approved."
        }
    }
}

extension MIMOGraphTreatment {
    /// The class of the staged design, for the D3 qualification lookup.
    static func classKey(stage: UnifiedGraphMIMOStage, routed: Bool = false, inBandWays: Int = 1) -> MIMOTreatmentClassKey {
        MIMOTreatmentClassKey(
            sourceCount: stage.filters.sourceCount, decimation: stage.filters.decimation, routed: routed, inBandWays: inBandWays)
    }

    /// Issues a permit and stores it, or refuses with every blocking reason. Production wiring: the engine passes its own
    /// context and video latency input (`AudioIOEngine.issueMIMOTreatmentPermit`). Never arms.
    @discardableResult
    func issuePermit(
        context: Context,
        videoLatency: MIMOVideoLatencyInput,
        verification: MIMOTreatmentVerificationResult?,
        acceptance: MIMORoomTreatmentHardwareAcceptance?,
        registry: MIMOTreatmentQualificationRegistry = .production,
        routed: Bool = false,
        inBandWays: Int = 1,
        issuedAt: Date = Date()
    ) -> Result<Permit, MIMOTreatmentPermitRefusal> {
        func refuse(_ refusal: MIMOTreatmentPermitRefusal) -> Result<Permit, MIMOTreatmentPermitRefusal> {
            setPermit(nil)
            return .failure(refusal)
        }
        switch videoLatency {
        case .unknown: return refuse(.videoLatencyInputNotWired)
        case .known(let mode): if mode || context.videoLatencyMode { return refuse(.videoLatencyMode) }
        }
        guard let stage else { return refuse(.noStagedDesign) }
        guard let verification else { return refuse(.verificationFailed([.spatialReportMissing, .repeatMeasurementMissing])) }
        var failures = verification.failures
        if !verification.includesRepeatMeasurement, !failures.contains(.repeatMeasurementMissing) {
            failures.append(.repeatMeasurementMissing)
        }
        if !failures.isEmpty { return refuse(.verificationFailed(failures)) }

        let key = Self.classKey(stage: stage, routed: routed, inBandWays: inBandWays)
        let accepted = acceptance.map {
            $0.isComplete && $0.sourceCount == stage.filters.sourceCount && abs($0.sampleRate - stage.filters.sampleRate) < 0.5
        } ?? false
        let qualified = registry.qualification(for: key) != nil
        guard accepted || qualified else { return refuse(.hardwareAcceptanceRequired) }

        let permit = Permit(fingerprint: currentFingerprint(stage, context), issuedAt: issuedAt, basis: accepted ? .hardwareAcceptance : .classQualification)
        setPermit(permit)
        return .success(permit)
    }
}
