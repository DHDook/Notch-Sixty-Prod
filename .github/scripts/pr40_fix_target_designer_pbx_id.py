from pathlib import Path

path = Path("NotchSixty.xcodeproj/project.pbxproj")
text = path.read_text()
old_id = "A20000000000000000000020"
new_id = "E20000000000000000000001"
old_build = f'\t\t{old_id} /* RoomCorrectionTargetDesigner.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A20000000000000000000030 /* RoomCorrectionTargetDesigner.swift */; }};\n'
new_build = f'\t\t{new_id} /* RoomCorrectionTargetDesigner.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A20000000000000000000030 /* RoomCorrectionTargetDesigner.swift */; }};\n'
old_phase = f'\t\t\t\t{old_id} /* RoomCorrectionTargetDesigner.swift in Sources */,\n'
new_phase = f'\t\t\t\t{new_id} /* RoomCorrectionTargetDesigner.swift in Sources */,\n'
for old, new, label in [(old_build, new_build, "build file"), (old_phase, new_phase, "source phase")]:
    if new in text:
        continue
    if text.count(old) != 1:
        raise SystemExit(f"Unexpected {label} anchor: found {text.count(old)}")
    text = text.replace(old, new, 1)
path.write_text(text)
