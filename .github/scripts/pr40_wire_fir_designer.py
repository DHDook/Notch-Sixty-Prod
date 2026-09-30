from pathlib import Path

path = Path("NotchSixty.xcodeproj/project.pbxproj")
text = path.read_text()


def insert_after(anchor: str, addition: str, label: str) -> None:
    global text
    if addition.strip() in text:
        return
    if text.count(anchor) != 1:
        raise SystemExit(f"Unexpected {label}: found {text.count(anchor)} anchors")
    text = text.replace(anchor, anchor + addition, 1)


insert_after(
    '\t\tA1000000000000000000001E /* RoomCorrectionTargetDesignerTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A10000000000000000000033 /* RoomCorrectionTargetDesignerTests.swift */; };\n',
    '\t\tE10000000000000000000002 /* RoomCorrectionFIRDesignerTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = E10000000000000000000012 /* RoomCorrectionFIRDesignerTests.swift */; };\n',
    'FIR test build-file anchor',
)
insert_after(
    '\t\tE20000000000000000000001 /* RoomCorrectionTargetDesigner.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000030 /* RoomCorrectionTargetDesigner.swift */; };\n',
    '\t\tE20000000000000000000002 /* RoomCorrectionFIRDesigner.swift in Sources */ = {isa = PBXBuildFile; fileRef = E20000000000000000000012 /* RoomCorrectionFIRDesigner.swift */; };\n',
    'FIR source build-file anchor',
)
insert_after(
    '\t\tA10000000000000000000033 /* RoomCorrectionTargetDesignerTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RoomCorrectionTargetDesignerTests.swift; sourceTree = "<group>"; };\n',
    '\t\tE10000000000000000000012 /* RoomCorrectionFIRDesignerTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RoomCorrectionFIRDesignerTests.swift; sourceTree = "<group>"; };\n',
    'FIR test file-reference anchor',
)
insert_after(
    '\t\tA20000000000000000000030 /* RoomCorrectionTargetDesigner.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RoomCorrectionTargetDesigner.swift; sourceTree = "<group>"; };\n',
    '\t\tE20000000000000000000012 /* RoomCorrectionFIRDesigner.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RoomCorrectionFIRDesigner.swift; sourceTree = "<group>"; };\n',
    'FIR source file-reference anchor',
)
insert_after(
    '\t\t\t\tA10000000000000000000033 /* RoomCorrectionTargetDesignerTests.swift */,\n',
    '\t\t\t\tE10000000000000000000012 /* RoomCorrectionFIRDesignerTests.swift */,\n',
    'FIR test group anchor',
)
insert_after(
    '\t\t\t\tA20000000000000000000030 /* RoomCorrectionTargetDesigner.swift */,\n',
    '\t\t\t\tE20000000000000000000012 /* RoomCorrectionFIRDesigner.swift */,\n',
    'FIR audio group anchor',
)
insert_after(
    '\t\t\t\tE20000000000000000000001 /* RoomCorrectionTargetDesigner.swift in Sources */,\n',
    '\t\t\t\tE20000000000000000000002 /* RoomCorrectionFIRDesigner.swift in Sources */,\n',
    'FIR app source-phase anchor',
)
insert_after(
    '\t\t\t\tA1000000000000000000001E /* RoomCorrectionTargetDesignerTests.swift in Sources */,\n',
    '\t\t\t\tE10000000000000000000002 /* RoomCorrectionFIRDesignerTests.swift in Sources */,\n',
    'FIR test source-phase anchor',
)

path.write_text(text)
