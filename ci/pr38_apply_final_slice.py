#!/usr/bin/env python3
import pr38_patch_telemetry_c
import pr38_patch_ui
import pr38_patch_docs

pr38_patch_telemetry_c.apply()
pr38_patch_ui.apply()
pr38_patch_docs.apply()
print("PR38 final parity/status slice applied")
