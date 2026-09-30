#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
MATRIX = ROOT / "docs" / "PR42_FINAL_PARITY_MATRIX.md"
PROVENANCE = ROOT / "docs" / "PR42_PROVENANCE_CLOSURE.md"
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
CONTRACT = ROOT / "docs" / "PR42_PARITY_PROVENANCE_CLOSURE.md"

ALLOWED = {"PARITY", "IMPROVED", "PORT VERIFIED", "SUPERSEDED", "BLOCKED"}
SUPERSEDED_RATIONALE_SIGNALS = (
    "replaced", "outside", "no-op", "not reproduced", "not recreated",
    "does not", "deliberately", "intentionally", "post-1.0", "future",
    "remains", "shared", "prioritizes", "uses", "avoids", "available",
)


def fail(message: str) -> None:
    print(f"PR42 closure validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


for path in (MATRIX, PROVENANCE, NOTICES, CONTRACT):
    require(path.exists(), f"missing required closure file: {path.relative_to(ROOT)}")

matrix = MATRIX.read_text(encoding="utf-8")
provenance = PROVENANCE.read_text(encoding="utf-8")
notices = NOTICES.read_text(encoding="utf-8")
contract = CONTRACT.read_text(encoding="utf-8")

# Parse every capability table row. The final matrix deliberately uses one of the
# five PR42 dispositions as the complete second column of every data row.
rows = []
for line in matrix.splitlines():
    if not line.startswith("|"):
        continue
    cells = [cell.strip().replace("**", "") for cell in line.strip().strip("|").split("|")]
    if len(cells) < 3:
        continue
    if cells[0] in {"Capability", "---"} or set(cells[0]) <= {"-", ":"}:
        continue
    status = cells[1]
    if status in ALLOWED:
        rows.append((cells[0], status, cells[2]))
    elif cells[0] and cells[1] and not set(cells[1]) <= {"-", ":"}:
        fail(f"unclassified/invalid disposition for '{cells[0]}': '{cells[1]}'")

require(len(rows) >= 70, f"final capability matrix is unexpectedly small ({len(rows)} classified rows)")
blocked = [capability for capability, status, _ in rows if status == "BLOCKED"]
require(not blocked, "unresolved BLOCKED rows: " + ", ".join(blocked))

required_capabilities = [
    "Software PLL multi-device synchronization",
    "Legacy 24-bit realtime Dither control",
    "Legacy `.eqpreset` v1 migration",
    "EasyEffects equalizer import/export",
    "CamillaDSP content-EQ/FIR export",
    "Automatic IIR room-correction fitter",
    "Measurement-derived automatic excess-phase inversion",
    "2–8 physical output routes",
    "Arbitrary per-output EQ",
    "Automatic crossover-frequency optimization",
    "App identity/icon assets",
]
capability_names = {capability for capability, _, _ in rows}
for capability in required_capabilities:
    require(capability in capability_names, f"required audited capability missing from final matrix: {capability}")

# SUPERSEDED must describe a replacement, deliberate boundary, audited no-op, or
# future handoff. This is semantic rather than padding rationales to an arbitrary
# character count.
for capability, status, rationale in rows:
    if status != "SUPERSEDED":
        continue
    normalized = rationale.lower()
    require(
        any(signal in normalized for signal in SUPERSEDED_RATIONALE_SIGNALS),
        f"SUPERSEDED row lacks replacement/boundary rationale: {capability}",
    )

require("not claims of current implementation" in matrix, "post-1.0 register must disclaim current implementation")
require("There are no unresolved release-blocking rows" in matrix, "matrix closure result is missing")

# Provenance must close the production-source, license, dependency and asset axes.
for token in [
    "unexplained production source origin: **none identified**",
    "unresolved GPL/AGPL production dependency: **none identified**",
    "third-party linked production component requiring a notice: **none identified**",
    "owner-authored reused asset without an ownership basis: **none identified**",
    "PR34–PR42 implementation areas without a provenance classification: **none identified**",
]:
    require(token in provenance, f"provenance closure token missing: {token}")

require("no linked or bundled third-party production dependency" in notices,
        "THIRD_PARTY_NOTICES.md does not record the PR42 dependency result")
require("GPL/AGPL dependencies are not permitted" in notices,
        "third-party notice policy lost GPL/AGPL production prohibition")

# Keep the main contract wired to the final artifacts/status once PR42 enters
# closure. This also prevents the branch from drifting back to an audit-only state.
require("PR42_FINAL_PARITY_MATRIX.md" in contract, "main PR42 contract does not reference the final matrix")
require("PR42_PROVENANCE_CLOSURE.md" in contract, "main PR42 contract does not reference provenance closure")
require("CLOSURE" in contract.upper(), "main PR42 contract no longer identifies closure state")

print(f"PR42 parity/provenance closure OK: {len(rows)} classified capability rows, 0 BLOCKED")
