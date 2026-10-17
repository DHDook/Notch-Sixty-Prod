#!/usr/bin/env python3
"""Batch 3 fast source/ownership contract, not a Swift build substitute."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "NotchSixty/UI/ProductionHeadphoneWorkspace.swift").read_text()
configuration = (
    ROOT / "NotchSixty/Audio/Routing/HeadphoneDeviceProfileConfiguration.swift"
).read_text()
tests = (ROOT / "NotchSixtyTests/HeadphoneCompletionTests.swift").read_text()
project = (ROOT / "NotchSixty.xcodeproj/project.pbxproj").read_text()
assets = (ROOT / "NotchSixty/Audio/Routing/BinauralProfileAsset.swift").read_text()
transport = (
    ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioBinauralHeadphoneTransportSession.swift"
).read_text()
workflow = (ROOT / ".github/workflows/batch3-headphone-completion.yml").read_text()

def need(ok, description):
    if not ok:
        raise AssertionError("Batch 3 headphone completion: " + description)

for token in (
    "perEarEQCard", "channelEQEditor(", "perEarBandControls(",
    "N60_HEADPHONE_MAX_EQ_SECTIONS", "HeadphoneEQResponsePreview.curve(",
    "Import HRTF / SOFA", "org.aes69.sofa",
    "engine.importNormalizedBinauralProfile(from: url)",
    "startAccessingSecurityScopedResource()",
    "HeadphoneCorrectionProposal.load(", "stageLocalProposal(",
    "headroomAttenuationDB", "conservativeRequiredHeadroomDB",
    "sampleRate: rate", "validateStructure(sampleRate: rate)",
    "profile.sampleRate", "It will be converted to the output rate when processing starts",
):
    need(token in ui, "missing production UX/safety item: " + token)
for token in (
    "struct HeadphoneCorrectionProposal: Codable",
    "sourceAttribution", "sourceLicense", "headphoneModel",
    "referenceSampleRate", "fileTooLarge", "64 * 1024",
    "Set(leftBands.map", "Set(rightBands.map",
    "headroomAttenuationDB = max(",
    "enum HeadphoneEQResponsePreview", "N60BiquadDesign(",
    "0.45 * sampleRate", "384_000",
    "HeadphoneDeviceProfileError.binauralProfileSampleRateMismatch",
):
    need(token in configuration, "missing data/precision/safety: " + token)
for token in (
    "testIndependent16BandPerEarEditingPersistsAt384kHz",
    "testPerEarElectricalResponsePreviewUsesActualProductionCoefficients",
    "testProposalRequiresSourceCreditAndExplicitMatchingRate",
    "testProposedLocalCorrectionStagesOnlyInDraftWithSufficientHeadroom",
    "testSofaRateMismatchIsConvertedWithinRendererTapBudget",
    "testDisabledBandsDoNotAddHeadroomOrGain",
):
    need(token in tests, "missing Swift XCTest: " + token)
need(project.count("HeadphoneCompletionTests.swift") >= 4,
     "Xcode target not wired to new Swift tests")
need("NativeSOFAImporter()" in assets and
     'sourceURL.pathExtension.lowercased() == "sofa"' in assets,
     "existing real SOFA importer has been bypassed")
need("sampleRateMismatch" in transport and
     "abs(tapFormat.sampleRate - outputFormat.sampleRate) < 0.5"
     in transport,
     "Core Audio native program/headphone rate boundary lost")
need("PR117D_SOFA_FIXTURE_DIR" in workflow
     and "generate_pr117d_sofa_fixtures.py" in workflow
     and "xcodebuild" in workflow
     and "integration-ci" in workflow,
     "actual-file macOS integration or exact-head trigger missing")
need("automaticResampleSOFA" not in ui and
     "automaticResampleSOFA" not in configuration,
     "new unverified SOFA resampler must not be silently introduced")
# RC hardening: HRIR rate conversion is explicit (UI copy above), control-plane
# only, frequency-response verified, and fails closed over the tap budget.
need("func resampled(to targetSampleRate: Double)" in assets
     and "resampledTapCount" in configuration,
     "HRIR rate conversion must stay the single verified control-plane path")
print("Batch 3 PEQ/SOFA/proposal UI and fail-closed rate/headroom contract: PASS")
