from pathlib import Path

path = Path('.github/scripts/pr41_slice_c4_core.py')
text = path.read_text()
old = 'snapshot.upperFrequencyHz = 2_000.0;'
new = 'snapshot.upperFrequencyHz = 2000.0;'
if text.count(old) != 1:
    raise SystemExit(f'expected one C digit-separator literal, found {text.count(old)}')
path.write_text(text.replace(old, new, 1))
print('PR41 C4 C literal repaired')
