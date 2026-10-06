import Foundation

struct MIMORoomTreatmentActivationPermit: Equatable, Sendable {
    let issuedAt: Date
    let hardwareConfirmedAt: Date
    let sampleRate: Double
    let sources: [MultichannelCalibrationSource]
    let tapCount: Int
    let declaredLatencyFrames: Int
    let engineLatencyFrames: Int
    let totalLatencyFrames: Int
    let verifiedSpatialRMSErrorImprovementDB: Double

    private init(
        issuedAt: Date,
        hardwareConfirmedAt: Date,
        sampleRate: Double,
        sources: [MultichannelCalibrationSource],
        tapCount: Int,
        declaredLatencyFrames: Int,
        engineLatencyFrames: Int,
        totalLatencyFrames: Int,
        verifiedSpatialRMSErrorImprovementDB: Double
    ) {
        self.issuedAt = issuedAt
        self.hardwareConfirmedAt = hardwareConfirmedAt
        self.sampleRate = sampleRate
        self.sources = sources
        self.tapCount = tapCount
        self.declaredLatencyFrames = declaredLatencyFrames
        self.engineLatencyFrames = engineLatencyFrames
        self.totalLatencyFrames = totalLatencyFrames
        self.verifiedSpatialRMSErrorImprovementDB =
            verifiedSpatialRMSErrorImprovementDB
    }

    /// The only product-side permit factory.
    ///
    /// A permit is a control-plane proof object only. It does not arm a runtime,
    /// publish a graph, start Core Audio or write to physical outputs.
    static func make(
        firProgram: MIMORoomTreatmentFIRProgram,
        sourceSafety: [MIMORoomTreatmentSourceSafetyDeclaration],
        verification: MIMORoomTreatmentVerificationReport?,
        hardwareAcceptance: MIMORoomTreatmentHardwareAcceptance?,
        issuedAt: Date = Date()
    ) -> MIMORoomTreatmentActivationPermit? {
        guard firProgram.sampleRate.isFinite,
              firProgram.sampleRate > 0,
              !firProgram.sources.isEmpty,
              firProgram.sources.count <= Int(N60_MIMO_FIR_MAX_CHANNELS),
              firProgram.tapCount > 0,
              firProgram.taps.count
                == firProgram.sources.count
                    * firProgram.sources.count
                    * firProgram.tapCount,
              firProgram.declaredLatencyFrames >= 0,
              firProgram.engineLatencyFrames > 0,
              firProgram.totalLatencyFrames
                == firProgram.declaredLatencyFrames
                    + firProgram.engineLatencyFrames else {
            return nil
        }

        let gate = MIMORoomTreatmentDeploymentGate().evaluate(
            firProgram: firProgram,
            sourceSafety: sourceSafety,
            verification: verification,
            hardwareAcceptance: hardwareAcceptance
        )
        guard gate.status == .eligibleForFutureLiveIntegration,
              gate.blockingReasons.isEmpty,
              let verification,
              verification.accepted,
              verification.sources == firProgram.sources,
              abs(verification.sampleRate - firProgram.sampleRate) < 0.5,
              let hardwareAcceptance,
              hardwareAcceptance.isComplete,
              hardwareAcceptance.sourceCount == firProgram.sources.count,
              abs(hardwareAcceptance.sampleRate - firProgram.sampleRate) < 0.5 else {
            return nil
        }

        return MIMORoomTreatmentActivationPermit(
            issuedAt: issuedAt,
            hardwareConfirmedAt: hardwareAcceptance.confirmedAt,
            sampleRate: firProgram.sampleRate,
            sources: firProgram.sources,
            tapCount: firProgram.tapCount,
            declaredLatencyFrames: firProgram.declaredLatencyFrames,
            engineLatencyFrames: firProgram.engineLatencyFrames,
            totalLatencyFrames: firProgram.totalLatencyFrames,
            verifiedSpatialRMSErrorImprovementDB:
                verification.spatialRMSErrorImprovementDB
        )
    }
}

struct MIMORoomTreatmentTransitionConfiguration: Equatable, Sendable {
    var armFadeMilliseconds = 40.0
    var faultFadeMilliseconds = 10.0

    static let conservative = MIMORoomTreatmentTransitionConfiguration()

    func frameCounts(
        sampleRate: Double
    ) -> (armFadeFrames: UInt32, faultFadeFrames: UInt32)? {
        guard sampleRate.isFinite,
              sampleRate > 0,
              armFadeMilliseconds.isFinite,
              armFadeMilliseconds > 0,
              faultFadeMilliseconds.isFinite,
              faultFadeMilliseconds > 0 else {
            return nil
        }

        let arm = armFadeMilliseconds * sampleRate / 1_000.0
        let fault = faultFadeMilliseconds * sampleRate / 1_000.0
        guard arm.isFinite,
              fault.isFinite,
              arm >= 1,
              fault >= 1,
              arm <= Double(N60_MIMO_TREATMENT_MAX_TRANSITION_FRAMES),
              fault <= Double(N60_MIMO_TREATMENT_MAX_TRANSITION_FRAMES) else {
            return nil
        }
        return (
            UInt32(arm.rounded()),
            UInt32(fault.rounded())
        )
    }
}

enum MIMORoomTreatmentTransitionPreparationError:
    Error, Equatable, LocalizedError
{
    case permitMismatch
    case invalidFadeConfiguration
    case programAllocationFailed
    case transitionAllocationFailed

    var errorDescription: String? {
        switch self {
        case .permitMismatch:
            return "Room-treatment activation permit does not match the compiled FIR program."
        case .invalidFadeConfiguration:
            return "Room-treatment arm/fault fade configuration is invalid."
        case .programAllocationFailed:
            return "Room-treatment FIR program could not be prepared."
        case .transitionAllocationFailed:
            return "Room-treatment transition runtime could not be prepared."
        }
    }
}

/// Test/control-plane owner for PR76's standalone transition runtime.
///
/// This object is intentionally not referenced by AudioIOEngine or the live
/// N-channel render graph. A later hardware-gated integration PR may reuse the
/// same preparation contract after physical acceptance.
final class MIMORoomTreatmentPreparedTransition {
    private let cProgram: UnsafeMutablePointer<N60MIMOFIRProgram>
    private let cRuntime: UnsafeMutablePointer<N60MIMOTreatmentTransitionRuntime>

    let permit: MIMORoomTreatmentActivationPermit

    init(
        firProgram: MIMORoomTreatmentFIRProgram,
        permit: MIMORoomTreatmentActivationPermit,
        configuration: MIMORoomTreatmentTransitionConfiguration = .conservative
    ) throws {
        guard permit.sampleRate == firProgram.sampleRate,
              permit.sources == firProgram.sources,
              permit.tapCount == firProgram.tapCount,
              permit.declaredLatencyFrames == firProgram.declaredLatencyFrames,
              permit.engineLatencyFrames == firProgram.engineLatencyFrames,
              permit.totalLatencyFrames == firProgram.totalLatencyFrames else {
            throw MIMORoomTreatmentTransitionPreparationError.permitMismatch
        }
        guard let fades = configuration.frameCounts(
            sampleRate: firProgram.sampleRate
        ) else {
            throw MIMORoomTreatmentTransitionPreparationError
                .invalidFadeConfiguration
        }

        var taps = firProgram.taps
        guard let prepared = taps.withUnsafeBufferPointer({ buffer in
            N60MIMOFIRProgramCreate(
                UInt32(firProgram.sources.count),
                buffer.baseAddress!,
                UInt32(firProgram.tapCount),
                UInt32(firProgram.declaredLatencyFrames)
            )
        }) else {
            throw MIMORoomTreatmentTransitionPreparationError
                .programAllocationFailed
        }

        guard let transition = N60MIMOTreatmentTransitionRuntimeCreate(
            prepared,
            fades.armFadeFrames,
            fades.faultFadeFrames
        ) else {
            N60MIMOFIRProgramDestroy(prepared)
            throw MIMORoomTreatmentTransitionPreparationError
                .transitionAllocationFailed
        }

        cProgram = prepared
        cRuntime = transition
        self.permit = permit

        // Authorization is granted only because construction required a permit
        // created from the complete PR75 gate.
        N60MIMOTreatmentTransitionSetAuthorized(cRuntime, true)
    }

    deinit {
        N60MIMOTreatmentTransitionRuntimeDestroy(cRuntime)
        N60MIMOFIRProgramDestroy(cProgram)
    }

    var snapshot: N60MIMOTreatmentTransitionSnapshot {
        N60MIMOTreatmentTransitionGetSnapshot(cRuntime)
    }

    /// Standalone validation surface only. This does not connect to Core Audio.
    func requestArm() -> Bool {
        N60MIMOTreatmentTransitionRequestArm(cRuntime)
    }

    func requestBypass() {
        N60MIMOTreatmentTransitionRequestBypass(cRuntime)
    }

    func latchFault(_ fault: N60MIMOTreatmentFault) -> Bool {
        N60MIMOTreatmentTransitionLatchFault(cRuntime, fault)
    }

    func requestFaultClear() {
        N60MIMOTreatmentTransitionRequestFaultClear(cRuntime)
    }

    func revokeAuthorization() {
        N60MIMOTreatmentTransitionSetAuthorized(cRuntime, false)
    }

    func processStandaloneFrame(
        input: [Float]
    ) -> [Float]? {
        guard input.count == permit.sources.count else { return nil }
        var output = [Float](repeating: 0, count: input.count)
        let success = input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                N60MIMOTreatmentTransitionProcessFrame(
                    cRuntime,
                    inputBuffer.baseAddress!,
                    outputBuffer.baseAddress!
                )
            }
        }
        return success ? output : nil
    }
}
