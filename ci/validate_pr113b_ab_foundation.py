#!/usr/bin/env python3
"""PR113B Slice 1 safe A/B snapshot-boundary contract audit."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILES = ROOT / "NotchSixty/State/ProductProfiles.swift"
RECOVERY = ROOT / "NotchSixty/State/ProductRecovery.swift"
HEADROOM = ROOT / "NotchSixty/State/HeadroomAssistant.swift"
BACKUP = ROOT / "NotchSixty/Backup/NotchSixtyBackup.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
HOST = ROOT / "NotchSixty/Audio/AudioUnitHostController.swift"
APP = ROOT / "NotchSixty/NotchSixtyApp.swift"
TOOLBAR = ROOT / "NotchSixty/UI/ProductionProfileToolbar.swift"
ROOT_UI = ROOT / "NotchSixty/UI/ProductionRootView.swift"
METERS_UI = ROOT / "NotchSixty/UI/ProductionMetersView.swift"
GUIDE = ROOT / "NotchSixty/UI/ProductionUserGuideView.swift"
READINESS = ROOT / "ci/build_pr113b_remote_product_finish_readiness.py"
LAB_REPORT = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabReport.swift"
LAB_UI = ROOT / "NotchSixty/UI/ProductionSpeakerMeasurementLabWorkspace.swift"
LAB_TESTS = ROOT / "NotchSixtyTests/SpeakerMeasurementLabReportTests.swift"
TESTS = ROOT / "NotchSixtyTests/ProductionInformationArchitectureTests.swift"
DOC = ROOT / "docs/PR113B_WORLD_CLASS_PRODUCT_FINISH.md"
ROADMAP = ROOT / "docs/ROADMAP.md"
WORKFLOW = ROOT / ".github/workflows/pr113b-world-class-product-finish.yml"

for path in (
    PROFILES, RECOVERY, HEADROOM, BACKUP, PROJECT, ENGINE, HOST, APP, TOOLBAR,
    ROOT_UI, METERS_UI, GUIDE, READINESS, LAB_REPORT, LAB_UI, LAB_TESTS, TESTS,
    DOC, ROADMAP, WORKFLOW
):
    assert path.is_file(), f"PR113B Slice 1 missing artifact: {path}"

profiles = PROFILES.read_text(encoding="utf-8")
recovery = RECOVERY.read_text(encoding="utf-8")
headroom = HEADROOM.read_text(encoding="utf-8")
backup = BACKUP.read_text(encoding="utf-8")
project = PROJECT.read_text(encoding="utf-8")
engine = ENGINE.read_text(encoding="utf-8")
host = HOST.read_text(encoding="utf-8")
app = APP.read_text(encoding="utf-8")
toolbar = TOOLBAR.read_text(encoding="utf-8")
root_ui = ROOT_UI.read_text(encoding="utf-8")
meters_ui = METERS_UI.read_text(encoding="utf-8")
guide = GUIDE.read_text(encoding="utf-8")
readiness = READINESS.read_text(encoding="utf-8")
lab_report = LAB_REPORT.read_text(encoding="utf-8")
lab_ui = LAB_UI.read_text(encoding="utf-8")
lab_tests = LAB_TESTS.read_text(encoding="utf-8")
tests = TESTS.read_text(encoding="utf-8")
doc = DOC.read_text(encoding="utf-8")
roadmap = ROADMAP.read_text(encoding="utf-8")
workflow = WORKFLOW.read_text(encoding="utf-8")

start = profiles.index("enum ContentABSlot:")
end = profiles.index("struct PlaybackSystemControlState:")
ab = profiles[start:end]

for token in (
    "enum ContentABSlot:",
    "struct ContentABAuditionState:",
    "var stereoEQ: StereoEQConfiguration",
    "var inputPreampDB: Double",
    "var headroomAttenuationDB: Double",
    "var dynamics: DynamicsConfiguration",
    "func merging(into current: ContentPresetState)",
    "struct ContentABSystemBoundary:",
    "selectedSystemProfileID: UUID?",
    "systemState: PlaybackSystemState",
    "case playbackSystemChanged",
    "case playbackSystemStateChanged",
    "struct ContentABSnapshot:",
    "final class ContentABComparisonController: ObservableObject",
    "func capture(_ slot: ContentABSlot)",
    "func clear(_ slot: ContentABSlot)",
    "func clearAll()",
    "func swapSnapshots()",
    "func compatibility(for slot: ContentABSlot)",
    "func currentContentDiffers(from slot: ContentABSlot)",
    "struct ContentABLoudnessMatchPlan:",
    "static let maximumAttenuationDB = 12.0",
    "levelMatchingEnabled",
    "loudnessMatchPlan",
    "func audition(_ slot: ContentABSlot) async",
    "func endAudition(restoringBaseline: Bool = true) async",
):
    assert token in ab, f"PR113B A/B foundation missing {token}"

# The safe audition value itself must remain exactly the deterministic
# content-facing engine state. Audio Unit topology and all system/hardware
# domains are excluded.
state_start = ab.index("struct ContentABAuditionState:")
state_end = ab.index("enum ContentABSystemCompatibility:")
audition_state = ab[state_start:state_end]
for forbidden in (
    "outputRouting",
    "outputDeviceProfile",
    "headphoneDeviceProfile",
    "bassManagement",
    "roomCorrection",
    "speakerDriverProcessing",
    "speakerIR",
    "associatedOutputUID",
    "outputGainDB",
):
    assert forbidden not in audition_state, (
        f"PR113B A/B audition state gained forbidden system field: {forbidden}"
    )

# Slice 1 must not gain live mutation authority. AudioUnitRack is mentioned only
# to state/preserve its exclusion from the snapshot payload.
for forbidden_call in (
    "selectOutput(",
    "replacePlaybackControlConfiguration(",
    "replaceBassManagementConfiguration(",
    "replaceMultiOutputRoutingConfiguration(",
    "replaceOutputDeviceProfileConfiguration(",
    "replaceHeadphoneDeviceProfileConfiguration(",
    "replaceSpeakerDriverProcessingConfiguration(",
    "replaceRoomCorrectionConfiguration(",
    "replaceSpeakerIRConfiguration(",
    "replaceRackConfiguration(",
    "applyContentStateWithoutAudioUnitRack(",
):
    assert forbidden_call not in ab, (
        f"PR113B Slice 1 gained live mutation authority: {forbidden_call}"
    )

for token in (
    "testABAuditionStateContainsOnlySafeContentDSP",
    "testABAuditionMergePreservesCurrentAudioUnitRack",
    "testABSystemBoundaryFailsClosedOnIdentityAndStateDrift",
    "testABSlotsHaveStableIdentityAndOpposites",
    "testABLoudnessMatchOnlyAttenuatesTheLouderCapture",
    "testABLoudnessMatchIsBoundedAndRequiresValidSignal",
    "testABSnapshotCanCarryMeasuredLoudnessWithoutBroadeningAuditionState",
):
    assert token in tests, f"PR113B A/B regression missing {token}"


for token in (
    "func transitionContentAuditionState(",
    "additionalInputAttenuationDB: Double = 0",
    "try session.transitionDSPGraph(graph)",
    "renderBassManagementConfiguration()",
    "attachActiveRoomCorrectionProgramIfNeeded(",
    "attachActiveSpeakerIRProgramIfNeeded(",
    "applyAudioUnitRackLatency(to: &graph)",
):
    assert token in engine, f"PR113B Slice 2 engine contract missing {token}"

# The A/B executor may only call the dedicated content-domain transition.
# It must not gain direct system/hardware mutation authority.
controller_start = ab.index("final class ContentABComparisonController")
controller = ab[controller_start:]
for forbidden_call in (
    "selectOutput(",
    "replaceBassManagementConfiguration(",
    "replaceMultiOutputRoutingConfiguration(",
    "replaceOutputDeviceProfileConfiguration(",
    "replaceHeadphoneDeviceProfileConfiguration(",
    "replaceSpeakerDriverProcessingConfiguration(",
    "replaceRoomCorrectionConfiguration(",
    "replaceSpeakerIRConfiguration(",
    "replaceRackConfiguration(",
):
    assert forbidden_call not in controller, (
        f"PR113B A/B controller gained hardware/system authority: {forbidden_call}"
    )

for token in (
    "let abComparison: ContentABComparisonController",
    "ContentABComparisonController(profiles: profiles)",
):
    assert token in app, f"PR113B product ownership missing {token}"

for token in (
    "abComparisonControl",
    'Label("A/B", systemImage: "arrow.left.arrow.right")',
    '"Capture Current as A"',
    '"Capture Current as B"',
    '"Measured Level Match"',
    '"Swap A / B"',
    '"Exit A/B and Restore"',
    "await comparison.audition(.a)",
    "await comparison.audition(.b)",
):
    assert token in toolbar, f"PR113B A/B production UI missing {token}"


for token in (
    "struct PlaybackSystemHardwareMappingRequirement:",
    "struct ProductProfileBackupSnapshot:",
    "var referencedHardwareDeviceUIDs: Set<String>",
    "case hardwareMappingRequired(profile: String)",
    "func makeBackupSnapshot()",
    "func restoreBackupSnapshot(",
    "availableOutputUIDs: Set<String>? = nil",
    "recomputeHardwareRequirements: Bool = true",
    "func confirmSelectedSystemHardwareMapping()",
    "hardwareMappingRequiredSystemIDs",
):
    assert token in profiles, f"PR113B Slice 3 profile backup contract missing {token}"

for token in (
    "struct NotchSixtyBackupPreferences:",
    "struct NotchSixtyBackupManifestEntry:",
    "struct NotchSixtyBackupManifest:",
    "struct NotchSixtyBackupBundle:",
    "final class NotchSixtyBackupService",
    "func exportData(",
    "func inspect(_ data: Data)",
    "func restore(",
    "SHA256.hash(data: data)",
    "roomCorrectionProjects",
    "measurementLabSessions",
    "binauralAssets",
):
    assert token in backup, f"PR113B Slice 3 backup service missing {token}"

# General backup must never recreate physical acceptance authority.
for forbidden in (
    "HardwareAcceptanceCampaign",
    "HardwareAcceptanceCampaignStore",
    "physicalAcceptanceComplete",
    "mayMergeIntoMain",
):
    assert forbidden not in backup, (
        f"PR113B backup gained acceptance authority/evidence coupling: {forbidden}"
    )

for token in (
    "NotchSixtyBackup.swift in Sources",
    "NotchSixtyBackup.swift",
):
    assert token in project, f"PR113B backup target membership missing {token}"

assert "ProductBackup.swift" not in project
assert not (ROOT / "NotchSixty/State/ProductBackup.swift").exists()

for token in (
    "let backup: NotchSixtyBackupService",
    "NotchSixtyBackupService(",
    'title: "Backup & Restore"',
    '"Save Backup…"',
    '"Restore Backup…"',
    '"n60backup"',
    "product.backup.restore(data)",
    "preferences.makeBackupSnapshot()",
    "preferences.restoreBackupSnapshot(",
):
    assert token in app, f"PR113B backup production UI missing {token}"

for token in (
    "Needs Mapping",
    '"Confirm Hardware Mapping"',
    "selectedSystemHardwareMappingRequirement",
):
    assert token in toolbar, f"PR113B hardware remapping UI missing {token}"

for token in (
    "testBackupRestoreMarksUnavailablePlaybackHardwareForMapping",
    "testBackupRestoreKeepsKnownHardwareEligibleWithoutRemapping",
    "testBackupPreferencesExcludeOSOwnedLaunchState",
    "testBackupInspectionRejectsDomainTampering",
    "testLocalOfflineRoutingDoesNotAcquireImportMappingGate",
):
    assert token in tests, f"PR113B Slice 3 regression missing {token}"


for token in (
    "struct SpeakerMeasurementLabFullFidelityExportEnvelope:",
    "measurementOnly: Bool = true",
    "canDeploy: Bool = false",
    "containsRawImpulseData: Bool = true",
    "containsFullTransferFunctionData: Bool = true",
    "struct SpeakerMeasurementLabFullFidelityExporter: Sendable",
    "func fullJSONData(",
    "func transferCSVData(",
    "func impulseCSVData(",
    "func frdData(",
    "func impulseWAVData(",
    "magnitude_domain=transfer_function_db_not_absolute_spl",
    "WAVE_FORMAT_IEEE_FLOAT",
    'Locale(identifier: "en_US_POSIX")',
    'appendASCII("fact", to: &data)',
):
    assert token in lab_report, (
        f"PR113B Slice 4 full-fidelity Lab exporter missing {token}"
    )

for forbidden in (
    "replaceSelectedSystem",
    "approveAndApply",
    "setRoomCorrection",
    "engine.start",
    "engine.stop",
):
    full_start = lab_report.index(
        "struct SpeakerMeasurementLabFullFidelityExporter: Sendable"
    )
    full_end = lab_report.index(
        "extension SpeakerMeasurementLabSessionStore",
        full_start,
    )
    assert forbidden not in lab_report[full_start:full_end], (
        f"PR113B Slice 4 exporter gained mutation authority: {forbidden}"
    )

for token in (
    '"Compact Report"',
    '"Full-Fidelity Data"',
    '"Export Full JSON"',
    '"Export Transfer CSV"',
    '"Export Impulse CSV"',
    '"Export Capture FRD"',
    '"Export Impulse WAV"',
    "SpeakerMeasurementLabFullFidelityExporter()",
):
    assert token in lab_ui, (
        f"PR113B Slice 4 production Lab UI missing {token}"
    )

for token in (
    "testFullJSONPreservesRawEvidenceAndSafetyBoundary",
    "testDetailedCSVsPreserveTransferAndImpulseSamples",
    "testFRDPreservesTransferGridWithoutClaimingAbsoluteSPL",
    "testImpulseWAVIsMonoFloat32AtCaptureRate",
    "testDetailedNumericExportsUsePOSIXDecimalPoint",
):
    assert token in lab_tests, (
        f"PR113B Slice 4 Lab export regression missing {token}"
    )

assert (
    "-only-testing:NotchSixtyTests/SpeakerMeasurementLabReportTests"
    in workflow
), "PR113B Slice 4 Lab export tests are not in the targeted CI gate"

# Slice 5 Safe Launch / Recovery Mode is machine-local and fail-closed.
for token in (
    "enum ProductRecoveryFailureKind:",
    "enum ProductSafeLaunchReason:",
    "struct ProductRecoveryPersistentState:",
    "var launchSessionOpen = false",
    "var consecutiveAudioStartFailures = 0",
    "var consecutivePlugInFailures = 0",
    "var lastKnownGoodProfiles: ProductProfileBackupSnapshot?",
    "struct ProductRecoveryStore: Sendable",
    '"Recovery"',
    '"recovery-state.json"',
    "final class ProductRecoveryController: ObservableObject",
    "static let failureThreshold = 2",
    "func prepareForLaunch(",
    "func openNormally()",
    "func openWithPlugInsBypassed()",
    "func recordStartFailure(",
    "func recordSuccessfulStart(",
    "func lastKnownGoodSnapshot()",
    "func markCleanTermination()",
    "case lastKnownGoodRequiresHardwareMapping(Int)",
    "case recoveryRequiresIdle",
):
    assert token in recovery, (
        f"PR113B Slice 5 recovery state missing {token}"
    )

for forbidden in (
    "physicalAcceptanceComplete",
    "releaseAcceptanceComplete",
    "liveFeedForwardANCAuthorized",
    "mayMergeIntoMain",
    "HardwareAcceptanceCampaign",
):
    assert forbidden not in recovery, (
        f"PR113B recovery gained forbidden authority: {forbidden}"
    )

assert "ProductRecovery" not in backup, (
    "Machine-local recovery state leaked into general backup"
)

for token in (
    "ProductRecovery.swift in Sources",
    "ProductRecovery.swift",
):
    assert token in project, (
        f"PR113B recovery target membership missing {token}"
    )

for token in (
    "let recovery: ProductRecoveryController",
    "recovery.prepareForLaunch()",
    "if !recovery.safeLaunchActive",
    "func openNormallyFromSafeLaunch() throws",
    "func openWithPlugInsBypassedFromSafeLaunch() throws",
    "func restoreLastKnownGoodFromSafeLaunch() throws",
    "try audioEngine.stageAudioUnitRackForNextStart(nil)",
    "recovery.recordStartFailure(",
    "recovery.recordSuccessfulStart(",
    "func diagnosticsReport(",
    "recovery.markCleanTermination()",
    "NSApplication.willTerminateNotification",
    "report.hardwareMappingRequiredCount == 0",
    "lastKnownGoodRequiresHardwareMapping(",
    "!audioUnitHost.activeRackHasQuarantinedComponent",
):
    assert token in app, f"PR113B Slice 5 product integration missing {token}"

for token in (
    "func applySelectedLayersNow() throws",
    "hardwareMappingRequirement(for: system.id) == nil",
    'profileName: "Recovery rollback"',
):
    assert token in profiles, (
        f"PR113B recovery selected-layer contract missing {token}"
    )

for token in (
    "var activeRackHasQuarantinedComponent: Bool",
    "!slot.bypassed",
    "quarantine.isQuarantined(component)",
):
    assert token in host, (
        f"PR113B Slice 5 active-rack health contract missing {token}"
    )

for token in (
    "ProductSafeLaunchSheet",
    '"Safe Launch"',
    '"Open Normally"',
    '"Open with Plug-ins Bypassed This Launch"',
    '"Restore Last Known Good"',
    '"Copy Diagnostics"',
    "try await product.startProcessing()",
):
    assert token in root_ui, (
        f"PR113B Slice 5 production recovery UI missing {token}"
    )

assert "try? engine.start()" not in root_ui, (
    "Main production toolbar bypasses ProductController.startProcessing"
)

for token in (
    "testRecoveryDetectsUncleanPriorLaunchButNotCleanTermination",
    "testRecoveryRepeatedFailuresTriggerSafeLaunchThreshold",
    "testRecoveryOnlyHealthyNormalStartUpdatesLastKnownGood",
    "testRecoveryUnreadableStateRequiresSafeLaunch",
    "testRecoveryPlugInBypassIsTransientAcrossCleanLaunch",
    "testRecoveryStateIsMachineLocalAndHasNoReleaseAuthority",
):
    assert token in tests, (
        f"PR113B Slice 5 recovery regression missing {token}"
    )


# Slice 6 — Headroom Assistant. Analysis consumes existing authoritative
# protection telemetry and can only add reserve after an explicit Apply.
for token in (
    "struct HeadroomAssistantBoundary:",
    "struct HeadroomAssistantEvidence:",
    "maximumPreRiderTruePeakDBTP",
    "gainRiderAttenuationDB",
    "truePeakGuardObserved",
    "struct HeadroomAssistantRecommendation:",
    "currentReserveSufficient",
    "recommendAdditionalAttenuation",
    "rangeLimited",
    "static let defaultTargetPeakDBTP = -1.0",
    "max(peakNeed, limiterNeed) + clampReserve",
    "final class HeadroomAssistantController: ObservableObject",
    "func startObservation(",
    "case abComparisonActive",
    "abAuditionSessionActive",
    "func applyRecommendation() throws",
    "func revertAppliedRecommendation() throws",
    "canRevertAppliedRecommendation",
    "appliedRecommendationPendingDecision",
    "boundary.matches(profiles)",
    "engine.transitionHeadroomAttenuationDB(",
):
    assert token in headroom, (
        f"PR113B Slice 6 Headroom Assistant contract missing {token}"
    )

assert headroom.count("engine.transitionHeadroomAttenuationDB(") == 2, (
    "PR113B Slice 6 must keep exactly two explicit mutation paths: Apply and Undo"
)

assert headroom.count("diagnostics.truePeakGuardActive") >= 2, (
    "PR113B Slice 6 must verify authoritative True Peak Guard both at observation start and while sampling"
)

for token in (
    "func transitionHeadroomAttenuationDB(",
    "session.transitionDSPGraph(graph)",
    "it does not save/overwrite the selected Content Preset",
):
    assert token in engine, (
        f"PR113B Slice 6 live transition contract missing {token}"
    )

for token in (
    "ProductionMetersView(",
    "assistant: product.headroomAssistant",
):
    assert token in root_ui, (
        f"PR113B Slice 6 Meters integration missing {token}"
    )

for token in (
    "let headroomAssistant: HeadroomAssistantController",
    "HeadroomAssistantController(",
    "abComparison: abComparison",
):
    assert token in app, (
        f"PR113B Slice 6 product/A-B ownership missing {token}"
    )

for token in (
    "@ObservedObject var assistant: HeadroomAssistantController",
    '"Headroom Assistant"',
    '"Observe Program"',
    '"Stop & Review"',
    '"Apply Additional Headroom"',
    '"Undo Applied Headroom"',
    '"Keep & Clear"',
    '"Target True Peak"',
    '"Pre-Rider True Peak"',
    "never removes existing headroom",
    "never auto-adjusts in the background",
    "save or update the Content Preset separately",
):
    assert token in meters_ui, (
        f"PR113B Slice 6 production UI missing {token}"
    )

for token in (
    "testHeadroomAssistantReconstructsPeakBeforeGainRider",
    "testHeadroomAssistantNeverReclaimsExistingAttenuation",
    "testHeadroomAssistantUsesLargestReserveNeedPlusClampReserve",
    "testHeadroomAssistantRequiresAuthoritativeRepresentativeEvidence",
    "testHeadroomAssistantRangeLimitFailsConservatively",
    "testHeadroomAssistantRejectsOpenABAuditionSession",
    "testHeadroomAssistantBoundaryFailsClosedOnContentDrift",
):
    assert token in tests, (
        f"PR113B Slice 6 regression missing {token}"
    )


# Slice 7 — non-intrusive Getting Started and cumulative remote closeout.
getting_start = guide.index('id: "getting-started"')
getting_end = guide.index('id: "dashboard"', getting_start)
getting_started = guide[getting_start:getting_end]

for token in (
    '"1. Grant only the permissions you need"',
    "Screen & System Audio Recording",
    "Measurement Microphone",
    '"2. Choose the real output and Playback System"',
    "Needs Mapping",
    "conservative listening level",
    '"3. Make first sound deliberately"',
    "never starts merely because Notch Sixty launches",
    "Headroom Assistant",
    '"4. Choose or create your first Content Preset"',
    "Use A/B",
    '"5. Add measurement and calibration only when useful"',
    "Measurement Lab",
    "PR112 physical hardware-acceptance",
    '"6. Protect a good setup"',
    ".n60backup",
    "Safe Launch",
    "Restore Last Known Good",
    "Copy Diagnostics",
):
    assert token in getting_started, (
        f"PR113B Slice 7 Getting Started coverage missing {token}"
    )

for token in (
    "testGettingStartedCoversNonIntrusiveFirstSessionPath",
    '"getting-started"',
    '"safe launch"',
    '"restore last known good"',
    '"physical hardware-acceptance"',
):
    assert token in tests, (
        f"PR113B Slice 7 Getting Started regression missing {token}"
    )

for token in (
    '"schema": "PR113B_REMOTE_PRODUCT_FINISH_READINESS"',
    '"remoteProductFinishComplete": True',
    '"abComparisonAvailable": True',
    '"backupRestoreAvailable": True',
    '"fullFidelityMeasurementExportAvailable": True',
    '"safeLaunchRecoveryAvailable": True',
    '"headroomAssistantAvailable": True',
    '"gettingStartedCoverageComplete": True',
    '"physicalAcceptanceComplete": False',
    '"releaseAcceptanceComplete": False',
    '"liveFeedForwardANCAuthorized": False',
    '"mayMergeIntoMain": False',
    '"physicalEvidenceSuppliedByCI": False',
):
    assert token in readiness, (
        f"PR113B Slice 7 readiness manifest missing {token}"
    )

for token in (
    "build_pr113b_remote_product_finish_readiness.py",
    "pr113b-remote-product-finish-readiness",
    "actions/upload-artifact@v4",
):
    assert token in workflow, (
        f"PR113B Slice 7 closeout workflow missing {token}"
    )

for token in (
    "Slice 1 — Safe A/B comparison foundation",
    "Audio Unit rack topology",
    "Playback System boundary",
    "No live mutation in Slice 1",
    "Slice 2 — Click-free, measured-level A/B audition",
    "attenuation-only",
    "Exit A/B and Restore",
    "Slice 3 — Full Notch Sixty backup & restore",
    "Slice 4 — Full-fidelity Measurement Lab export",
    "Slice 5 — Safe Launch / Recovery Mode",
    "Restore Last Known Good",
    "Plug-ins Bypassed This Launch",
    "machine-local",
    "32-bit IEEE-float WAV",
    "transfer-function dB",
    "binaural",
    "Needs Mapping",
    "SHA-256",
    "OPEN, DRAFT and UNMERGED",
):
    assert token in doc, f"PR113B Slice 1 documentation missing {token}"

for token in (
    "Current execution status — PR113B",
    "safe A/B comparison foundation",
    "full Notch Sixty backup & restore bundle",
    "full-fidelity Measurement Lab export",
    "Safe Launch / Recovery Mode",
    "Headroom Assistant",
    "Getting Started",
):
    assert token in roadmap, f"PR113B roadmap missing {token}"

for token in (
    "validate_pr113b_ab_foundation.py",
    "validate_pr113_production_ux.py",
    "ProductionInformationArchitectureTests",
):
    assert token in workflow, f"PR113B workflow missing {token}"

print("PR113B Slices 1–7 world-class product closeout contract: PASS")
