import CryptoKit
import XCTest
@testable import NotchSixty

final class ProductionInformationArchitectureTests: XCTestCase {
    func testDashboardIsStandaloneAndNotInAGroup() {
        let grouped =
            ProductionSection.playback
            + ProductionSection.system
            + ProductionSection.tools
            + ProductionSection.extensions

        XCTAssertFalse(grouped.contains(.dashboard))
        XCTAssertEqual(Set(grouped).count, grouped.count)
        XCTAssertEqual(
            Set(grouped + [.dashboard]),
            Set(ProductionSection.allCases)
        )
    }

    func testPlaybackGroupContainsOnlyContentFacingDailyControls() {
        XCTAssertEqual(
            ProductionSection.playback,
            [.equalizer, .dynamics, .meters]
        )
    }

    func testSystemGroupContainsHardwareCalibrationAndAcoustics() {
        XCTAssertEqual(
            ProductionSection.system,
            [
                .speakers,
                .headphones,
                .speakerCalibration,
                .measurementLab,
                .roomCorrection,
                .activeAcoustics,
            ]
        )
    }

    func testToolsGroupContainsOccasionalAdvisoryAndAcceptanceWorkflows() {
        XCTAssertEqual(
            ProductionSection.tools,
            [.roomAdvisor, .hardwareAcceptance]
        )
    }

    func testExtensionsGroupContainsPluginRackEntryPoint() {
        XCTAssertEqual(
            ProductionSection.extensions,
            [.plugins]
        )
    }

    func testRenamedAndNewTitlesMatchProductLanguage() {
        XCTAssertEqual(ProductionSection.dashboard.title, "Dashboard")
        XCTAssertEqual(ProductionSection.speakers.title, "Speakers")
        XCTAssertEqual(
            ProductionSection.measurementLab.title,
            "Measurement Lab"
        )
        XCTAssertEqual(
            ProductionSection.activeAcoustics.title,
            "Active Acoustics"
        )
        XCTAssertEqual(
            ProductionSection.roomAdvisor.title,
            "Room Advisor"
        )
        XCTAssertEqual(
            ProductionSection.hardwareAcceptance.title,
            "Hardware Acceptance"
        )
        XCTAssertEqual(ProductionSection.plugins.title, "Plug-ins")
    }

    func testActiveAcousticsUXRequiresCalibrationBeforeTimingReview() {
        let snapshot = ActiveAcousticsCommissioningUXSnapshot(
            calibrationPlanned: false,
            timingReadiness: .missingMeasurements
        )

        XCTAssertEqual(snapshot.state, .calibrationRequired)
        XCTAssertEqual(snapshot.timingCaption, "MEASUREMENTS REQUIRED")
        XCTAssertFalse(snapshot.instrumentEvidenceAuthenticated)
        XCTAssertFalse(snapshot.physicalAttenuationVerified)
        XCTAssertFalse(snapshot.emergencyMuteHardwareVerified)
        XCTAssertFalse(snapshot.liveANCOutputAuthorized)
    }

    func testPhysicallyPlausibleTimingStillRequiresHardwareVerification() {
        let snapshot = ActiveAcousticsCommissioningUXSnapshot(
            calibrationPlanned: true,
            timingReadiness: .physicallyPlausible
        )

        XCTAssertEqual(snapshot.state, .timingPlausibleHardwareRequired)
        XCTAssertEqual(snapshot.timingCaption, "DIAGNOSTIC PASS")
        XCTAssertTrue(snapshot.nextAction.contains("PR99 A/B/A"))
        XCTAssertFalse(snapshot.liveANCOutputAuthorized)
    }

    func testNonCausalTimingNeverLooksReady() {
        let snapshot = ActiveAcousticsCommissioningUXSnapshot(
            calibrationPlanned: true,
            timingReadiness: .nonCausal
        )

        XCTAssertEqual(snapshot.state, .timingUnqualified)
        XCTAssertEqual(snapshot.timingCaption, "NON-CAUSAL")
        XCTAssertFalse(snapshot.physicalAttenuationVerified)
    }


    func testConsolidatedDiagnosticsKeepPhysicalGatesSeparate() {
        let budget = QuietZoneFeedForwardBudget(
            readiness: .physicallyPlausible,
            acousticPreviewSeconds: 0.020,
            conservativePreviewSeconds: 0.015,
            antiNoisePathSeconds: 0.010,
            conservativeReserveSeconds: 0.005,
            geometryOnly: false,
            runtimeAvailable: false,
            explanation: "Synthetic diagnostic fixture"
        )
        let snapshot = ActiveAcousticsDiagnosticsUXSnapshot(
            calibration: nil,
            budget: budget
        )

        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "causality" })?.disposition,
            .diagnosticPass
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "acoustic" })?.disposition,
            .hardwareRequired
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "mute" })?.disposition,
            .hardwareRequired
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "output" })?.disposition,
            .disconnected
        )
        XCTAssertGreaterThan(snapshot.unresolvedCount, 0)
    }

    func testConsolidatedDiagnosticsExposeMissingCommissioningRecords() {
        let snapshot = ActiveAcousticsDiagnosticsUXSnapshot(
            calibration: nil,
            budget: .missing
        )

        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "plan" })?.disposition,
            .blocked
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "clock" })?.disposition,
            .blocked
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "path" })?.disposition,
            .blocked
        )
        XCTAssertTrue(snapshot.headline.contains("blockers"))
    }


    func testPhysicalCampaignPlanPreservesABAAndEvidenceCounts() {
        let campaign = ActiveAcousticsPhysicalCampaignUXSnapshot()

        XCTAssertEqual(campaign.visits.map(\.positionLabel), ["A", "B", "A"])
        XCTAssertEqual(campaign.totalSourceCaptures, 9)
        XCTAssertEqual(campaign.totalFaultWitnesses, 15)
        XCTAssertFalse(campaign.physicalVerificationComplete)
        XCTAssertFalse(campaign.instrumentProvenanceAuthenticated)
        XCTAssertFalse(campaign.liveOutputAuthorized)
    }


    private func makePhysicalEvidencePackage(
        validDigest: Bool = true
    ) throws -> QuietZonePhysicalEvidencePackage {
        let rig = QuietZoneHardwareCalibrationRig(
            projectID: UUID(),
            microphoneID: "test-mic",
            microphoneChannel: 0,
            outputDeviceID: "test-dac",
            routeID: "route-1",
            sampleRate: 96_000,
            clockID: "clock-1",
            triggerID: "fixture-1"
        )
        let campaign = QuietZonePhysicalVerificationReview(
            rig: rig,
            sessionIDs: [UUID(), UUID(), UUID()],
            firstPrimaryReductionDB: 5.0,
            neighboringSeatReductionDB: 2.0,
            returningPrimaryReductionDB: 4.6,
            worstMeasuredBandReductionDB: 1.0,
            largestPrimaryBaselineDifferenceDB: 0.7,
            primaryReductionRepeatDifferenceDB: 0.4,
            worstReportedShutdownSeconds: 0.050,
            uniqueExternalLaunchCount: 24
        )
        let rows = [["SCHEMA", "PR99_PHYSICAL_EVIDENCE", "1"]]
        let data = try JSONEncoder().encode(rows)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let actualDigest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let digest = validDigest
            ? actualDigest
            : String(repeating: "0", count: 64)
        return QuietZonePhysicalEvidencePackage(
            schemaVersion: 1,
            canonicalJSON: json,
            sha256Hex: digest,
            frequencyResults: [
                .init(
                    frequencyHz: 40,
                    primaryFirstReductionDB: 5.0,
                    neighboringSeatReductionDB: 2.0,
                    primaryReturnReductionDB: 4.6,
                    primaryRepeatDifferenceDB: 0.4,
                    worstObservedReductionDB: 2.0,
                    primaryFourBaselineSpanDB: 0.5
                ),
                .init(
                    frequencyHz: 80,
                    primaryFirstReductionDB: 4.0,
                    neighboringSeatReductionDB: 1.5,
                    primaryReturnReductionDB: 3.8,
                    primaryRepeatDifferenceDB: 0.2,
                    worstObservedReductionDB: 1.5,
                    primaryFourBaselineSpanDB: 0.7
                ),
                .init(
                    frequencyHz: 120,
                    primaryFirstReductionDB: 3.5,
                    neighboringSeatReductionDB: 1.0,
                    primaryReturnReductionDB: 3.2,
                    primaryRepeatDifferenceDB: 0.3,
                    worstObservedReductionDB: 1.0,
                    primaryFourBaselineSpanDB: 0.6
                ),
            ],
            campaignReview: campaign,
            maximumPrimaryBandRepeatDifferenceDB: 0.4,
            worstFrequencyReductionDB: 1.0,
            rawSourceLaunchCount: 9,
            rawFaultWitnessCount: 15
        )
    }



    private func makeReviewPacket(
        for package: QuietZonePhysicalEvidencePackage,
        includeRecords: Bool = true
    ) -> QuietZoneExternalReviewPacket {
        let reviews: [QuietZoneExternalReviewAcknowledgment] =
            includeRecords
                ? [
                    .init(
                        role: .acoustics,
                        reviewerID: "acoustics-reviewer",
                        evidenceSHA256Hex: package.sha256Hex,
                        reviewedAt: Date(timeIntervalSince1970: 1_000),
                        decision: .recommendFurtherHardwareReview,
                        notes: "Numerical acoustic evidence reviewed."
                    ),
                    .init(
                        role: .electricalSafety,
                        reviewerID: "safety-reviewer",
                        evidenceSHA256Hex: package.sha256Hex,
                        reviewedAt: Date(timeIntervalSince1970: 1_030),
                        decision: .recommendFurtherHardwareReview,
                        notes: "Fault witness metadata reviewed."
                    ),
                ]
                : []

        return QuietZoneExternalReviewPacket(
            evidenceSHA256Hex: package.sha256Hex,
            reviews: reviews,
            numericalAcceptance: true,
            independentRolesAcknowledged: true
        )
    }

    func testPhysicalEvidenceUXWaitsForRealCampaign() {
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: nil,
            reviewPacket: nil
        )

        XCTAssertEqual(snapshot.state, .awaitingCampaign)
        XCTAssertTrue(snapshot.curvePoints.isEmpty)
        XCTAssertNil(snapshot.initialPrimaryReductionDB)
        XCTAssertFalse(snapshot.digestIntegrityVerified)
        XCTAssertFalse(snapshot.instrumentEvidenceAuthenticated)
        XCTAssertFalse(snapshot.physicalAttenuationVerified)
        XCTAssertFalse(snapshot.emergencyMuteHardwareVerified)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

    func testPhysicalEvidenceUXShowsVerifiedNumericalPackageWithoutAuthorizingANC()
        throws {
        let package = try makePhysicalEvidencePackage()
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: package,
            reviewPacket: nil
        )

        XCTAssertEqual(snapshot.state, .numericalEvidenceAvailable)
        XCTAssertTrue(snapshot.digestIntegrityVerified)
        XCTAssertEqual(snapshot.curvePoints.count, 3)
        XCTAssertEqual(snapshot.initialPrimaryReductionDB, 5.0)
        XCTAssertEqual(snapshot.neighboringSeatReductionDB, 2.0)
        XCTAssertEqual(snapshot.returningPrimaryReductionDB, 4.6)
        XCTAssertEqual(snapshot.worstSeatReductionDB, 2.0)
        XCTAssertEqual(snapshot.worstFrequencyReductionDB, 1.0)
        XCTAssertEqual(snapshot.largestPrimaryBaselineDifferenceDB, 0.7)
        XCTAssertFalse(snapshot.independentRolesAcknowledged)
        XCTAssertFalse(snapshot.instrumentEvidenceAuthenticated)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

    func testPhysicalEvidenceUXSuppressesTamperedPackageMetrics() throws {
        let package = try makePhysicalEvidencePackage(validDigest: false)
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: package,
            reviewPacket: nil
        )

        XCTAssertEqual(snapshot.state, .invalidPackage)
        XCTAssertFalse(snapshot.digestIntegrityVerified)
        XCTAssertTrue(snapshot.curvePoints.isEmpty)
        XCTAssertNil(snapshot.initialPrimaryReductionDB)
        XCTAssertNil(snapshot.worstFrequencyReductionDB)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

    func testTwoRoleReviewStillDoesNotAuthenticatePhysicalEvidence() throws {
        let package = try makePhysicalEvidencePackage()
        let packet = makeReviewPacket(for: package)
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: package,
            reviewPacket: packet
        )

        XCTAssertEqual(snapshot.state, .roleReviewAcknowledged)
        XCTAssertTrue(snapshot.independentRolesAcknowledged)
        XCTAssertFalse(snapshot.instrumentEvidenceAuthenticated)
        XCTAssertFalse(snapshot.physicalAttenuationVerified)
        XCTAssertFalse(snapshot.emergencyMuteHardwareVerified)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

    func testClaimedReviewBoolWithoutRoleRecordsIsNotAccepted() throws {
        let package = try makePhysicalEvidencePackage()
        let packet = makeReviewPacket(for: package, includeRecords: false)
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: package,
            reviewPacket: packet
        )

        XCTAssertEqual(snapshot.state, .numericalEvidenceAvailable)
        XCTAssertFalse(snapshot.independentRolesAcknowledged)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

    func testEvidenceProvenanceShowsDigestValidRecordButNotAuthentication()
        throws {
        let package = try makePhysicalEvidencePackage()
        let packet = makeReviewPacket(for: package)
        let provenance = ActiveAcousticsEvidenceProvenanceUXSnapshot(
            package: package,
            reviewPacket: packet
        )

        XCTAssertEqual(provenance.microphoneID, "test-mic")
        XCTAssertEqual(provenance.microphoneChannel, 0)
        XCTAssertEqual(provenance.outputDeviceID, "test-dac")
        XCTAssertEqual(provenance.routeID, "route-1")
        XCTAssertEqual(provenance.sampleRate, 96_000)
        XCTAssertEqual(provenance.clockID, "clock-1")
        XCTAssertEqual(provenance.triggerID, "fixture-1")
        XCTAssertEqual(provenance.sessionCount, 3)
        XCTAssertEqual(provenance.sourceCaptureCount, 9)
        XCTAssertEqual(provenance.faultWitnessCount, 15)
        XCTAssertEqual(
            Set(provenance.acknowledgedReviewRoles),
            Set(["Acoustics", "Electrical safety"])
        )
        XCTAssertFalse(provenance.reviewerIdentityCryptographicallyVerified)
        XCTAssertFalse(provenance.instrumentEvidenceIndependentlyAuthenticated)
        XCTAssertFalse(provenance.liveOutputAuthorized)
    }


    func testUserGuideCoversEveryProductionWorkspace() {
        XCTAssertTrue(
            ProductionUserGuideCatalog.uncoveredProductionSections.isEmpty
        )

        for section in ProductionSection.allCases {
            let articleID = ProductionUserGuideCatalog.articleID(for: section)
            XCTAssertNotNil(
                ProductionUserGuideCatalog.article(id: articleID),
                "Missing guide article for \(section.title)"
            )
        }
    }

    func testUserGuideIdentifiersAreStableAndUnique() {
        let articles = ProductionUserGuideCatalog.articles
        XCTAssertEqual(
            Set(articles.map(\.id)).count,
            articles.count
        )

        for article in articles {
            XCTAssertEqual(
                Set(article.sections.map(\.id)).count,
                article.sections.count,
                "Duplicate section ID in \(article.id)"
            )
            XCTAssertEqual(
                Set(article.formulas.map(\.id)).count,
                article.formulas.count,
                "Duplicate formula ID in \(article.id)"
            )
        }
    }

    func testUserGuideSearchFindsFeatureMathAndSafetyLanguage() {
        XCTAssertTrue(
            ProductionUserGuideCatalog.search("compressor ratio")
                .contains { $0.id == "dynamics" }
        )
        XCTAssertTrue(
            ProductionUserGuideCatalog.search("transfer function impulse")
                .contains { $0.id == "measurement-lab" }
        )
        XCTAssertTrue(
            ProductionUserGuideCatalog.search("physical evidence H08")
                .contains { $0.id == "hardware-acceptance" }
        )
        XCTAssertTrue(
            ProductionUserGuideCatalog.search("causality budget")
                .contains { $0.id == "active-acoustics" }
        )
    }

    func testMathBearingGuideArticlesExplainFormulaScope() throws {
        let requiredMathArticles = [
            "dashboard",
            "equalizer",
            "dynamics",
            "meters",
            "speakers",
            "headphones",
            "speaker-calibration",
            "measurement-lab",
            "room-correction",
            "active-acoustics",
            "room-advisor",
            "math-reference",
        ]

        for id in requiredMathArticles {
            let article = try XCTUnwrap(
                ProductionUserGuideCatalog.article(id: id)
            )
            XCTAssertFalse(article.formulas.isEmpty, id)
            for formula in article.formulas {
                XCTAssertFalse(formula.expression.isEmpty, formula.id)
                XCTAssertFalse(formula.explanation.isEmpty, formula.id)
                XCTAssertFalse(formula.scope.title.isEmpty, formula.id)
            }
        }
    }

    func testGuideKeepsSoftwareAndPhysicalAuthorityDistinct() throws {
        let acceptance = try XCTUnwrap(
            ProductionUserGuideCatalog.article(id: "hardware-acceptance")
        )
        XCTAssertTrue(
            acceptance.searchableText.contains("ci test labeled pass")
        )
        XCTAssertTrue(
            acceptance.searchableText.contains("physical-hardware evidence")
        )
        XCTAssertTrue(
            acceptance.searchableText.contains("independent physical review")
        )
    }


    @MainActor
    func testReferenceNavigatorRoutesGuideAndDSPDeepLinks() {
        let navigator = ProductionReferenceNavigator()

        navigator.openGuide(articleID: "room-correction")
        XCTAssertEqual(navigator.selectedTab, .userGuide)
        XCTAssertEqual(navigator.selectedArticleID, "room-correction")
        XCTAssertNil(navigator.selectedFormulaID)

        navigator.openDSPReference(
            articleID: "dynamics",
            formulaID: "compressor-ratio"
        )
        XCTAssertEqual(navigator.selectedTab, .dspReference)
        XCTAssertEqual(navigator.selectedArticleID, "dynamics")
        XCTAssertEqual(navigator.selectedFormulaID, "compressor-ratio")
    }

    func testWorkflowVocabularySeparatesDraftAndLiveRecoverySemantics() {
        XCTAssertEqual(
            Set(ProductionWorkflowTerm.allCases.map(\.rawValue)),
            Set(["Preview", "Apply", "Verify", "Revert", "Rollback", "Deploy"])
        )
        XCTAssertTrue(
            ProductionWorkflowTerm.preview.definition
                .contains("without changing saved or live playback state")
        )
        XCTAssertTrue(
            ProductionWorkflowTerm.revert.definition
                .contains("before a live Apply")
        )
        XCTAssertTrue(
            ProductionWorkflowTerm.rollback.definition
                .contains("after a live or saved change")
        )
        XCTAssertTrue(
            ProductionWorkflowTerm.verify.definition
                .contains("fresh evidence")
        )
    }

    func testReferenceSearchFindsWorkflowAndDSPGlossaryTerms() {
        let workflow = ProductionUserGuideCatalog.search("rollback evidence")
        XCTAssertTrue(workflow.contains { $0.id == "workflow-glossary" })

        let dsp = ProductionUserGuideCatalog.search("dBTP headroom")
        XCTAssertTrue(dsp.contains { $0.id == "workflow-glossary" })

        let coherence = ProductionUserGuideCatalog.search("coherence confidence")
        XCTAssertTrue(coherence.contains { $0.id == "workflow-glossary" })
    }


    func testRoomCorrectionReferenceMatchesMinimumPhaseImplementation() throws {
        let article = try XCTUnwrap(
            ProductionUserGuideCatalog.article(id: "room-correction")
        )
        let formula = try XCTUnwrap(
            article.formulas.first { $0.id == "minimum-phase-fir" }
        )

        XCTAssertTrue(formula.title.contains("Minimum-phase"))
        XCTAssertTrue(formula.explanation.contains("causal minimum-phase"))
        XCTAssertTrue(formula.expression.contains("IFFT"))
        XCTAssertTrue(
            formula.explanation.contains("not a symmetric linear-phase FIR")
        )
    }

}
