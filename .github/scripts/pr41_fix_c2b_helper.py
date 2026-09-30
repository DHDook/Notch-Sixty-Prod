from pathlib import Path

path = Path('.github/scripts/pr41_slice_c2b.py')
text = path.read_text()
old = '''        case .captureBufferSizeMismatch(let capture, let output):\\n            return "Capture buffer size \\\\(capture) frames does not match output buffer size \\\\(output) frames."\\n'''
new = '''        case .captureBufferSizeMismatch(let capture, let output):\\n            return "Tap aggregate callback quantum is \\\\(capture) frames; expected \\\\(output) frames to match the physical output."\\n'''
if text.count(old) != 1:
    raise SystemExit(f'expected one stale capture-buffer description anchor, found {text.count(old)}')
text = text.replace(old, new, 1)
path.write_text(text)
print('PR41 C2b transport-error helper anchor fixed')
