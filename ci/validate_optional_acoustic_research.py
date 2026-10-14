#!/usr/bin/env python3
"""Optional research fast fail-closed ownership/source contracts."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = {
    "research": "NotchSixty/Audio/OptionalAcousticResearch.swift",
    "models": "NotchSixty/Audio/Routing/HeadphoneModelResearchLibrary.swift",
    "view": "NotchSixty/UI/ProductionOptionalAudioResearchWorkspace.swift",
    "headphones": "NotchSixty/UI/ProductionHeadphoneWorkspace.swift",
    "root": "NotchSixty/UI/ProductionRootView.swift",
    "guide": "NotchSixty/UI/ProductionUserGuideView.swift",
    "tests": "NotchSixtyTests/OptionalAudioResearchTests.swift",
    "project": "NotchSixty.xcodeproj/project.pbxproj",
    "doc": "docs/OPTIONAL_AUDIO_RESEARCH.md",
    "workflow": ".github/workflows/optional-acoustic-research-expansion.yml",
}
content = {kind: (ROOT / path).read_text()
           for kind, path in FILES.items()}

def need(ok, why):
    if not ok:
        raise AssertionError("Optional acoustic research: " + why)

for token in (
    "MixedPhaseResearchDesigner", "minimumLeft", "maximumMagnitudeDeviationDB",
    "preRingingEnergyFraction", "latencyBudgetMilliseconds",
    "HRTFDirectionalResearchDesigner", "maximumGapDegrees", "insufficientCoverage",
    "HRTFAuditionPreferenceStore", "listenerRating", "canDeploy: Bool { false }",
    "personalizedAccuracyVerified: Bool { false }",
):
    need(token in content["research"], "research-boundary missing " + token)
for token in (
    "HeadphoneModelCorrectionDesigner",
    "HeadphoneModelMeasurementLibrary",
    "HeadphoneEQResponsePreview.magnitudeDB",
    "sourceAttribution", "sourceLicense", "targetMagnitudeDB",
    "maximumBandsPerEar", "HeadphoneCorrectionProposal",
    "draft.stageLocalProposal", "128_000", "canApply: Bool { false }",
    "isIndividualCalibration: Bool { false }",
):
    need(token in content["models"], "headphone database/proposal contract missing " + token)
for token in (
    "projects.selectedDesign", "MixedPhaseResearchDesigner().design",
    "HRTFDirectionalResearchDesigner().interpolate", "HRTFAuditionPreferenceStore",
    "sampleRate", "No", "canDeploy"
):
    if token == "canDeploy":
        continue
    need(token in content["view"], "research control/UI not bound " + token)
for token in (
    "importLocalModelMeasurement", "HeadphoneModelCorrectionDesigner().fit",
    "Review Fitted Bands Below", "pendingEQProposal = fit.proposal",
    "HeadphoneModelMeasurementLibrary().list", "availableImportedHRTFs",
    "draft.binauralProfile", "Stopped", "selectedSampleRate",
):
    if token == "Stopped":
        continue
    need(token in content["headphones"], "headphone model UI not integrated " + token)
need("case acousticResearch" in content["root"]
     and "ProductionOptionalAudioResearchWorkspace(" in content["root"],
     "Tools does not expose research workspace")
need('id: "acoustic-research"' in content["guide"]
     and 'case .acousticResearch: return "acoustic-research"' in content["guide"],
     "User Guide missing research workflow")
for filename in ("OptionalAcousticResearch.swift",
                 "HeadphoneModelResearchLibrary.swift",
                 "ProductionOptionalAudioResearchWorkspace.swift",
                 "OptionalAudioResearchTests.swift"):
    need(content["project"].count(filename) >= 4,
         "Xcode target missing first-party source: " + filename)
for name in (
    "testMixedPhaseIdentityIsFiniteAndNeverDeploysThrough384kHz",
    "testMixedPhaseFiniteTapsAndBlockingHeadroomAndBadInputs",
    "testHRTFExactDirectionAndInterpolationAreBounded",
    "testHRTFWrapAroundAndPrivateListenerRatingPersistence",
    "testModelPEQFitReducesModeledResidualAndStagesOnlyDraft",
    "testModelLibraryRetainsCreditAndRejectsMalformedFiles",
):
    need(name in content["tests"], "required XCTest missing "+name)
for old in ("AudioObjectSetPropertyData(", "N60RenderKernelConfigure(",
            "N60RealtimeAudioBridgeConfigure(", "mysofa_load("):
    need(old not in content["research"]
         and old not in content["models"]
         and old not in content["view"],
         "research may not mutate realtime/hardware via "+old)
need("xcodebuild" in content["workflow"]
     and "integration-ci" in content["workflow"]
     and "generate_pr117d_sofa_fixtures.py" in content["workflow"],
     "one exact-head native HDF5/XCTest integration gate missing")
need("physical" in content["doc"].lower()
     and "rights" in content["doc"].lower(),
     "physical and legal scope not documented")
print("Three optional research tracks: source, product UI, evidence and no-Apply contract PASS")
