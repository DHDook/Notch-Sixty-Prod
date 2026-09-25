from pathlib import Path

p = Path('.github/scripts/pr25_audition_core.py')
t = p.read_text()
old = "'''    bool bypassed;\\n    N60AuditionMode auditionMode;\\n    uint32_t latencyFrames;\\n''', 2)"
new = "'''    bool bypassed;\\n    N60AuditionMode auditionMode;\\n    uint32_t latencyFrames;\\n''')"
if old not in t:
    raise SystemExit('cardinality marker missing')
p.write_text(t.replace(old, new, 1))
