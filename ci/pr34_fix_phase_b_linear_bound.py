from pathlib import Path

path = Path("NotchSixty/Audio/Realtime/N60LinearPhaseEQ.h")
text = path.read_text()
old = "#define N60_LINEAR_PHASE_MAX_BANDS (N60_MAX_EQ_BANDS * N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND)"
new = "#define N60_LINEAR_PHASE_MAX_BANDS 512u"
if new not in text:
    if old not in text:
        raise SystemExit("Expected Phase B Linear-Phase bound was not found")
    text = text.replace(old, new, 1)
path.write_text(text)
print("PR34 Phase B Linear-Phase bound is header-local (512 compiled sections/channel).")
