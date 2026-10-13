#!/usr/bin/env python3
"""PR113 production UX and in-app guide contract audit."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "NotchSixty/NotchSixtyApp.swift"
GUIDE = ROOT / "NotchSixty/UI/ProductionUserGuideView.swift"
ROOT_VIEW = ROOT / "NotchSixty/UI/ProductionRootView.swift"
EQUALIZER = ROOT / "NotchSixty/UI/ProductionEqualizerView.swift"
DYNAMICS = ROOT / "NotchSixty/UI/ProductionDynamicsView.swift"
TESTS = ROOT / "NotchSixtyTests/ProductionInformationArchitectureTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR113_PRODUCTION_UX.md"
ROADMAP = ROOT / "docs/ROADMAP.md"
WORKFLOW = ROOT / ".github/workflows/pr113-production-ux.yml"
MANIFEST = ROOT / "ci/build_pr113_remote_ux_readiness.py"

for path in (
    APP, GUIDE, ROOT_VIEW, EQUALIZER, DYNAMICS, TESTS,
    PROJECT, DOC, ROADMAP, WORKFLOW, MANIFEST
):
    assert path.is_file(), f"PR113 missing artifact: {path}"

app = APP.read_text(encoding="utf-8")
guide = GUIDE.read_text(encoding="utf-8")
root_view = ROOT_VIEW.read_text(encoding="utf-8")
equalizer = EQUALIZER.read_text(encoding="utf-8")
dynamics = DYNAMICS.read_text(encoding="utf-8")
tests = TESTS.read_text(encoding="utf-8")
project = PROJECT.read_text(encoding="utf-8")
doc = DOC.read_text(encoding="utf-8")
roadmap = ROADMAP.read_text(encoding="utf-8")
workflow = WORKFLOW.read_text(encoding="utf-8")
manifest = MANIFEST.read_text(encoding="utf-8")

for token in (
    "TabView(selection: $reference.selectedTab)",
    'Label("General", systemImage: "gearshape")',
    "ProductionUserGuideView(navigator: reference)",
    'Label("User Guide", systemImage: "book.closed")',
    "ProductionDSPReferenceView(navigator: reference)",
    'Label("DSP Reference", systemImage: "function")',
    "private var generalSettings: some View",
    '.navigationTitle("Preferences & Reference")',
    'minWidth: 760',
    'idealWidth: 960',
):
    assert token in app, f"PR113 Settings IA missing {token}"

for token in (
    "enum ProductionUserGuideCategory:",
    "enum ProductionUserGuideMathScope:",
    "case coreEquation",
    "case implementationRelationship",
    "case diagnosticModel",
    "struct ProductionUserGuideFormula:",
    "struct ProductionUserGuideArticle:",
    "enum ProductionUserGuideCatalog",
    "static let articles:",
    "static func search(",
    "static func articleID(for section: ProductionSection)",
    "static var uncoveredProductionSections:",
    "enum ProductionWorkflowTerm:",
    "enum ProductionReferenceTab:",
    "final class ProductionReferenceNavigator: ObservableObject",
    "struct ProductionReferenceHelpButton: View",
    "struct ProductionUserGuideView: View",
    "struct ProductionDSPReferenceView: View",
    '"Math & DSP Details"',
    '"Core equation"',
    '"Implementation relationship"',
    '"Diagnostic / model definition"',
    '"minimum-phase-fir"',
    "causal minimum-phase",
    "ProductionWorkflowTerm.allCases",
    ".accessibilityLabel(label)",
):
    assert token in guide, f"PR113 guide architecture missing {token}"

for article_id in (
    "getting-started",
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
    "hardware-acceptance",
    "plugins",
    "settings",
    "workflow-glossary",
    "math-reference",
):
    assert f'id: "{article_id}"' in guide, f"PR113 guide missing {article_id}"

for math_token in (
    "H(z) =",
    "y[n] = Σ",
    "τ = (N−1) / (2fₛ)",
    "y_dB = T + (x_dB − T)/R",
    "RMS = √",
    "Crest_dB = 20 · log₁₀",
    "ρ = Σ(L·R)",
    "H_LR,2m(s) = [H_BW,m(s)]²",
    "φ(f) = 2πfΔt",
    "H(f) = Y(f) / X(f)",
    "h[n] = IFFT{H(f)}",
    "B = t_preview",
    "σ_LF = √",
):
    assert math_token in guide, f"PR113 guide math missing {math_token}"

for safety_token in (
    "CI test labeled PASS cannot satisfy",
    "Protected Low/Mid/High driver protocols",
    "Never connect a speaker-level amplifier output directly",
    "Software plausibility checks never replace physical speaker-safety acceptance",
):
    assert safety_token in guide, f"PR113 safety language missing {safety_token}"

for forbidden in (
    "AudioIOEngine",
    "engine.start(",
    "engine.stop(",
    "replaceSelectedSystem",
    "approveAndApply(",
    "setRoomCorrection",
):
    assert forbidden not in guide, f"PR113 guide gained runtime authority: {forbidden}"

for token in (
    "testUserGuideCoversEveryProductionWorkspace",
    "testUserGuideIdentifiersAreStableAndUnique",
    "testUserGuideSearchFindsFeatureMathAndSafetyLanguage",
    "testMathBearingGuideArticlesExplainFormulaScope",
    "testGuideKeepsSoftwareAndPhysicalAuthorityDistinct",
    "testReferenceNavigatorRoutesGuideAndDSPDeepLinks",
    "testWorkflowVocabularySeparatesDraftAndLiveRecoverySemantics",
    "testReferenceSearchFindsWorkflowAndDSPGlossaryTerms",
    "testRoomCorrectionReferenceMatchesMinimumPhaseImplementation",
):
    assert token in tests, f"PR113 guide regression missing {token}"

for token in (
    'Label("Preferences & Reference", systemImage: "gearshape")',
    "ProductionReferenceHelpButton(",
    "ProductionUserGuideCatalog.articleID(for: selection ?? .dashboard)",
):
    assert token in root_view, f"PR113 contextual reference link missing {token}"

for token in (
    'formulaID: "biquad"',
    'destination: .dspReference',
):
    assert token in equalizer, f"PR113 EQ reference deep-link missing {token}"

for token in (
    'referenceFormulaID: "compressor-ratio"',
    'referenceFormulaID: "expander-ratio"',
    'referenceFormulaID: "time-constant"',
):
    assert token in dynamics, f"PR113 Dynamics reference deep-link missing {token}"

assert "ProductionUserGuideView.swift in Sources" in project
assert "ProductionUserGuideView.swift" in project

for token in (
    "Slice 1",
    "User Guide",
    "DSP Reference",
    "Slice 2",
    "Workflow consistency",
    "Accessibility",
    "OPEN, DRAFT and UNMERGED",
):
    assert token in doc, f"PR113 documentation missing {token}"

assert "PR113" in roadmap
assert "validate_pr112a_hardware_acceptance.py" in workflow
assert "ProductionInformationArchitectureTests" in workflow
assert "build_pr113_remote_ux_readiness.py" in workflow
assert "pr113-remote-ux-readiness" in workflow

for key in (
    '"remoteUXSoftwareComplete": True',
    '"preferencesAndReferenceAvailable": True',
    '"userGuideCoverageComplete": True',
    '"dspReferenceAvailable": True',
    '"contextualReferenceLinksAvailable": True',
    '"workflowVocabularyStandardized": True',
    '"physicalAcceptanceComplete": False',
    '"releaseAcceptanceComplete": False',
    '"liveFeedForwardANCAuthorized": False',
    '"mayMergeIntoMain": False',
    '"physicalEvidenceSuppliedByCI": False',
):
    assert key in manifest, f"PR113 readiness manifest authority changed: {key}"

# PR113 is a presentation/control-plane milestone. Its guide must map the
# production IA without adding another navigation destination to the main
# sidebar.
assert "case userGuide" not in root_view
assert ".userGuide" not in root_view

print("PR113 production UX / user-guide contract: PASS")
