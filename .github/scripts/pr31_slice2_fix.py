from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"anchor not found: {label}")
    return text.replace(old, new, 1)

# Bridge the new C detector telemetry through the existing Swift diagnostics abstraction.
diag = Path('NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift')
text = diag.read_text()
text = replace_once(
    text,
    '    let crossoverSectionCount: UInt32\n    let deEsserEnabled: Bool\n',
    '    let crossoverSectionCount: UInt32\n    let mainsDetectedFrequencyHz: Float\n    let mainsDetectionConfidence: Float\n    let deEsserEnabled: Bool\n',
    'Swift diagnostics fields',
)
text = replace_once(
    text,
    '        crossoverSectionCount = diagnostics.crossoverSectionCount\n        deEsserEnabled = diagnostics.deEsserEnabled\n',
    '        crossoverSectionCount = diagnostics.crossoverSectionCount\n        mainsDetectedFrequencyHz = diagnostics.mainsDetectedFrequencyHz\n        mainsDetectionConfidence = diagnostics.mainsDetectionConfidence\n        deEsserEnabled = diagnostics.deEsserEnabled\n',
    'Swift diagnostics mapping',
)
diag.write_text(text)

app = Path('NotchSixty/NotchSixtyApp.swift')
text = app.read_text()
text = replace_once(
    text,
    '    @State private var mainsDiagnostics: N60RenderKernelDiagnostics?\n',
    '    @State private var mainsDiagnostics: RenderKernelDiagnostics?\n',
    'PR31 UI diagnostics type',
)
app.write_text(text)
