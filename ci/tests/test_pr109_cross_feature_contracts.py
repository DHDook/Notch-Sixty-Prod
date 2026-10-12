#!/usr/bin/env python3
"""Negative integration-guard tests, intentionally without hardware."""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "ci/validate_pr109_cross_feature_contracts.py"
SPEC = importlib.util.spec_from_file_location("pr109_cross_feature", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

class CrossFeatureContractsTests(unittest.TestCase):
    def setUp(self):
        self.sources = MODULE.read_sources()

    def test_live_cumulative_feature_contracts(self):
        self.assertEqual(MODULE.audit_sources(self.sources), [])

    def test_peq_and_fir_cannot_be_stacked_without_validation(self):
        path = "NotchSixty/Audio/SpeakerOptimizerPEQDeployment.swift"
        self.sources[path] = self.sources[path].replace(
            "profile.speakerOptimizerFIR == nil", "true")
        self.assertIn("profile.speakerOptimizerFIR", str(MODULE.audit_sources(self.sources)))

    def test_fir_cannot_ignore_peq_ownership(self):
        path = "NotchSixty/Audio/SpeakerOptimizerFIRDeployment.swift"
        self.sources[path] = self.sources[path].replace(
            "profile.speakerOptimizerPEQ == nil", "true")
        self.assertIn("profile.speakerOptimizerPEQ", str(MODULE.audit_sources(self.sources)))

    def test_single_and_multi_sub_ownership_cannot_overlap(self):
        path = "NotchSixty/Audio/Routing/OutputDeviceProfileConfiguration.swift"
        self.sources[path] = self.sources[path].replace(
            "&& coherentMultiSubwooferAlignment != nil) else",
            "&& false) else")
        self.assertIn("coherentMultiSubwooferAlignment", str(
            MODULE.audit_sources(self.sources)))

    def test_render_fir_cannot_follow_bass_management(self):
        path = "NotchSixty/Audio/Realtime/N60LiveNChannelRenderCore.h"
        render = self.sources[path]
        mark = "static inline bool N60LiveNChannelRenderProcessFrame("
        first, body = render.split(mark, 1)
        fir = "N60ProgramFIRRuntimeProcessFrame("
        bass = "N60MultichannelBassManagementProcessFrame("
        # Reverse the two function identifiers inside the realtime body.
        body = body.replace(fir, "PR109_SWAP", 1).replace(
            bass, fir, 1).replace("PR109_SWAP", bass, 1)
        self.sources[path] = first + mark + body
        problems = MODULE.audit_sources(self.sources)
        self.assertTrue(any("live DSP order" in problem for problem in problems))

    def test_protected_measurement_requires_limiter(self):
        path = "NotchSixty/Audio/SpeakerMeasurementLabProtectedExcitation.swift"
        self.sources[path] = self.sources[path].replace(
            "guard targetDriver.limiterEnabled else", "guard true else")
        self.assertIn("targetDriver.limiterEnabled", str(
            MODULE.audit_sources(self.sources)))

    def test_fresh_verification_cannot_be_skipped(self):
        path = "NotchSixty/Audio/SpeakerOptimizerFIRApplyTransaction.swift"
        self.sources[path] = self.sources[path].replace(
            "requiresMeasuredVerification", "verificationOptional")
        self.assertIn("requiresMeasuredVerification", str(
            MODULE.audit_sources(self.sources)))

    def test_missing_source_rejected(self):
        self.sources.pop("NotchSixty/Audio/Routing/OutputDeviceProfileConfiguration.swift")
        self.assertTrue(any("missing source" in p for p in MODULE.audit_sources(self.sources)))

if __name__ == "__main__":
    unittest.main()
