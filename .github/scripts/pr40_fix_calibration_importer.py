from pathlib import Path

path = Path("NotchSixty/UI/ProductionRoomCorrectionWorkspace.swift")
text = path.read_text()

old = '''    private func importMicrophoneCalibrationFile(_ result: Result<URL, Error>) {
        actionError = nil
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
'''
new = '''    private func importMicrophoneCalibrationFile(_ result: Result<[URL], Error>) {
        actionError = nil
        do {
            let urls = try result.get()
            guard let url = urls.first else {
                actionError = "Choose a microphone calibration file."
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
'''
if new not in text:
    if text.count(old) != 1:
        raise SystemExit(f"Unexpected importer helper anchor: found {text.count(old)}")
    text = text.replace(old, new, 1)

old_caption = '                Text("This capture measures one listening position. Named multi-position storage and weighting build on the analyzed Left / Right result in the next Room Correction stage.")\n'
new_caption = '                Text("This capture measures one listening position. After analysis, keep it as a named position below, then repeat for additional seats.")\n'
if new_caption not in text:
    if text.count(old_caption) != 1:
        raise SystemExit(f"Unexpected measurement caption anchor: found {text.count(old_caption)}")
    text = text.replace(old_caption, new_caption, 1)

path.write_text(text)
