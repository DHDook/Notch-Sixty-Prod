#!/usr/bin/env python3
from pathlib import Path

path = Path("NotchSixty.xcodeproj/project.pbxproj")
text = path.read_text(encoding="utf-8")

anchors = [
    (
        '\t\tF64000000000000000000002 /* MultichannelCalibrationDesigner.swift in Sources */ = {isa = PBXBuildFile; fileRef = F64000000000000000000012 /* MultichannelCalibrationDesigner.swift */; };\n',
        '\t\tF64000000000000000000003 /* MultichannelCalibrationTransport.swift in Sources */ = {isa = PBXBuildFile; fileRef = F64000000000000000000013 /* MultichannelCalibrationTransport.swift */; };\n'
    ),
    (
        '\t\tF64000000000000000000012 /* MultichannelCalibrationDesigner.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MultichannelCalibrationDesigner.swift; sourceTree = "<group>"; };\n',
        '\t\tF64000000000000000000013 /* MultichannelCalibrationTransport.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MultichannelCalibrationTransport.swift; sourceTree = "<group>"; };\n'
    ),
    (
        'F63000000000000000000011 /* CoreAudioNChannelTransportSession.swift */, A20000000000000000000028 /* MasterVolumeDeviceController.swift */',
        'F63000000000000000000011 /* CoreAudioNChannelTransportSession.swift */, F64000000000000000000013 /* MultichannelCalibrationTransport.swift */, A20000000000000000000028 /* MasterVolumeDeviceController.swift */'
    ),
    (
        '\t\t\t\tF64000000000000000000002 /* MultichannelCalibrationDesigner.swift in Sources */,\n',
        '\t\t\t\tF64000000000000000000003 /* MultichannelCalibrationTransport.swift in Sources */,\n'
    ),
]
for anchor, addition in anchors:
    count = text.count(anchor)
    if count != 1:
        raise SystemExit(f"expected one project anchor, found {count}: {anchor}")
    if anchor.startswith('F630'):
        text = text.replace(anchor, addition, 1)
    else:
        text = text.replace(anchor, anchor + addition, 1)

path.write_text(text, encoding="utf-8")
print("targeted calibration transport added to app target")
