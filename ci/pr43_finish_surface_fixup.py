#!/usr/bin/env python3
from pathlib import Path

patcher = Path('ci/pr43_finish_surface_patch.py')
text = patcher.read_text(encoding='utf-8')
old = '''            switch bus {
            case .subLeft, .subRight: initialFrequency = 60
            case .lowLeft, .lowRight: initialFrequency = 120
            case .midLeft, .midRight: initialFrequency = 1_000
            case .highLeft, .highRight: initialFrequency = 5_000
            case .fullRangeLeft, .fullRangeRight: initialFrequency = 1_000
            }'''
new = '''            switch bus {
            case .subMono: initialFrequency = 60
            case .leftLow, .rightLow: initialFrequency = 120
            case .leftMid, .rightMid: initialFrequency = 1_000
            case .leftHigh, .rightHigh: initialFrequency = 5_000
            case .leftFullRange, .rightFullRange: initialFrequency = 1_000
            }'''
if old not in text and new not in text:
    raise SystemExit('speaker-bus patch anchor missing')
text = text.replace(old, new, 1)

marker = '''## Also deferred

- per-driver realtime meter UI:'''
replacement = '''## Also deferred

- automatic low-latency IIR Room Correction fitting: the commercial graph intentionally keeps Content-Preset EQ separate from the dedicated Playback-System Room Correction lane. Shipping an automatic IIR fitter now would either hide system filters inside the content EQ bank or require a new system-IIR render lane immediately before 1.0. PR43 preserves the bounded minimum-phase FIR correction path and defers system-owned automatic IIR until that lane can be designed, persisted, bypassed, and verified explicitly;
- per-driver realtime meter UI:'''
if marker not in text and replacement not in text:
    raise SystemExit('closure deferral anchor missing')
text = text.replace(marker, replacement, 1)
patcher.write_text(text, encoding='utf-8')

scope = Path('docs/PR43_ADVANCED_ACOUSTIC_SPEAKER_OPTIMIZATION.md')
scope_text = scope.read_text(encoding='utf-8')
scope_text = scope_text.replace(
    'Status: **KICKOFF / IMPLEMENTATION IN PROGRESS**',
    'Status: **CLOSED BY `docs/PR43_CLOSURE.md` — REAL-MAC ACCEPTANCE PENDING**',
    1,
)
scope.write_text(scope_text, encoding='utf-8')

print('PR43 finish-surface fixup applied')
