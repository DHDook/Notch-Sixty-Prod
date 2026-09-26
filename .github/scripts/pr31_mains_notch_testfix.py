from pathlib import Path

path = Path('NotchSixtyTests/NotchSixtyTests.swift')
text = path.read_text()
old = '''        let frameCount = max(Int(sampleRate * 0.35), 16_000)
        let settleFrames = max(Int(sampleRate * 0.08), 4_000)
'''
new = '''        // A 60 Hz, Q=30 cut has a long physical settling time. Give the
        // realtime IIR enough time to reach steady state before evaluating the
        // requested depth, especially at the 384 kHz validation rate.
        let frameCount = max(Int(sampleRate * 1.25), 60_000)
        let settleFrames = max(Int(sampleRate * 0.55), 24_000)
'''
if old not in text:
    raise SystemExit('mains-notch measurement window anchor not found')
path.write_text(text.replace(old, new, 1))
