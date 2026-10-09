import Foundation

/// A diagnostic handoff verdict only. Neither a trusted-file signature nor
/// a positive timing reserve proves that ANC attenuates ambient noise.
enum QuietZoneCommissioningTimingVerdict: String, Sendable {
    case plausibleUnverified
    case insufficientMargin
    case nonCausal
}

struct QuietZoneCommissioningHandoffReport: Sendable {
    let signerKeyID: String
    let instrumentID: String
    let calibrationRecordID: String
    let sourceLaunchIDs: [String]
    let latencyStages: [QuietZonePhysicalLatencyEvidence]
    let timing: QuietZonePhysicalLatencyReport
    let checklist: QuietZoneCommissioningChecklist
    let verdict: QuietZoneCommissioningTimingVerdict
    let signatureVerified: Bool = true
    let physicallyCommissioned: Bool = false
    let acousticCancellationVerified: Bool = false
    let liveANCQualified: Bool = false

    /// Reviewable plain text for a user-selected file or diagnostics pane.
    /// Do not include raw microphone samples or private signing material.
    var reviewText: String {
        var lines = [
            "PR97 — Physical timing commissioning (diagnostic only)",
            "Instrument: \(instrumentID)",
            "Key: \(signerKeyID) · calibration record: \(calibrationRecordID)",
            "Signature: matches separately configured key; hardware not attested",
            "Survey launch IDs: \(sourceLaunchIDs.joined(separator: ", "))",
            "Timing verdict: \(verdict.rawValue)",
            String(format: "Conservative lead: %.3f ms",
                   timing.lowerBoundNoiseLeadSeconds * 1_000),
            String(format: "Nominal response path: %.3f ms",
                   timing.nominalPathSeconds * 1_000),
            String(format: "Worst-case response path: %.3f ms",
                   timing.upperBoundPathSeconds * 1_000),
            String(format: "Conservative reserve: %.3f ms",
                   timing.conservativeReserveSeconds * 1_000),
            String(format: "Reserve after required safety allowance: %.3f ms",
                   timing.spareAfterSafetyReserveSeconds * 1_000),
            "Physical hardware verified: NO",
            "Acoustic attenuation verified: NO",
            "Live ANC enabled: NO",
            "",
            "Commissioning gates:"
        ]
        for item in checklist.items {
            lines.append("• \(item.gate.title): \(item.status.caption)")
            lines.append("  \(item.explanation)")
        }
        lines.append("")
        lines.append(
            "Next: independently verify microphone/fixture clock, DAC and " +
            "speaker-to-seat timing, then measure cancellation, coherence " +
            "and stability on the actual playback hardware."
        )
        return lines.joined(separator: "\n")
    }
}

enum QuietZoneCommissioningHandoffError: Error, LocalizedError, Equatable {
    case incompletePhysicalSurvey
    case sourceLaunchMismatch
    case notARegularFile
    case unreadableFile
    case oversizedFile

    var errorDescription: String? {
        switch self {
        case .incompletePhysicalSurvey:
            return "Complete clock, electrical loopback and all three instrumented microphone placements first."
        case .sourceLaunchMismatch:
            return "The signed source launches do not match the three physical launches accepted by this session."
        case .notARegularFile:
            return "Select a regular local measurement evidence file."
        case .unreadableFile:
            return "The selected measurement file is unavailable or unreadable."
        case .oversizedFile:
            return "The selected measurement file exceeds the bounded evidence format."
        }
    }
}

/// A read-only, control-plane adapter for user-selected instrument files
/// and in-memory packets. No private keys, realtime callback, audio output,
/// calibration sidecar writes, or live ANC activation are involved.
struct QuietZoneCommissioningHandoffAdapter: Sendable {
    /// Called only off the realtime audio thread. The caller obtains file
    /// access via the usual sandbox user-selection/security scope.
    func inspectSelectedFile(
        at url: URL,
        trustedSigner: QuietZoneEvidenceTrustedSigner,
        session: QuietZoneHardwareCalibrationSession,
        currentOutput: QuietZoneHardwareHALClockAcquisition.Route?,
        plan: QuietZoneFeedForwardCalibration,
        project: RoomCorrectionProject,
        ledger: inout QuietZoneEvidenceImportLedger,
        now: Date = Date()
    ) throws -> QuietZoneCommissioningHandoffReport {
        guard url.isFileURL else {
            throw QuietZoneCommissioningHandoffError.notARegularFile
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw QuietZoneCommissioningHandoffError.unreadableFile
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw QuietZoneCommissioningHandoffError.notARegularFile
        }
        guard let length = attributes[.size] as? NSNumber,
              length.int64Value > 0,
              length.int64Value <= QuietZoneEvidenceHandoffVerifier
                .envelopeByteLimit else {
            throw QuietZoneCommissioningHandoffError.oversizedFile
        }
        let bytes: Data
        do { bytes = try Data(contentsOf: url) }
        catch { throw QuietZoneCommissioningHandoffError.unreadableFile }
        return try inspect(
            bytes, trustedSigner: trustedSigner, session: session,
            currentOutput: currentOutput, plan: plan, project: project,
            ledger: &ledger, now: now
        )
    }

    func inspect(
        _ bytes: Data,
        trustedSigner: QuietZoneEvidenceTrustedSigner,
        session: QuietZoneHardwareCalibrationSession,
        currentOutput: QuietZoneHardwareHALClockAcquisition.Route?,
        plan: QuietZoneFeedForwardCalibration,
        project: RoomCorrectionProject,
        ledger: inout QuietZoneEvidenceImportLedger,
        now: Date = Date()
    ) throws -> QuietZoneCommissioningHandoffReport {
        // Reject an ordinary, non-instrumented survey, even if a signed
        // external file claims to contain three independently launched probes.
        guard session.nextStep == .physicalReview,
              session.instrumentedSourceLaunchIDs.count == 3 else {
            throw QuietZoneCommissioningHandoffError.incompletePhysicalSurvey
        }

        // Stage the replay ledger. No failed downstream validation is allowed
        // to consume a valid package or leave partial accepted state behind.
        var pendingLedger = ledger
        let inspection = try QuietZoneEvidenceHandoffVerifier().inspect(
            bytes, trustedSigner: trustedSigner, session: session,
            currentOutput: currentOutput, ledger: &pendingLedger, now: now
        )
        guard inspection.sourceLaunchIDs == session.instrumentedSourceLaunchIDs
        else { throw QuietZoneCommissioningHandoffError.sourceLaunchMismatch }

        // Calls PR96 + PR97 analyzers on the actual in-memory A/B/A capture
        // and independently witnessed stage durations. A missing or invalid
        // project, clock, loopback, or listener-return causes a hard failure.
        let timing = try session.evaluateInstrumentedLatencyRun(
            inspection.measurementRun, plan: plan, project: project, now: now
        )
        let checklist = QuietZoneHardwareCommissioningEvaluator().assess(
            session: session, run: inspection.measurementRun,
            currentOutput: currentOutput, plan: plan, project: project,
            now: now
        )
        // Ensure the diagnostic view and strict analyzer agree. A signed
        // payload alone can never bypass the actual commissioning stages.
        guard checklist.item(.selectedOutput)?.status == .capturedUnverified,
              checklist.item(.halClocks)?.status == .capturedUnverified,
              checklist.item(.wiredLoopback)?.status == .capturedUnverified,
              checklist.item(.movableMicrophoneSurvey)?.status == .capturedUnverified,
              checklist.item(.causalBudget) != nil,
              checklist.item(.independentHardwareReview)?.status
                == .physicalVerificationRequired,
              checklist.item(.acousticAcceptance)?.status
                == .physicalVerificationRequired
        else { throw QuietZoneCommissioningHandoffError.incompletePhysicalSurvey }
        let verdict: QuietZoneCommissioningTimingVerdict
        switch timing.readiness {
        case .physicallyPlausible: verdict = .plausibleUnverified
        case .limitedMargin: verdict = .insufficientMargin
        case .nonCausal: verdict = .nonCausal
        default: throw QuietZoneCommissioningHandoffError.incompletePhysicalSurvey
        }
        let report = QuietZoneCommissioningHandoffReport(
            signerKeyID: inspection.signerKeyID,
            instrumentID: inspection.instrumentID,
            calibrationRecordID: inspection.calibrationRecordID,
            sourceLaunchIDs: inspection.sourceLaunchIDs,
            latencyStages: inspection.measuredStages,
            timing: timing, checklist: checklist, verdict: verdict
        )
        // Commit only after the entire signed + physically scoped diagnostic
        // inspection was successful, never when merely parsing a file.
        ledger = pendingLedger
        return report
    }
}
