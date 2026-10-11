import SwiftUI


enum ActiveAcousticsCommissioningUXState: Equatable {
    case calibrationRequired
    case timingUnqualified
    case timingPlausibleHardwareRequired

    var title: String {
        switch self {
        case .calibrationRequired:
            return "Calibration required"
        case .timingUnqualified:
            return "Timing diagnostics incomplete"
        case .timingPlausibleHardwareRequired:
            return "Timing plausible · hardware verification required"
        }
    }
}

struct ActiveAcousticsCommissioningUXSnapshot: Equatable {
    let calibrationPlanned: Bool
    let timingReadiness: QuietZoneFeedForwardReadiness

    var state: ActiveAcousticsCommissioningUXState {
        guard calibrationPlanned else {
            return .calibrationRequired
        }
        guard timingReadiness == .physicallyPlausible else {
            return .timingUnqualified
        }
        return .timingPlausibleHardwareRequired
    }

    var timingCaption: String {
        switch timingReadiness {
        case .missingMeasurements:
            return "MEASUREMENTS REQUIRED"
        case .invalidTimebase:
            return "CLOCK UNQUALIFIED"
        case .unreliableMeasurements:
            return "MEASUREMENT QUALITY HOLD"
        case .nonCausal:
            return "NON-CAUSAL"
        case .limitedMargin:
            return "MARGIN TOO SMALL"
        case .physicallyPlausible:
            return "DIAGNOSTIC PASS"
        }
    }

    // PR100 must never transform remote/synthetic diagnostics into physical
    // authorization. These remain explicit UX facts until later hardware work.
    let instrumentEvidenceAuthenticated = false
    let physicalAttenuationVerified = false
    let emergencyMuteHardwareVerified = false
    let liveANCOutputAuthorized = false

    var nextAction: String {
        switch state {
        case .calibrationRequired:
            return "Prepare the one-microphone plan, then capture the listener → upstream → listener timing survey on the physical system."
        case .timingUnqualified:
            return "Complete or correct the hardware timing survey until causality and reserve diagnostics are trustworthy."
        case .timingPlausibleHardwareRequired:
            return "Run the PR99 A/B/A acoustic campaign, independent instrument review, and real emergency-shutdown verification before any live ANC authorization."
        }
    }
}



enum ActiveAcousticsDiagnosticDisposition: String, Equatable {
    case recorded = "RECORDED"
    case diagnosticPass = "DIAGNOSTIC PASS"
    case attention = "ATTENTION"
    case blocked = "BLOCKED"
    case hardwareRequired = "HARDWARE REQUIRED"
    case disconnected = "DISCONNECTED"
}

struct ActiveAcousticsDiagnosticUXItem: Identifiable, Equatable {
    let id: String
    let title: String
    let disposition: ActiveAcousticsDiagnosticDisposition
    let detail: String
}

struct ActiveAcousticsDiagnosticsUXSnapshot: Equatable {
    let items: [ActiveAcousticsDiagnosticUXItem]

    init(
        calibration: QuietZoneFeedForwardCalibration?,
        budget: QuietZoneFeedForwardBudget
    ) {
        let requiredPositions: [QuietZoneFeedForwardPosition] = [
            .listenerFirst, .upstream, .listenerReturn
        ]
        let positions = calibration?.arrivals.map(\.position) ?? []
        let surveyComplete = positions == requiredPositions
        let clockPresent = calibration?.halClockTrace != nil
        let timingPresent = calibration?.timingPath != nil

        let causalityDisposition: ActiveAcousticsDiagnosticDisposition
        let causalityDetail: String
        switch budget.readiness {
        case .physicallyPlausible:
            causalityDisposition = .diagnosticPass
            causalityDetail =
                "The conservative timing reserve is positive. This is timing plausibility only."
        case .limitedMargin:
            causalityDisposition = .attention
            causalityDetail =
                "A positive reserve exists but is below the required safety margin."
        case .nonCausal:
            causalityDisposition = .blocked
            causalityDetail =
                "The anti-noise path cannot reliably beat the disturbance to the listener."
        case .invalidTimebase:
            causalityDisposition = .blocked
            causalityDetail =
                "The input/output timebase is not trustworthy enough for causal scheduling."
        case .unreliableMeasurements:
            causalityDisposition = .blocked
            causalityDetail =
                "Measurement quality or repeatability is insufficient."
        case .missingMeasurements:
            causalityDisposition = .blocked
            causalityDetail =
                "The physical timing survey is incomplete."
        }

        items = [
            .init(
                id: "plan",
                title: "One-microphone plan",
                disposition: calibration == nil ? .blocked : .recorded,
                detail: calibration == nil
                    ? "Prepare the listener/upstream geometry before commissioning."
                    : "A software calibration record exists; physical provenance is not authenticated."
            ),
            .init(
                id: "aba",
                title: "Listener → upstream → listener survey",
                disposition: surveyComplete ? .recorded : .blocked,
                detail: surveyComplete
                    ? "All three timing positions are recorded in the expected order."
                    : "Three trigger-synchronized position records are required."
            ),
            .init(
                id: "clock",
                title: "Concurrent HAL clock evidence",
                disposition: clockPresent ? .recorded : .blocked,
                detail: clockPresent
                    ? "A clock trace is present for analysis; presence alone is not instrument attestation."
                    : "Input/output clock observations are still required."
            ),
            .init(
                id: "path",
                title: "Physical latency path",
                disposition: timingPresent ? .recorded : .blocked,
                detail: timingPresent
                    ? "ADC, processing and command-to-seat latency fields are present."
                    : "Independent reference ADC, processing, DAC and speaker-to-seat timing is required."
            ),
            .init(
                id: "causality",
                title: "Causality reserve",
                disposition: causalityDisposition,
                detail: causalityDetail
            ),
            .init(
                id: "acoustic",
                title: "PR99 A/B/A acoustic verification",
                disposition: .hardwareRequired,
                detail: "Requires real calibrated seat measurements, repeatability and independently reviewed evidence."
            ),
            .init(
                id: "mute",
                title: "Emergency shutdown verification",
                disposition: .hardwareRequired,
                detail: "Requires externally measured real output mute/fade behavior for all required fault classes."
            ),
            .init(
                id: "output",
                title: "Live feed-forward speaker output",
                disposition: .disconnected,
                detail: "PR100 exposes no arm, authorization or speaker-output connection."
            ),
        ]
    }

    var unresolvedCount: Int {
        items.filter {
            $0.disposition == .blocked
                || $0.disposition == .attention
                || $0.disposition == .hardwareRequired
                || $0.disposition == .disconnected
        }.count
    }

    var headline: String {
        if items.contains(where: { $0.disposition == .blocked }) {
            return "Commissioning has unresolved software or measurement blockers"
        }
        return "Remote diagnostics complete · physical verification still required"
    }
}



struct ActiveAcousticsPhysicalCampaignUXVisit: Identifiable, Equatable {
    let id: Int
    let positionLabel: String
    let role: String
    let instruction: String
    let sourceCaptureCount: Int
    let faultWitnessCount: Int
}

struct ActiveAcousticsPhysicalCampaignUXSnapshot: Equatable {
    let visits: [ActiveAcousticsPhysicalCampaignUXVisit] = [
        .init(
            id: 1,
            positionLabel: "A",
            role: "Primary listener",
            instruction: "Run a complete independent OFF → TEST → OFF measurement at the primary listening position.",
            sourceCaptureCount: 3,
            faultWitnessCount: 5
        ),
        .init(
            id: 2,
            positionLabel: "B",
            role: "Neighbor / observer",
            instruction: "Move the same microphone to the neighboring position and repeat the complete independent measurement.",
            sourceCaptureCount: 3,
            faultWitnessCount: 5
        ),
        .init(
            id: 3,
            positionLabel: "A",
            role: "Primary listener return",
            instruction: "Return the same microphone to the original primary position and repeat to expose geometry or timebase drift.",
            sourceCaptureCount: 3,
            faultWitnessCount: 5
        ),
    ]

    var totalSourceCaptures: Int {
        visits.reduce(0) { $0 + $1.sourceCaptureCount }
    }

    var totalFaultWitnesses: Int {
        visits.reduce(0) { $0 + $1.faultWitnessCount }
    }

    let physicalVerificationComplete = false
    let instrumentProvenanceAuthenticated = false
    let liveOutputAuthorized = false
}



struct ActiveAcousticsEvidenceCurvePoint: Identifiable, Equatable {
    let frequencyHz: Double
    let primaryFirstReductionDB: Double
    let neighboringSeatReductionDB: Double
    let primaryReturnReductionDB: Double
    let worstObservedReductionDB: Double

    var id: Double { frequencyHz }
}

enum ActiveAcousticsPhysicalEvidenceUXState: Equatable {
    case awaitingCampaign
    case invalidPackage
    case numericalEvidenceAvailable
    case roleReviewAcknowledged

    var caption: String {
        switch self {
        case .awaitingCampaign:
            return "AWAITING PHYSICAL CAMPAIGN"
        case .invalidPackage:
            return "EVIDENCE INTEGRITY FAILED"
        case .numericalEvidenceAvailable:
            return "NUMERICAL EVIDENCE · UNAUTHENTICATED"
        case .roleReviewAcknowledged:
            return "TWO-ROLE REVIEW · STILL UNAUTHENTICATED"
        }
    }
}

struct ActiveAcousticsPhysicalEvidenceUXSnapshot: Equatable {
    let state: ActiveAcousticsPhysicalEvidenceUXState
    let initialPrimaryReductionDB: Double?
    let neighboringSeatReductionDB: Double?
    let returningPrimaryReductionDB: Double?
    let worstFrequencyReductionDB: Double?
    let primaryRepeatDifferenceDB: Double?
    let maximumBandRepeatDifferenceDB: Double?
    let largestPrimaryBaselineDifferenceDB: Double?
    let curvePoints: [ActiveAcousticsEvidenceCurvePoint]
    let digestPrefix: String?
    let digestIntegrityVerified: Bool
    let independentRolesAcknowledged: Bool

    let instrumentEvidenceAuthenticated = false
    let physicalAttenuationVerified = false
    let emergencyMuteHardwareVerified = false
    let liveOutputAuthorized = false

    init(
        package: QuietZonePhysicalEvidencePackage?,
        reviewPacket: QuietZoneExternalReviewPacket?
    ) {
        guard let package else {
            state = .awaitingCampaign
            initialPrimaryReductionDB = nil
            neighboringSeatReductionDB = nil
            returningPrimaryReductionDB = nil
            worstFrequencyReductionDB = nil
            primaryRepeatDifferenceDB = nil
            maximumBandRepeatDifferenceDB = nil
            largestPrimaryBaselineDifferenceDB = nil
            curvePoints = []
            digestPrefix = nil
            digestIntegrityVerified = false
            independentRolesAcknowledged = false
            return
        }

        let verified =
            (try? QuietZonePhysicalSpectralEvidenceAnalyzer().verifyDigest(
                canonicalJSON: package.canonicalJSON,
                expectedSHA256Hex: package.sha256Hex
            )) == true
        let reviewed =
            verified
            && reviewPacket?.evidenceSHA256Hex == package.sha256Hex
            && reviewPacket?.numericalAcceptance == true
            && reviewPacket?.independentRolesAcknowledged == true

        state =
            !verified
                ? .invalidPackage
                : reviewed
                    ? .roleReviewAcknowledged
                    : .numericalEvidenceAvailable
        initialPrimaryReductionDB =
            package.campaignReview.firstPrimaryReductionDB
        neighboringSeatReductionDB =
            package.campaignReview.neighboringSeatReductionDB
        returningPrimaryReductionDB =
            package.campaignReview.returningPrimaryReductionDB
        worstFrequencyReductionDB = package.worstFrequencyReductionDB
        primaryRepeatDifferenceDB =
            package.campaignReview.primaryReductionRepeatDifferenceDB
        maximumBandRepeatDifferenceDB =
            package.maximumPrimaryBandRepeatDifferenceDB
        largestPrimaryBaselineDifferenceDB =
            package.campaignReview.largestPrimaryBaselineDifferenceDB
        curvePoints = package.frequencyResults.map {
            .init(
                frequencyHz: $0.frequencyHz,
                primaryFirstReductionDB: $0.primaryFirstReductionDB,
                neighboringSeatReductionDB: $0.neighboringSeatReductionDB,
                primaryReturnReductionDB: $0.primaryReturnReductionDB,
                worstObservedReductionDB: $0.worstObservedReductionDB
            )
        }
        digestPrefix = String(package.sha256Hex.prefix(12))
        digestIntegrityVerified = verified
        independentRolesAcknowledged = reviewed
    }
}

private struct ActiveAcousticsEvidenceReductionCurveView: View {
    let points: [ActiveAcousticsEvidenceCurvePoint]

    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                guard !points.isEmpty else { return }
                let plot = CGRect(
                    x: 42,
                    y: 10,
                    width: max(size.width - 52, 1),
                    height: max(size.height - 30, 1)
                )
                let allValues = points.flatMap {
                    [
                        $0.primaryFirstReductionDB,
                        $0.neighboringSeatReductionDB,
                        $0.primaryReturnReductionDB,
                    ]
                }
                let minimum = min(-1.0, floor((allValues.min() ?? 0) - 0.5))
                let maximum = max(2.0, ceil((allValues.max() ?? 1) + 0.5))
                let range = max(maximum - minimum, 0.001)

                func x(_ frequency: Double) -> CGFloat {
                    let low = log(20.0)
                    let high = log(150.0)
                    let clamped = min(max(frequency, 20), 150)
                    let fraction = (log(clamped) - low) / (high - low)
                    return plot.minX + plot.width * CGFloat(fraction)
                }

                func y(_ value: Double) -> CGFloat {
                    let fraction = (value - minimum) / range
                    return plot.maxY - plot.height * CGFloat(fraction)
                }

                for gain in stride(
                    from: ceil(minimum),
                    through: floor(maximum),
                    by: 1.0
                ) {
                    var line = Path()
                    line.move(to: CGPoint(x: plot.minX, y: y(gain)))
                    line.addLine(to: CGPoint(x: plot.maxX, y: y(gain)))
                    context.stroke(
                        line,
                        with: .color(
                            Color.secondary.opacity(
                                abs(gain) < 0.001 ? 0.35 : 0.12
                            )
                        ),
                        lineWidth: abs(gain) < 0.001 ? 1.25 : 1
                    )
                }

                for frequency in [20.0, 40, 80, 150] {
                    let position = x(frequency)
                    var line = Path()
                    line.move(to: CGPoint(x: position, y: plot.minY))
                    line.addLine(to: CGPoint(x: position, y: plot.maxY))
                    context.stroke(
                        line,
                        with: .color(Color.secondary.opacity(0.10)),
                        lineWidth: 1
                    )
                    context.draw(
                        Text("\(Int(frequency))")
                            .font(.caption2)
                            .foregroundStyle(.secondary),
                        at: CGPoint(x: position, y: plot.maxY + 11),
                        anchor: .center
                    )
                }

                func draw(
                    _ value: (ActiveAcousticsEvidenceCurvePoint) -> Double,
                    style: Color,
                    width: CGFloat
                ) {
                    var path = Path()
                    for (index, point) in points.enumerated() {
                        let position = CGPoint(
                            x: x(point.frequencyHz),
                            y: y(value(point))
                        )
                        if index == 0 {
                            path.move(to: position)
                        } else {
                            path.addLine(to: position)
                        }
                    }
                    context.stroke(
                        path,
                        with: .color(style),
                        lineWidth: width
                    )
                }

                draw(
                    { $0.primaryFirstReductionDB },
                    style: Color.accentColor,
                    width: 2
                )
                draw(
                    { $0.neighboringSeatReductionDB },
                    style: Color.secondary,
                    width: 1.5
                )
                draw(
                    { $0.primaryReturnReductionDB },
                    style: Color.green,
                    width: 2
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Physical verification frequency reduction curve")
        .accessibilityValue(
            points.isEmpty
                ? "No physical evidence available"
                : "\(points.count) measured frequency bins from 20 to 150 hertz"
        )
    }
}

/// PR96 uses the familiar Quiet Zone workspace but deliberately does not
/// expose an Arm switch until the reference-to-speaker path is proven causal.
struct ProductionFeedForwardReadinessCard: View {
    @ObservedObject var quietZone: ActiveQuietZoneController
    let physicalEvidence: QuietZonePhysicalEvidencePackage?
    let independentReview: QuietZoneExternalReviewPacket?

    init(
        quietZone: ActiveQuietZoneController,
        physicalEvidence: QuietZonePhysicalEvidencePackage? = nil,
        independentReview: QuietZoneExternalReviewPacket? = nil
    ) {
        _quietZone = ObservedObject(wrappedValue: quietZone)
        self.physicalEvidence = physicalEvidence
        self.independentReview = independentReview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Virtual-Position Feed-Forward ANC")
                        .font(.headline)
                    Text(
                        "One microphone, two locations: virtual listening-seat error point and upstream doorway reference."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("PR97 · HARDWARE SETUP")
                    .font(.caption.bold())
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    do {
                        try quietZone.prepareFeedForwardPlan()
                    } catch {
                        // Controller publishes the same prerequisites in refresh.
                        quietZone.refreshFeedForwardCalibration()
                    }
                } label: {
                    Label(
                        "Prepare One-Mic Plan",
                        systemImage: "mic"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(
                    quietZone.feedForwardCalibration != nil
                )

                Button {
                    quietZone.refreshFeedForwardCalibration()
                } label: {
                    Label(
                        "Refresh",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                Spacer()
                Text(
                    quietZone.feedForwardCalibration == nil
                        ? "NO CALIBRATION"
                        : "CALIBRATION PLANNED"
                )
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            }

            commissioningSummary
            oneMicrophoneSetupProgress
            consolidatedDiagnostics
            physicalCampaignPlan
            physicalEvidenceVisualization

            VStack(alignment: .leading, spacing: 7) {
                stage(
                    1,
                    "Listener: establish speaker → virtual-seat path and synchronized controlled-source arrival."
                )
                stage(
                    2,
                    "Doorway: move the same mic upstream; repeat the controlled source with the same trigger/clock reference."
                )
                stage(
                    3,
                    "Listener: return to check source/timebase drift. Independently measure reference acquisition, processing and anti-noise speaker latency."
                )
                stage(
                    4,
                    "Leave mic upstream only after confidence, causality, model accuracy and hardware verification gates pass."
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Instrumented calibration stages").font(.caption.bold())
                Text("1. Qualify concurrent input and output HAL clocks")
                Text("2. Repeat at least three wired electrical loopbacks")
                Text("3. Capture listener → upstream doorway → listener return")
                Text("4. Measure physical speaker-to-seat latency before considering ANC")
                Text("The automated hardware capture driver is not connected; no live anti-noise output is permitted.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)

            let commissioning = QuietZoneHardwareCommissioningEvaluator()
                .preview(calibration: quietZone.feedForwardCalibration)
            VStack(alignment: .leading, spacing: 6) {
                Text("Hardware commissioning checklist")
                    .font(.caption.bold())
                ForEach(commissioning.items) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.gate.title)
                        Spacer(minLength: 8)
                        Text(item.status.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.caption2)
                }
                Text("Saved calibration data cannot certify physical source clocks, independent endpoint instrumentation, or measured attenuation. Live feed-forward ANC is disconnected.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let calibration = quietZone.feedForwardCalibration {
                HStack {
                    Text("Upstream reference")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(calibration.upstreamLabel)
                }
                .font(.caption)

                HStack {
                    Text("Timed captures")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(
                        "\(calibration.arrivals.count) / 3"
                    )
                    .monospacedDigit()
                }
                .font(.caption)
            }

            if let trace = quietZone.feedForwardCalibration?.halClockTrace {
                if let clock = try? QuietZoneHALClockAnalyzer().analyze(trace) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            "HAL clock stability: qualified for loopback bench only",
                            systemImage: "clock"
                        )
                        .font(.caption.bold())
                        Text(
                            String(
                                format:
                                    "Input %.2f Hz · Output %.2f Hz · relative drift %.1f ppm · worst timestamp residual %.3f ms",
                                clock.measuredInputRateHz,
                                clock.measuredOutputRateHz,
                                clock.relativeDriftPPM,
                                1000 * max(
                                    clock.worstInputResidualSeconds,
                                    clock.worstOutputResidualSeconds
                                )
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(
                            "Clock stability is not ADC/DAC latency or proof of live cancellation."
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Label(
                        "HAL clock observations failed qualification. Re-capture timing evidence.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if quietZone.feedForwardBudget.acousticPreviewSeconds != nil {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ],
                    spacing: 10
                ) {
                    valueCard(
                        "Measured preview",
                        milliseconds(
                            quietZone.feedForwardBudget.acousticPreviewSeconds
                        ),
                        "Source→listener minus source→upstream; before uncertainty."
                    )
                    valueCard(
                        "Conservative preview",
                        milliseconds(
                            quietZone.feedForwardBudget.conservativePreviewSeconds
                        ),
                        "Lower confidence bound, including repeat drift."
                    )
                    valueCard(
                        "Anti-noise path",
                        milliseconds(
                            quietZone.feedForwardBudget.antiNoisePathSeconds
                        ),
                        "Actual reference ADC + DSP + output-to-seat travel."
                    )
                    valueCard(
                        "Causality reserve",
                        milliseconds(
                            quietZone.feedForwardBudget.conservativeReserveSeconds
                        ),
                        "Conservative preview minus measured path and jitter."
                    )
                }
            }

            if let timing = quietZone.feedForwardCalibration?.timingPath {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Timing path breakdown · diagnostic only")
                        .font(.caption.bold())
                    HStack {
                        Text("Reference ADC / acquisition")
                        Spacer()
                        Text(milliseconds(timing.referenceAcquisitionSeconds))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Reference processing / scheduling")
                        Spacer()
                        Text(milliseconds(timing.referenceProcessingSeconds))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("DAC + speaker-to-seat (combined)")
                        Spacer()
                        Text(milliseconds(timing.commandToSeatSeconds))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Worst-case jitter + 3σ clock allowance")
                        Spacer()
                        Text(milliseconds(
                            timing.totalWorstCaseJitterSeconds
                                + 3 * timing.timingUncertaintySeconds
                        )).monospacedDigit()
                    }
                    Text("Component bounds require separately instrumented hardware evidence. Cable loopback cannot determine acoustic propagation. Positive timing reserve does not establish any frequency-specific attenuation or permit live ANC.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Label(
                readinessTitle,
                systemImage: "waveform.path.ecg.rectangle"
            )
            .font(.callout.bold())
            .foregroundStyle(.secondary)

            Text(quietZone.feedForwardMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "Feed-forward remains unarmed: the PR90 250 ms polling/window analysis is not causal for unpredictable noise. A trigger-synchronized physical calibration, low-latency reference-to-speaker transport and re-measurement at the virtual seat are required. No estimated cancellation dB or broadband frequency range is claimed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .padding(18)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 18)
        )
    }




    private var physicalEvidenceVisualization: some View {
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: physicalEvidence,
            reviewPacket: independentReview
        )

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Physical Evidence")
                        .font(.subheadline.bold())
                    Text(snapshot.state.caption)
                        .font(.caption)
                        .foregroundStyle(
                            snapshot.state == .invalidPackage
                                ? .red
                                : .secondary
                        )
                }
                Spacer()
                if let digest = snapshot.digestPrefix {
                    Text("SHA-256 " + digest + "…")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if snapshot.curvePoints.isEmpty {
                Text(
                    "No PR99 physical evidence package is attached. This view will remain empty until the real A → B → A campaign is captured and compiled."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ],
                    spacing: 8
                ) {
                    evidenceMetric(
                        "Primary A",
                        decibels(snapshot.initialPrimaryReductionDB),
                        "Integrated first primary-seat reduction."
                    )
                    evidenceMetric(
                        "Neighbor B",
                        decibels(snapshot.neighboringSeatReductionDB),
                        "Integrated neighboring-seat reduction."
                    )
                    evidenceMetric(
                        "Primary A return",
                        decibels(snapshot.returningPrimaryReductionDB),
                        "Integrated reduction after moving the microphone away and back."
                    )
                    evidenceMetric(
                        "Worst frequency",
                        decibels(snapshot.worstFrequencyReductionDB),
                        "Weakest observed 20–150 Hz benefit across all three visits."
                    )
                    evidenceMetric(
                        "A repeat difference",
                        absoluteDecibels(snapshot.primaryRepeatDifferenceDB),
                        "Integrated initial-A versus returned-A difference."
                    )
                    evidenceMetric(
                        "Worst band repeat",
                        absoluteDecibels(snapshot.maximumBandRepeatDifferenceDB),
                        "Largest single-frequency A versus A-return discrepancy."
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Frequency-resolved reduction")
                            .font(.caption.bold())
                        Spacer()
                        HStack(spacing: 10) {
                            legend("A", Color.accentColor)
                            legend("B", Color.secondary)
                            legend("A return", Color.green)
                        }
                    }
                    ActiveAcousticsEvidenceReductionCurveView(
                        points: snapshot.curvePoints
                    )
                    .frame(height: 170)
                    Text(
                        "Positive values indicate lower measured coherent-band level during the experimental condition. This graph is numerical evidence only; it does not authenticate the measurement instrument."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ],
                spacing: 8
            ) {
                verificationCell(
                    "Record digest",
                    snapshot.digestIntegrityVerified
                        ? "INTEGRITY VERIFIED"
                        : physicalEvidence == nil
                            ? "NO PACKAGE"
                            : "FAILED",
                    "SHA-256 detects package changes; it is not an instrument signature."
                )
                verificationCell(
                    "Independent role review",
                    snapshot.independentRolesAcknowledged
                        ? "2 ROLES ACKNOWLEDGED"
                        : "NOT ESTABLISHED",
                    "Claimed acoustics and electrical-safety review does not cryptographically identify either reviewer."
                )
                verificationCell(
                    "Instrument provenance",
                    "UNAUTHENTICATED",
                    "No enrolled meter, microphone, trusted timestamp or hardware-root signature is verified."
                )
                verificationCell(
                    "Physical attenuation",
                    "UNVERIFIED",
                    "Numerical results cannot certify real acoustic benefit without independent physical review."
                )
                verificationCell(
                    "Emergency hardware mute",
                    "UNVERIFIED",
                    "Typed fault-witness records are not proof of actual analog shutdown."
                )
                verificationCell(
                    "Live ANC output",
                    "DISCONNECTED",
                    "PR100 has no speaker-output authorization or feed-forward arm path."
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func evidenceMetric(
        _ title: String,
        _ value: String,
        _ detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .secondary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func decibels(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%+.2f dB", value)
    }

    private func absoluteDecibels(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.2f dB", abs(value))
    }

    private var physicalCampaignPlan: some View {
        let campaign = ActiveAcousticsPhysicalCampaignUXSnapshot()

        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Physical Verification Campaign")
                        .font(.subheadline.bold())
                    Text("One microphone · A → B → A")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("NOT YET PERFORMED")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }

            ForEach(campaign.visits) { visit in
                HStack(alignment: .top, spacing: 10) {
                    Text(visit.positionLabel)
                        .font(.caption.bold())
                        .frame(width: 24, height: 24)
                        .background(
                            Color.accentColor.opacity(0.10),
                            in: Circle()
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(visit.id). \(visit.role)")
                            .font(.caption.bold())
                        Text(visit.instruction)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 10)
                    Text(
                        "\(visit.sourceCaptureCount) captures · \(visit.faultWitnessCount) faults"
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ],
                spacing: 8
            ) {
                verificationCell(
                    "Source captures",
                    "\(campaign.totalSourceCaptures) TOTAL",
                    "Three independent OFF/TEST/OFF source launches per visit."
                )
                verificationCell(
                    "Fault witnesses",
                    "\(campaign.totalFaultWitnesses) TOTAL",
                    "Five externally measured shutdown classes per visit."
                )
                verificationCell(
                    "Acoustic band",
                    "20–150 Hz",
                    "Frequency-resolved coherent verification; no broadband silence claim."
                )
                verificationCell(
                    "Primary repeat gate",
                    "≤ 1.5 dB",
                    "Return-to-A reduction and OFF baselines must remain repeatable per frequency."
                )
            }

            Text(
                "This is a commissioning guide, not evidence. The captures must come from the real fixed rig with independently calibrated instrumentation; PR100 does not synthesize, sign, or authenticate them."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var consolidatedDiagnostics: some View {
        let snapshot = ActiveAcousticsDiagnosticsUXSnapshot(
            calibration: quietZone.feedForwardCalibration,
            budget: quietZone.feedForwardBudget
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Diagnostics & Blockers")
                        .font(.subheadline.bold())
                    Text(snapshot.headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(snapshot.unresolvedCount) OPEN")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(snapshot.items) { item in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.caption.bold())
                        Text(item.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Text(item.disposition.rawValue)
                        .font(.caption2.bold())
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(
                            item.disposition == .blocked
                                ? .red
                                : item.disposition == .diagnosticPass
                                    ? .green
                                    : .secondary
                        )
                }
                .padding(.vertical, 3)
            }

            Text(
                "A diagnostic pass means only that the corresponding software check succeeded. Physical acoustic benefit, instrument provenance, real emergency shutdown, and live output authorization remain separate hardware gates."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var oneMicrophoneSetupProgress: some View {
        let calibration = quietZone.feedForwardCalibration
        let rows: [(String, Bool, String)] = [
            (
                "Plan",
                calibration != nil,
                "Playback system, listener position and upstream reference are identified."
            ),
            (
                "Listener A",
                calibration?.arrivals.contains {
                    $0.position == .listenerFirst
                } ?? false,
                "First trigger-synchronized listener arrival captured."
            ),
            (
                "Upstream reference",
                calibration?.arrivals.contains {
                    $0.position == .upstream
                } ?? false,
                "Same microphone moved upstream without changing the timing identity."
            ),
            (
                "Listener A return",
                calibration?.arrivals.contains {
                    $0.position == .listenerReturn
                } ?? false,
                "Microphone returned to the listener to expose source/timebase drift."
            ),
            (
                "Physical timing path",
                calibration?.timingPath != nil,
                "Reference ADC, processing, DAC and speaker-to-seat latency evidence supplied."
            ),
            (
                "HAL clock trace",
                calibration?.halClockTrace != nil,
                "Concurrent input/output clock observations supplied for qualification."
            ),
        ]
        let completed = rows.filter { $0.1 }.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Guided One-Microphone Setup")
                        .font(.subheadline.bold())
                    Text(
                        "Move the same microphone from the listener to the upstream reference position and back."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(completed) / \(rows.count)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top, spacing: 10) {
                    Image(
                        systemName:
                            row.1
                                ? "checkmark.circle.fill"
                                : "circle"
                    )
                    .foregroundStyle(
                        row.1 ? Color.green : Color.secondary
                    )
                    .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(index + 1). \(row.0)")
                            .font(.caption.bold())
                        Text(row.2)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(row.1 ? "RECORDED" : "PENDING")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }

            Text(
                "Recorded means only that a software record exists. PR100 does not authenticate the microphone, trigger clock, instrument, geometry, or acoustic result."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var commissioningSummary: some View {
        let snapshot = ActiveAcousticsCommissioningUXSnapshot(
            calibrationPlanned: quietZone.feedForwardCalibration != nil,
            timingReadiness: quietZone.feedForwardBudget.readiness
        )

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Commissioning & Verification")
                        .font(.subheadline.bold())
                    Text(snapshot.state.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("PR100 · READ ONLY")
                    .font(.caption2.bold())
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ],
                spacing: 10
            ) {
                verificationCell(
                    "One-mic calibration",
                    snapshot.calibrationPlanned ? "PLANNED" : "REQUIRED",
                    snapshot.calibrationPlanned
                        ? "Listener/upstream geometry exists; physical captures may still be missing."
                        : "No feed-forward calibration plan is available."
                )
                verificationCell(
                    "Timing & causality",
                    snapshot.timingCaption,
                    "Software diagnostics only; never proof of acoustic cancellation."
                )
                verificationCell(
                    "Physical evidence",
                    "HARDWARE REQUIRED",
                    "Instrument provenance, A/B/A attenuation and moving-room stability are not yet authenticated."
                )
                verificationCell(
                    "Live ANC output",
                    "DISCONNECTED",
                    "No PR98/PR99 result can authorize speaker-connected feed-forward ANC."
                )
            }

            Label(snapshot.nextAction, systemImage: "arrow.right.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func verificationCell(
        _ title: String,
        _ value: String,
        _ detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.bold())
                .tracking(0.4)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .secondary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private var readinessTitle: String {
        switch quietZone.feedForwardBudget.readiness {
        case .missingMeasurements:
            return "Capture required · not eligible"
        case .invalidTimebase:
            return "Clock not trustworthy · not eligible"
        case .unreliableMeasurements:
            return "Measurement confidence insufficient"
        case .nonCausal:
            return "Negative causality reserve · feed-forward cannot work"
        case .limitedMargin:
            return "Marginal positive reserve · control held"
        case .physicallyPlausible:
            return "Timing physically plausible · runtime not yet verified"
        }
    }

    private func stage(
        _ number: Int,
        _ explanation: String
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(
                    Color.accentColor.opacity(0.10),
                    in: Circle()
                )
            Text(explanation)
                .font(.caption)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
    }

    private func milliseconds(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else {
            return "—"
        }
        return String(
            format: "%+.2f ms",
            seconds * 1000
        )
    }

    private func valueCard(
        _ title: String,
        _ value: String,
        _ detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
            Text(value)
                .font(.title3.monospacedDigit().bold())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            .secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}
