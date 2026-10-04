#!/usr/bin/env python3
from pathlib import Path

# One-shot correction for the explicit one-line Routing PBXGroup anchor.
# This file exists only to make the production patch fully asserted.
path = Path(__file__).resolve().parent / "pr64_apply_integration_patch.py"
text = path.read_text()
old = '''project_insert(
    '\\t\\t\\t\\tF62000000000000000000011 /* OutputDeviceProfileConfiguration.swift */,\\n',
    '\\t\\t\\t\\tF64000000000000000000011 /* OutputDeviceCalibration.swift */,\\n'
)
'''
new = '''routing_anchor = '\\t\\tA20000000000000000000053 /* Routing */ = {isa = PBXGroup; children = (A20000000000000000000024 /* AudioRouteConfiguration.swift */, F62000000000000000000011 /* OutputDeviceProfileConfiguration.swift */,); path = Routing; sourceTree = "<group>"; };\\n'
routing_replacement = '\\t\\tA20000000000000000000053 /* Routing */ = {isa = PBXGroup; children = (A20000000000000000000024 /* AudioRouteConfiguration.swift */, F62000000000000000000011 /* OutputDeviceProfileConfiguration.swift */, F64000000000000000000011 /* OutputDeviceCalibration.swift */,); path = Routing; sourceTree = "<group>"; };\\n'
if project.count(routing_anchor) != 1:
    raise SystemExit("project.pbxproj Routing group anchor mismatch")
project = project.replace(routing_anchor, routing_replacement, 1)
'''
if text.count(old) != 1:
    raise SystemExit("PR64 patch-script anchor mismatch")
path.write_text(text.replace(old, new, 1))
