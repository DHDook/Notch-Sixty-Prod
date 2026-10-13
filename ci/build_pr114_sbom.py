#!/usr/bin/env python3
"""Build deterministic PR114 CycloneDX production SBOM from classified inputs."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "release" / "pr114-release-baseline.json"
DEPENDENCIES = ROOT / "release" / "production-dependencies.json"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_set_digest(paths: list[str]) -> str:
    digest = hashlib.sha256()
    for relative in sorted(paths):
        path = ROOT / relative
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(sha256_file(path).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def git_head() -> str:
    return subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def build() -> dict[str, Any]:
    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
    deps = json.loads(DEPENDENCIES.read_text(encoding="utf-8"))
    product = baseline["product"]
    source_commit = git_head()

    app_ref = (
        "pkg:generic/notch-sixty@"
        + product["marketingVersion"]
        + "?build="
        + product["buildNumber"]
    )

    components: list[dict[str, Any]] = []
    dependency_refs: list[str] = []

    for component in sorted(
        deps["thirdPartyComponents"],
        key=lambda item: item["id"],
    ):
        component_ref = (
            "pkg:github/hoene/libmysofa@"
            + component["version"]
            if component["id"] == "libmysofa"
            else "urn:notchsixty:component:" + component["id"]
        )
        dependency_refs.append(component_ref)

        license_path = ROOT / component["licenseFile"]
        notice_path = ROOT / component["shippingNoticeFile"]
        source_paths = component["productionSourceFiles"]

        entry: dict[str, Any] = {
            "type": "library",
            "bom-ref": component_ref,
            "name": component["name"],
            "version": component["version"],
            "licenses": [
                {
                    "license": {
                        "id": component["license"],
                    }
                }
            ],
            "externalReferences": [
                {
                    "type": "vcs",
                    "url": component["upstream"],
                    "comment": "Upstream tag " + component["upstreamTag"],
                }
            ],
            "properties": [
                {
                    "name": "notchsixty:vendoredRoot",
                    "value": component["vendoredRoot"],
                },
                {
                    "name": "notchsixty:purpose",
                    "value": component["purpose"],
                },
                {
                    "name": "notchsixty:realtimeRenderPath",
                    "value": str(component["realtimeRenderPath"]).lower(),
                },
                {
                    "name": "notchsixty:licenseFile",
                    "value": component["licenseFile"],
                },
                {
                    "name": "notchsixty:licenseFileSHA256",
                    "value": sha256_file(license_path),
                },
                {
                    "name": "notchsixty:shippingNoticeFile",
                    "value": component["shippingNoticeFile"],
                },
                {
                    "name": "notchsixty:shippingNoticeSHA256",
                    "value": sha256_file(notice_path),
                },
                {
                    "name": "notchsixty:productionSourceCount",
                    "value": str(len(source_paths)),
                },
                {
                    "name": "notchsixty:productionSourceSetSHA256",
                    "value": source_set_digest(source_paths),
                },
            ],
        }
        components.append(entry)

    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "bom-ref": app_ref,
                "name": product["name"],
                "version": product["marketingVersion"],
                "properties": [
                    {
                        "name": "notchsixty:buildNumber",
                        "value": product["buildNumber"],
                    },
                    {
                        "name": "notchsixty:platform",
                        "value": product["platform"],
                    },
                    {
                        "name": "notchsixty:architecture",
                        "value": product["architecture"],
                    },
                    {
                        "name": "notchsixty:minimumMacOS",
                        "value": product["minimumMacOS"],
                    },
                    {
                        "name": "notchsixty:sourceCommit",
                        "value": source_commit,
                    },
                    {
                        "name": "notchsixty:productionSourceLicense",
                        "value": deps["policy"]["productionSourceLicense"],
                    },
                ],
            },
            "properties": [
                {
                    "name": "notchsixty:generator",
                    "value": "ci/build_pr114_sbom.py",
                },
                {
                    "name": "notchsixty:unclassifiedProductionDependencyAllowed",
                    "value": str(
                        deps["policy"]["unclassifiedProductionDependencyAllowed"]
                    ).lower(),
                },
            ],
        },
        "components": components,
        "dependencies": [
            {
                "ref": app_ref,
                "dependsOn": dependency_refs,
            },
            *[
                {
                    "ref": ref,
                    "dependsOn": [],
                }
                for ref in dependency_refs
            ],
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    data = json.dumps(
        build(),
        indent=2,
        sort_keys=True,
        ensure_ascii=False,
    ).encode("utf-8") + b"\n"

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)


if __name__ == "__main__":
    main()
