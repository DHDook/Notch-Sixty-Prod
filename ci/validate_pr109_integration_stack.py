#!/usr/bin/env python3
"""Read-only PR109 stack audit. Never merges branches or authorizes hardware/release."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "ci/pr109_stack_manifest.json"
ALLOWED_SLICE_ONE_FILES = frozenset({
    "ci/pr109_stack_manifest.json",
    "ci/validate_pr109_integration_stack.py",
    "ci/tests/test_pr109_integration_stack.py",
    ".github/workflows/pr109-integration-stack.yml",
    "docs/PR109_INTEGRATION_STACK_CONSOLIDATION.md",
    "docs/ROADMAP.md",
})
SHA = re.compile(r"^[0-9a-f]{40}$")


def require(ok: bool, message: str) -> None:
    if not ok:
        raise ValueError(message)


def validate_manifest(data: dict) -> None:
    require(isinstance(data, dict), "manifest must be an object")
    require(data.get("schemaVersion") == 1, "schemaVersion must be 1")
    require(data.get("repository") == "DHDook/Notch-Sixty-Prod", "wrong repository")
    require(data.get("roadmapFeatureHead") == 108, "PR108 is the inherited feature head")
    require(data.get("roadmapIntegrationPR") == 109, "PR109 is the integration audit")
    require(data.get("softwareAuditOnly") is True, "audit must remain software-only")
    for field in ("hardwareAcceptanceComplete", "releaseAcceptanceComplete",
                  "mayMergeIntoMain", "liveFeedForwardANCAuthorized"):
        require(data.get(field) is False, f"{field} must remain false")
    require(isinstance(data.get("scope"), str) and "no merges" in data["scope"],
            "remote/no-merge scope is required")
    require(bool(SHA.fullmatch(str(data.get("mainSnapshotCommit", "")))),
            "invalid main snapshot SHA")
    items = data.get("milestones")
    require(isinstance(items, list) and len(items) == 10,
            "PR99..PR108 checkpoint set must be complete")
    seen_sha = {data["mainSnapshotCommit"]}
    seen_branches = set()
    for index, milestone in enumerate(items):
        require(isinstance(milestone, dict), "milestone must be an object")
        number = 99 + index
        require(milestone.get("roadmapPR") == number,
                f"missing or out-of-order roadmap PR{number}")
        require(milestone.get("githubPR") == number + 1,
                f"wrong GitHub PR for roadmap PR{number}")
        branch = milestone.get("branch")
        require(isinstance(branch, str) and branch.startswith(f"feature/pr{number}-"),
                f"wrong branch for roadmap PR{number}")
        require(branch not in seen_branches, f"duplicate branch {branch}")
        seen_branches.add(branch)
        head = milestone.get("headCommit")
        require(isinstance(head, str) and bool(SHA.fullmatch(head)),
                f"invalid commit SHA for roadmap PR{number}")
        require(head not in seen_sha, f"duplicate checkpoint SHA for PR{number}")
        seen_sha.add(head)


def git(*args: str) -> str:
    proc = subprocess.run(["git", *args], cwd=ROOT,
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          check=False)
    require(proc.returncode == 0,
            f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout.strip()


def audit_checkout(data: dict) -> dict:
    milestones = data["milestones"]
    chain = [("main snapshot", data["mainSnapshotCommit"])]
    chain += [(f"PR{item['roadmapPR']}", item["headCommit"]) for item in milestones]
    chain += [("PR109 checkout", git("rev-parse", "HEAD"))]
    for label, commit in chain:
        git("cat-file", "-e", f"{commit}^{{commit}}")
    for (older_label, older), (newer_label, newer) in zip(chain, chain[1:]):
        proc = subprocess.run(["git", "merge-base", "--is-ancestor", older, newer],
                              cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, check=False)
        require(proc.returncode == 0,
                f"{older_label} is not an ancestor of {newer_label} "
                "(or history is shallow); PR109 must not rebase other branches")
        require(older != newer, f"identical {older_label}/{newer_label} checkpoints")
    source = milestones[-1]["headCommit"]
    changed = set(git("diff", "--name-only", source, "HEAD").splitlines())
    unexpected = changed - ALLOWED_SLICE_ONE_FILES
    require(not unexpected,
            "PR109 Slice 1 must not change app/DSP/runtime/safety code: "
            + ", ".join(sorted(unexpected)))
    require("ci/validate_pr109_integration_stack.py" in changed,
            "PR109 validator must be committed on PR109")
    return {
        "evidenceAuthority": "remoteGitAncestryAndCI",
        "mainSnapshotCommit": data["mainSnapshotCommit"],
        "inheritedPR108Commit": source,
        "checkoutCommit": chain[-1][1],
        "checkpointsAudited": [label for label, _ in chain],
        "changedFiles": sorted(changed),
        "hardwareAcceptanceComplete": False,
        "releaseAcceptanceComplete": False,
        "mayMergeIntoMain": False,
        "liveFeedForwardANCAuthorized": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--schema-only", action="store_true",
                        help="Unit-test or offline schema audit; CI must run full git audit.")
    parser.add_argument("--report", type=Path,
                        help="Write a machine-readable audit (not hardware/release evidence).")
    args = parser.parse_args()
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
        validate_manifest(data)
        if args.schema_only:
            print("PR109 stack manifest schema: PASS (ancestry NOT verified)")
            return 0
        report = audit_checkout(data)
        if args.report is not None:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n",
                                   encoding="utf-8")
        print(f"PR109 read-only stack ancestry: PASS; {len(report['checkpointsAudited'])} "
              "checkpoints; physical/release/merge authority: FALSE")
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"PR109 remote stack audit: FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
