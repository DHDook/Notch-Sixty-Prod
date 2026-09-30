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
    '\t\tA1000000000000000000001D /* RoomCorrectionProjectControllerTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A10000000000000000000032 /* RoomCorrectionProjectControllerTests.swift */; };\n',
    '\t\tA1000000000000000000001E /* RoomCorrectionTargetDesignerTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A10000000000000000000033 /* RoomCorrectionTargetDesignerTests.swift */; };\n',
    'test build-file anchor',
)
insert_after(
    '\t\tA2000000000000000000001F /* RoomCorrectionProjectController.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000000000000000000002F /* RoomCorrectionProjectController.swift */; };\n',
    '\t\tA20000000000000000000020 /* RoomCorrectionTargetDesigner.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000030 /* RoomCorrectionTargetDesigner.swift */; };\n',
    'source build-file anchor',
)
insert_after(
    '\t\tA10000000000000000000032 /* RoomCorrectionProjectControllerTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RoomCorrectionProjectControllerTests.swift; sourceTree = "<group>"; };\n',
    '\t\tA10000000000000000000033 /* RoomCorrectionTargetDesignerTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RoomCorrectionTargetDesignerTests.swift; sourceTree = "<group>"; };\n',
    'test file-reference anchor',
)
insert_after(
    '\t\tA2000000000000000000002F /* RoomCorrectionProjectController.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RoomCorrectionProjectController.swift; sourceTree = "<group>"; };\n',
    '\t\tA20000000000000000000030 /* RoomCorrectionTargetDesigner.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RoomCorrectionTargetDesigner.swift; sourceTree = "<group>"; };\n',
    'source file-reference anchor',
)
insert_after(
    '\t\t\t\tA10000000000000000000032 /* RoomCorrectionProjectControllerTests.swift */,\n',
    '\t\t\t\tA10000000000000000000033 /* RoomCorrectionTargetDesignerTests.swift */,\n',
    'test group anchor',
)
insert_after(
    '\t\t\t\tA2000000000000000000002E /* RoomCorrectionMeasurementAnalyzer.swift */,\n',
    '\t\t\t\tA20000000000000000000030 /* RoomCorrectionTargetDesigner.swift */,\n',
    'audio group anchor',
)
insert_after(
    '\t\t\t\tA2000000000000000000001F /* RoomCorrectionProjectController.swift in Sources */,\n',
    '\t\t\t\tA20000000000000000000020 /* RoomCorrectionTargetDesigner.swift in Sources */,\n',
    'app source-phase anchor',
)
insert_after(
    '\t\t\t\tA1000000000000000000001D /* RoomCorrectionProjectControllerTests.swift in Sources */,\n',
    '\t\t\t\tA1000000000000000000001E /* RoomCorrectionTargetDesignerTests.swift in Sources */,\n',
    'test source-phase anchor',
)

path.write_text(text)
