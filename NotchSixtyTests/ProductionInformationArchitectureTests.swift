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


    func testABAuditionStateContainsOnlySafeContentDSP() {
        let audition = ContentABAuditionState(
            contentState: ContentPresetState()
        )
        let labels = Set(
            Mirror(reflecting: audition).children.compactMap { $0.label }
        )

        XCTAssertEqual(
            labels,
            Set([
                "stereoEQ",
                "inputPreampDB",
                "headroomAttenuationDB",
                "dynamics",
            ])
        )
        XCTAssertFalse(labels.contains("audioUnitRack"))
        XCTAssertFalse(labels.contains("outputRouting"))
        XCTAssertFalse(labels.contains("bassManagement"))
        XCTAssertFalse(labels.contains("roomCorrection"))
        XCTAssertFalse(labels.contains("speakerIR"))
        XCTAssertFalse(labels.contains("speakerDriverProcessing"))
        XCTAssertFalse(labels.contains("outputGainDB"))
    }

    func testABAuditionMergePreservesCurrentAudioUnitRack() {
        let base = ContentPresetState()
        let audition = ContentABAuditionState(
            stereoEQ: StereoEQConfiguration(),
            inputPreampDB: -3.0,
            headroomAttenuationDB: -1.5,
            dynamics: DynamicsConfiguration()
        )

        let merged = audition.merging(into: base)

        XCTAssertEqual(merged.stereoEQ, audition.stereoEQ)
        XCTAssertEqual(merged.inputPreampDB, -3.0)
        XCTAssertEqual(merged.headroomAttenuationDB, -1.5)
        XCTAssertEqual(merged.dynamics, audition.dynamics)
        XCTAssertEqual(merged.audioUnitRack, base.audioUnitRack)
    }

    func testABSystemBoundaryFailsClosedOnIdentityAndStateDrift() {
        let systemID = UUID()
        let state = PlaybackSystemState()
        let boundary = ContentABSystemBoundary(
            selectedSystemProfileID: systemID,
            systemState: state
        )

        XCTAssertEqual(
            boundary.compatibility(
                currentSystemProfileID: systemID,
                currentSystemState: state
            ),
            .ready
        )

        XCTAssertEqual(
            boundary.compatibility(
                currentSystemProfileID: UUID(),
                currentSystemState: state
            ),
            .playbackSystemChanged
        )

        var changedState = state
        changedState.outputGainDB = -1.0
        XCTAssertEqual(
            boundary.compatibility(
                currentSystemProfileID: systemID,
                currentSystemState: changedState
            ),
            .playbackSystemStateChanged
        )
    }

    func testABSlotsHaveStableIdentityAndOpposites() {
        XCTAssertEqual(ContentABSlot.allCases, [.a, .b])
        XCTAssertEqual(ContentABSlot.a.displayName, "A")
        XCTAssertEqual(ContentABSlot.b.displayName, "B")
        XCTAssertEqual(ContentABSlot.a.opposite, .b)
        XCTAssertEqual(ContentABSlot.b.opposite, .a)
    }


    func testABLoudnessMatchOnlyAttenuatesTheLouderCapture() throws {
        let plan = try XCTUnwrap(
            ContentABLoudnessMatchPlan.make(
                aLUFS: -14.0,
                bLUFS: -17.0
            )
        )

        XCTAssertEqual(plan.referenceLUFS, -17.0, accuracy: 0.0001)
        XCTAssertEqual(plan.attenuationA_DB, -3.0, accuracy: 0.0001)
        XCTAssertEqual(plan.attenuationB_DB, 0.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(plan.attenuationA_DB, 0)
        XCTAssertLessThanOrEqual(plan.attenuationB_DB, 0)
    }

    func testABLoudnessMatchIsBoundedAndRequiresValidSignal() throws {
        let bounded = try XCTUnwrap(
            ContentABLoudnessMatchPlan.make(
                aLUFS: -10.0,
                bLUFS: -30.0
            )
        )
        XCTAssertEqual(
            bounded.attenuationA_DB,
            -ContentABLoudnessMatchPlan.maximumAttenuationDB,
            accuracy: 0.0001
        )
        XCTAssertEqual(bounded.attenuationB_DB, 0, accuracy: 0.0001)

        XCTAssertNil(
            ContentABLoudnessMatchPlan.make(
                aLUFS: nil,
                bLUFS: -18
            )
        )
        XCTAssertNil(
            ContentABLoudnessMatchPlan.make(
                aLUFS: -70,
                bLUFS: -18
            )
        )
    }

    func testABSnapshotCanCarryMeasuredLoudnessWithoutBroadeningAuditionState() throws {
        let snapshot = ContentABSnapshot(
            sourceContentPresetID: nil,
            sourceContentPresetName: "Fixture",
            loudnessReferenceLUFS: -18.5,
            auditionState: ContentABAuditionState(
                contentState: ContentPresetState()
            ),
            systemBoundary: ContentABSystemBoundary(
                selectedSystemProfileID: nil,
                systemState: PlaybackSystemState()
            )
        )

        XCTAssertEqual(
            try XCTUnwrap(snapshot.loudnessReferenceLUFS),
            -18.5,
            accuracy: 0.0001
        )

        let labels = Set(
            Mirror(reflecting: snapshot.auditionState)
                .children.compactMap { $0.label }
        )
        XCTAssertEqual(
            labels,
            Set([
                "stereoEQ",
                "inputPreampDB",
                "headroomAttenuationDB",
                "dynamics",
            ])
        )
    }


    @MainActor
    func testBackupRestoreMarksUnavailablePlaybackHardwareForMapping()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profiles = ProductProfileController(
            engine: AudioIOEngine(),
            storageURL: root.appendingPathComponent("profiles.json")
        )
        let content = ContentPreset(
            name: "Backup Content",
            origin: .user,
            state: ContentPresetState()
        )
        let system = PlaybackSystemProfile(
            name: "Backup System",
            state: PlaybackSystemState(
                associatedOutputUID: "missing-output"
            )
        )
        let snapshot = ProductProfileBackupSnapshot(
            contentPresets: [content],
            systemProfiles: [system],
            selectedContentPresetID: content.id,
            selectedSystemProfileID: system.id
        )

        let report = try profiles.restoreBackupSnapshot(
            snapshot,
            availableOutputUIDs: []
        )

        XCTAssertEqual(
            report.hardwareMappingRequiredSystemIDs,
            [system.id]
        )
        XCTAssertNil(profiles.selectedSystemProfileID)
        let requirement = try XCTUnwrap(
            profiles.hardwareMappingRequirement(for: system.id)
        )
        XCTAssertEqual(
            requirement.importedDeviceUIDs,
            ["missing-output"]
        )
    }

    @MainActor
    func testBackupRestoreKeepsKnownHardwareEligibleWithoutRemapping()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profiles = ProductProfileController(
            engine: AudioIOEngine(),
            storageURL: root.appendingPathComponent("profiles.json")
        )
        let content = ContentPreset(
            name: "Backup Content",
            origin: .user,
            state: ContentPresetState()
        )
        let system = PlaybackSystemProfile(
            name: "Known System",
            state: PlaybackSystemState(
                associatedOutputUID: "known-output"
            )
        )
        let snapshot = ProductProfileBackupSnapshot(
            contentPresets: [content],
            systemProfiles: [system],
            selectedContentPresetID: content.id,
            selectedSystemProfileID: system.id
        )

        let report = try profiles.restoreBackupSnapshot(
            snapshot,
            availableOutputUIDs: ["known-output"]
        )

        XCTAssertTrue(
            report.hardwareMappingRequiredSystemIDs.isEmpty
        )
        XCTAssertEqual(profiles.selectedSystemProfileID, system.id)
        XCTAssertNil(
            profiles.hardwareMappingRequirement(for: system.id)
        )
    }

    func testBackupPreferencesExcludeOSOwnedLaunchState() throws {
        let preferences = NotchSixtyBackupPreferences(
            appearance: "dark",
            presence: "both",
            volumeStepResolution: 64
        )
        XCTAssertNoThrow(try preferences.validate())

        let labels = Set(
            Mirror(reflecting: preferences).children
                .compactMap { $0.label }
        )
        XCTAssertFalse(labels.contains("launchAtLogin"))
        XCTAssertFalse(labels.contains("launchAtLoginEnabled"))
        XCTAssertFalse(labels.contains("permissions"))

        let invalid = NotchSixtyBackupPreferences(
            appearance: "invalid",
            presence: "both",
            volumeStepResolution: 64
        )
        XCTAssertThrowsError(try invalid.validate())
    }

    @MainActor
    func testBackupInspectionRejectsDomainTampering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profiles = ProductProfileController(
            engine: AudioIOEngine(),
            storageURL: root.appendingPathComponent("profiles.json")
        )
        let backup = NotchSixtyBackupService(
            profiles: profiles,
            roomStore: RoomCorrectionProjectStore(
                rootDirectory: root.appendingPathComponent(
                    "room",
                    isDirectory: true
                )
            ),
            labStore: SpeakerMeasurementLabSessionStore(
                rootDirectory: root.appendingPathComponent(
                    "lab",
                    isDirectory: true
                )
            ),
            binauralStore: BinauralProfileAssetStore(
                rootURL: root.appendingPathComponent(
                    "binaural",
                    isDirectory: true
                )
            )
        )
        let preferences = NotchSixtyBackupPreferences(
            appearance: "dark",
            presence: "both",
            volumeStepResolution: 32
        )

        let original = try backup.exportData(
            preferences: preferences,
            appVersion: "1.0",
            appBuild: "1",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertNoThrow(try backup.inspect(original))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: original)
                as? [String: Any]
        )
        var profilesJSON = try XCTUnwrap(
            object["profiles"] as? [String: Any]
        )
        var presets = try XCTUnwrap(
            profilesJSON["contentPresets"]
                as? [[String: Any]]
        )
        XCTAssertFalse(presets.isEmpty)
        presets[0]["name"] = "Tampered"
        profilesJSON["contentPresets"] = presets
        object["profiles"] = profilesJSON

        let tampered = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        XCTAssertThrowsError(
            try backup.inspect(tampered)
        ) { error in
            guard let backupError =
                    error as? NotchSixtyBackupError,
                  case .integrityMismatch(let domain) =
                    backupError else {
                return XCTFail(
                    "Expected integrity mismatch, got \(error)"
                )
            }
            XCTAssertEqual(domain, "profiles")
        }
    }


    @MainActor
    func testLocalOfflineRoutingDoesNotAcquireImportMappingGate()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("profiles.json")
        let profiles = ProductProfileController(
            engine: AudioIOEngine(),
            storageURL: storageURL
        )
        let routing = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Left Main",
                    bus: .leftFullRange,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "offline-main-dac",
                        channelIndex: 0
                    )
                ),
                SpeakerOutputRoute(
                    name: "Right Main",
                    bus: .rightFullRange,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "offline-main-dac",
                        channelIndex: 1
                    )
                ),
            ],
            synchronizationMode: .softwarePLL,
            referenceDeviceUID: "offline-main-dac"
        )

        try profiles.replaceSelectedSystemOutputRouting(routing)
        XCTAssertNil(
            profiles.selectedSystemHardwareMappingRequirement
        )

        let restored = ProductProfileController(
            engine: AudioIOEngine(),
            storageURL: storageURL
        )
        XCTAssertEqual(
            restored.selectedSystemProfile?.state.outputRouting,
            routing
        )
        XCTAssertNil(
            restored.selectedSystemHardwareMappingRequirement
        )
    }


    @MainActor
    func testRecoveryDetectsUncleanPriorLaunchButNotCleanTermination()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pr113b-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recovery.json")
        let store = ProductRecoveryStore(storageURL: url)

        let first = ProductRecoveryController(store: store)
        first.prepareForLaunch(
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertFalse(first.safeLaunchActive)

        let afterUnclean = ProductRecoveryController(store: store)
        afterUnclean.prepareForLaunch(
            now: Date(timeIntervalSince1970: 200)
        )
        XCTAssertTrue(afterUnclean.safeLaunchActive)
        XCTAssertTrue(
            afterUnclean.safeLaunchReasons.contains(
                .uncleanTermination
            )
        )

        afterUnclean.markCleanTermination()

        let afterClean = ProductRecoveryController(store: store)
        afterClean.prepareForLaunch(
            now: Date(timeIntervalSince1970: 300)
        )
        XCTAssertFalse(afterClean.safeLaunchActive)
        XCTAssertFalse(
            afterClean.safeLaunchReasons.contains(
                .uncleanTermination
            )
        )
    }

    @MainActor
    func testRecoveryRepeatedFailuresTriggerSafeLaunchThreshold()
        throws {
        let controller = ProductRecoveryController(
            store: ProductRecoveryStore(storageURL: nil)
        )
        controller.prepareForLaunch()

        controller.recordStartFailure(
            .audioStart,
            description: "first"
        )
        XCTAssertFalse(controller.safeLaunchActive)

        controller.recordStartFailure(
            .audioStart,
            description: "second"
        )
        XCTAssertTrue(controller.safeLaunchActive)
        XCTAssertTrue(
            controller.safeLaunchReasons.contains(
                .repeatedAudioStartFailures
            )
        )

        controller.openNormally()
        XCTAssertFalse(controller.safeLaunchActive)

        let plugInController = ProductRecoveryController(
            store: ProductRecoveryStore(storageURL: nil)
        )
        plugInController.prepareForLaunch()
        plugInController.recordStartFailure(
            .plugInStart,
            description: "plug-in one"
        )
        XCTAssertFalse(plugInController.safeLaunchActive)
        plugInController.recordStartFailure(
            .plugInStart,
            description: "plug-in two"
        )
        XCTAssertTrue(
            plugInController.safeLaunchReasons.contains(
                .repeatedPlugInFailures
            )
        )
    }

    @MainActor
    func testRecoveryOnlyHealthyNormalStartUpdatesLastKnownGood()
        throws {
        let controller = ProductRecoveryController(
            store: ProductRecoveryStore(storageURL: nil)
        )
        controller.prepareForLaunch()

        let firstPreset = ContentPreset(
            name: "Known Good",
            origin: .user,
            state: ContentPresetState()
        )
        let firstSnapshot = ProductProfileBackupSnapshot(
            contentPresets: [firstPreset],
            systemProfiles: [],
            selectedContentPresetID: firstPreset.id,
            selectedSystemProfileID: nil
        )

        controller.recordSuccessfulStart(
            profiles: firstSnapshot,
            plugInChainHealthy: true,
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(
            try controller.lastKnownGoodSnapshot()
                .contentPresets.first?.name,
            "Known Good"
        )

        let secondPreset = ContentPreset(
            name: "Bypassed Candidate",
            origin: .user,
            state: ContentPresetState()
        )
        let secondSnapshot = ProductProfileBackupSnapshot(
            contentPresets: [secondPreset],
            systemProfiles: [],
            selectedContentPresetID: secondPreset.id,
            selectedSystemProfileID: nil
        )

        controller.openWithPlugInsBypassed()
        controller.recordSuccessfulStart(
            profiles: secondSnapshot,
            plugInChainHealthy: true,
            now: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(
            try controller.lastKnownGoodSnapshot()
                .contentPresets.first?.name,
            "Known Good"
        )

        controller.openNormally()
        controller.recordSuccessfulStart(
            profiles: secondSnapshot,
            plugInChainHealthy: false,
            now: Date(timeIntervalSince1970: 300)
        )
        XCTAssertEqual(
            try controller.lastKnownGoodSnapshot()
                .contentPresets.first?.name,
            "Known Good"
        )
    }


    @MainActor
    func testRecoveryUnreadableStateRequiresSafeLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pr113b-recovery-corrupt-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let url = root.appendingPathComponent("recovery.json")
        try Data("not-json".utf8).write(to: url)

        let controller = ProductRecoveryController(
            store: ProductRecoveryStore(storageURL: url)
        )
        controller.prepareForLaunch()

        XCTAssertTrue(controller.safeLaunchActive)
        XCTAssertTrue(
            controller.safeLaunchReasons.contains(
                .recoveryStateUnreadable
            )
        )
        XCTAssertNotNil(
            controller.lastPersistenceErrorDescription
        )
    }

    @MainActor
    func testRecoveryPlugInBypassIsTransientAcrossCleanLaunch()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pr113b-recovery-bypass-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recovery.json")
        let store = ProductRecoveryStore(storageURL: url)

        let first = ProductRecoveryController(store: store)
        first.prepareForLaunch()
        first.openWithPlugInsBypassed()
        XCTAssertTrue(first.plugInsBypassedForThisLaunch)
        first.markCleanTermination()

        let second = ProductRecoveryController(store: store)
        second.prepareForLaunch()
        XCTAssertFalse(second.safeLaunchActive)
        XCTAssertFalse(second.plugInsBypassedForThisLaunch)
    }

    @MainActor
    func testRecoveryStateIsMachineLocalAndHasNoReleaseAuthority()
        throws {
        let labels = Set(
            Mirror(
                reflecting: ProductRecoveryPersistentState()
            ).children.compactMap { $0.label }
        )
        XCTAssertFalse(labels.contains("physicalAcceptanceComplete"))
        XCTAssertFalse(labels.contains("releaseAcceptanceComplete"))
        XCTAssertFalse(labels.contains("mayMergeIntoMain"))
        XCTAssertFalse(labels.contains("liveFeedForwardANCAuthorized"))
    }


    func testHeadroomAssistantReconstructsPeakBeforeGainRider() {
        var evidence = HeadroomAssistantEvidence()
        let inputLinear =
            Float(pow(10.0, -3.0 / 20.0))

        for index in 0..<20 {
            evidence.ingest(
                inputTruePeakLinear: inputLinear,
                outputTruePeakLinear: inputLinear,
                limiterGainReductionDB: 0.2,
                sustainedLimiterGainReductionDB: 0.1,
                gainRiderAttenuationDB: 2.0,
                truePeakGuardActive: true,
                cumulativeSafetyClampSamples: 0,
                initialSafetyClampSamples: 0,
                elapsedSeconds: 10.0 + Double(index) * 0.1
            )
        }

        XCTAssertEqual(
            evidence.maximumMeasuredInputTruePeakDBTP ?? 0,
            -3.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            evidence.maximumPreRiderTruePeakDBTP ?? 0,
            -1.0,
            accuracy: 0.001
        )
        XCTAssertTrue(evidence.isSufficientForRecommendation)
    }

    func testHeadroomAssistantNeverReclaimsExistingAttenuation() {
        var evidence = HeadroomAssistantEvidence()
        evidence.observationSeconds = 30
        evidence.sampleCount = 30
        evidence.maximumPreRiderTruePeakDBTP = -6
        evidence.maximumMeasuredInputTruePeakDBTP = -6
        evidence.truePeakGuardObserved = true

        let recommendation =
            HeadroomAssistantRecommendation.make(
                evidence: evidence,
                currentHeadroomAttenuationDB: -4,
                targetPeakDBTP: -1
            )

        XCTAssertEqual(
            recommendation.disposition,
            .currentReserveSufficient
        )
        XCTAssertEqual(
            recommendation.recommendedHeadroomAttenuationDB,
            -4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            recommendation.additionalAttenuationDB,
            0,
            accuracy: 0.0001
        )
        XCTAssertFalse(recommendation.canApply)
    }

    func testHeadroomAssistantUsesLargestReserveNeedPlusClampReserve() {
        var evidence = HeadroomAssistantEvidence()
        evidence.observationSeconds = 30
        evidence.sampleCount = 30
        evidence.maximumPreRiderTruePeakDBTP = -0.2
        evidence.maximumMeasuredInputTruePeakDBTP = -0.2
        evidence.maximumSustainedLimiterGainReductionDB = 1.0
        evidence.maximumLimiterGainReductionDB = 2.0
        evidence.safetyClampSamples = 4
        evidence.truePeakGuardObserved = true

        let recommendation =
            HeadroomAssistantRecommendation.make(
                evidence: evidence,
                currentHeadroomAttenuationDB: -1,
                targetPeakDBTP: -1
            )

        // Peak need is 0.8 dB. Sustained-limiter need is 0.5 dB.
        // Use the larger need, then add the 0.5 dB clamp reserve.
        XCTAssertEqual(
            recommendation.peakDrivenAttenuationDB,
            0.8,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            recommendation
                .sustainedLimiterDrivenAttenuationDB,
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            recommendation.safetyClampReserveDB,
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            recommendation.additionalAttenuationDB,
            1.3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            recommendation.recommendedHeadroomAttenuationDB,
            -2.3,
            accuracy: 0.0001
        )
        XCTAssertTrue(recommendation.canApply)
    }

    func testHeadroomAssistantRequiresAuthoritativeRepresentativeEvidence() {
        var tooShort = HeadroomAssistantEvidence()
        tooShort.observationSeconds = 5
        tooShort.sampleCount = 30
        tooShort.maximumPreRiderTruePeakDBTP = 0
        tooShort.truePeakGuardObserved = true

        XCTAssertEqual(
            HeadroomAssistantRecommendation.make(
                evidence: tooShort,
                currentHeadroomAttenuationDB: 0
            ).disposition,
            .insufficientEvidence
        )

        var noTruePeakGuard = tooShort
        noTruePeakGuard.observationSeconds = 30
        noTruePeakGuard.truePeakGuardObserved = false

        XCTAssertEqual(
            HeadroomAssistantRecommendation.make(
                evidence: noTruePeakGuard,
                currentHeadroomAttenuationDB: 0
            ).disposition,
            .insufficientEvidence
        )
    }

    func testHeadroomAssistantRangeLimitFailsConservatively() {
        var evidence = HeadroomAssistantEvidence()
        evidence.observationSeconds = 30
        evidence.sampleCount = 30
        evidence.maximumPreRiderTruePeakDBTP = 6.0
        evidence.maximumMeasuredInputTruePeakDBTP = 6.0
        evidence.maximumSustainedLimiterGainReductionDB = 12.0
        evidence.safetyClampSamples = 10
        evidence.truePeakGuardObserved = true

        let recommendation =
            HeadroomAssistantRecommendation.make(
                evidence: evidence,
                currentHeadroomAttenuationDB: -47.5,
                targetPeakDBTP: -1.0
            )

        XCTAssertEqual(recommendation.disposition, .rangeLimited)
        XCTAssertEqual(
            recommendation.recommendedHeadroomAttenuationDB,
            DSPGainConfiguration
                .headroomAttenuationRange.lowerBound,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            recommendation.additionalAttenuationDB,
            0.5,
            accuracy: 0.0001
        )
        XCTAssertTrue(recommendation.rangeLimited)
        XCTAssertTrue(recommendation.canApply)
    }

    @MainActor
    func testHeadroomAssistantRejectsOpenABAuditionSession()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pr113b-headroom-ab-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = AudioIOEngine()
        let profiles = ProductProfileController(
            engine: engine,
            storageURL:
                root.appendingPathComponent("profiles.json")
        )
        let comparison =
            ContentABComparisonController(profiles: profiles)
        comparison.capture(.a)
        await comparison.audition(.a)
        XCTAssertNotNil(comparison.sessionBaseline)

        let assistant = HeadroomAssistantController(
            engine: engine,
            profiles: profiles,
            abComparison: comparison
        )
        XCTAssertThrowsError(
            try assistant.startObservation()
        ) { error in
            XCTAssertEqual(
                error as? HeadroomAssistantError,
                .abComparisonActive
            )
        }

        await comparison.endAudition(
            restoringBaseline: false
        )
    }

    @MainActor
    func testHeadroomAssistantBoundaryFailsClosedOnContentDrift()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pr113b-headroom-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = AudioIOEngine()
        let profiles = ProductProfileController(
            engine: engine,
            storageURL:
                root.appendingPathComponent("profiles.json")
        )
        let boundary =
            HeadroomAssistantBoundary(profiles: profiles)

        XCTAssertTrue(boundary.matches(profiles))
        try engine.setHeadroomAttenuationDB(-1.0)
        XCTAssertFalse(boundary.matches(profiles))
    }

}
