from pathlib import Path

path = Path('.github/scripts/pr41_slice_c2b.py')
text = path.read_text()
old = '''        case .captureBufferSizeMismatch(let capture, let output):\\n            return "Capture buffer size \\\\(capture) frames does not match output buffer size \\\\(output) frames."\\n'''
new = '''        case .captureBufferSizeMismatch(let capture, let output):\\n            return "Tap aggregate callback quantum is \\\\(capture) frames; expected \\\\(output) frames to match the physical output."\\n'''
count = text.count(old)
if count != 2:
    raise SystemExit(f'expected two stale capture-buffer description anchors, found {count}')
text = text.replace(old, new)
path.write_text(text)
print('PR41 C2b transport-error helper anchors fixed')
