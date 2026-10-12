#!/usr/bin/env python3
"""Contract tests for PR109's read-only, fail-closed milestone manifest."""
import copy
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "pr109_stack", ROOT / "ci/validate_pr109_integration_stack.py")
assert SPEC and SPEC.loader
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)
BASE = json.loads((ROOT / "ci/pr109_stack_manifest.json").read_text(encoding="utf-8"))


class StackManifestTests(unittest.TestCase):
    def test_valid_pinned_complete_stack(self):
        module.validate_manifest(BASE)

    def test_missing_dependency_fails(self):
        data = copy.deepcopy(BASE)
        del data["milestones"][4]
        with self.assertRaises(ValueError):
            module.validate_manifest(data)

    def test_out_of_order_dependency_fails(self):
        data = copy.deepcopy(BASE)
        data["milestones"][3], data["milestones"][4] = (
            data["milestones"][4], data["milestones"][3])
        with self.assertRaises(ValueError):
            module.validate_manifest(data)

    def test_wrong_github_pr_number_fails(self):
        data = copy.deepcopy(BASE)
        data["milestones"][5]["githubPR"] = 105
        with self.assertRaises(ValueError):
            module.validate_manifest(data)

    def test_duplicate_checkpoint_fails(self):
        data = copy.deepcopy(BASE)
        data["milestones"][6]["headCommit"] = data["milestones"][5]["headCommit"]
        with self.assertRaises(ValueError):
            module.validate_manifest(data)

    def test_integration_authorization_cannot_be_forged(self):
        for flag in ("hardwareAcceptanceComplete", "releaseAcceptanceComplete",
                     "mayMergeIntoMain", "liveFeedForwardANCAuthorized"):
            with self.subTest(flag=flag):
                data = copy.deepcopy(BASE)
                data[flag] = True
                with self.assertRaises(ValueError):
                    module.validate_manifest(data)

    def test_snapshot_must_be_exact_sha(self):
        data = copy.deepcopy(BASE)
        data["mainSnapshotCommit"] = "main"
        with self.assertRaises(ValueError):
            module.validate_manifest(data)

    def test_no_dsp_or_runtime_modification_in_slice_one(self):
        self.assertNotIn("NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c",
                         module.ALLOWED_SLICE_ONE_FILES)
        self.assertNotIn("NotchSixty/Audio/Routing/OutputDeviceProfileConfiguration.swift",
                         module.ALLOWED_SLICE_ONE_FILES)


if __name__ == "__main__":
    unittest.main()
