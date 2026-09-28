#!/usr/bin/env python3
from pathlib import Path

EQ = Path("NotchSixty/UI/ProductionEqualizerView.swift")
VALIDATOR = Path("ci/validate_pr37_equalizer_ui.py")
DOC = Path("docs/PR37_PRODUCTION_EQUALIZER.md")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Unable to patch {label}: expected anchor not found")
    return text.replace(old, new, 1)


text = EQ.read_text()

text = replace_once(
    text,
    '''                .buttonStyle(.glassProminent)\n                .disabled(bands.count >= EQConfiguration.maximumBandCount)''',
    '''                .buttonStyle(.glassProminent)\n                .keyboardShortcut("n", modifiers: [.command, .shift])\n                .help("Add EQ band (⇧⌘N)")\n                .disabled(bands.count >= EQConfiguration.maximumBandCount)''',
    "add-band keyboard shortcut"
)

text = replace_once(
    text,
    '''                Spacer()\n                Text("\\(bands.count) / \\(EQConfiguration.maximumBandCount)")\n                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)''',
    '''                Spacer()\n                Button { selectAdjacentBand(offset: -1) } label: {\n                    Image(systemName: "chevron.left")\n                }\n                .buttonStyle(.borderless)\n                .keyboardShortcut("[", modifiers: [.command])\n                .help("Previous band (⌘[)")\n                .disabled(bands.count < 2)\n                Button { selectAdjacentBand(offset: 1) } label: {\n                    Image(systemName: "chevron.right")\n                }\n                .buttonStyle(.borderless)\n                .keyboardShortcut("]", modifiers: [.command])\n                .help("Next band (⌘])")\n                .disabled(bands.count < 2)\n                Text("\\(bands.count) / \\(EQConfiguration.maximumBandCount)")\n                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)''',
    "band navigation controls"
)

text = replace_once(
    text,
    '''                Picker("Filter", selection: binding.type) {\n                    ForEach(EQFilterType.allCases) { type in Text(type.displayName).tag(type) }\n                }''',
    '''                Picker("Filter", selection: binding.type) {\n                    ForEach(EQFilterType.allCases) { type in\n                        Text(type.displayName)\n                            .tag(type)\n                            .disabled(\n                                (type == .fir && band.firKernel == nil)\n                                    || (type == .allPass && configuration.phaseMode != .minimumPhase)\n                            )\n                    }\n                }''',
    "filter validity choices"
)

text = replace_once(
    text,
    '''            .buttonStyle(.glass)\n        }\n    }\n\n    @ViewBuilder\n    private func staticControls''',
    '''            .buttonStyle(.glass)\n            .keyboardShortcut(.delete, modifiers: [.command])\n            .help("Remove selected band (⌘⌫)")\n        }\n    }\n\n    @ViewBuilder\n    private func staticControls''',
    "remove-band keyboard shortcut"
)

text = replace_once(
    text,
    '''    private func removeBand(_ id: UUID) {\n        do {\n            try engine.removeEQBand(id: id)\n            if selectedBandID == id { selectedBandID = nil }\n            ensureSelection()\n        } catch { }\n    }\n\n    private func suggestedFrequency() -> Double {''',
    '''    private func removeBand(_ id: UUID) {\n        let previousBands = bands\n        let previousIndex = previousBands.firstIndex(where: { $0.id == id }) ?? 0\n        do {\n            try engine.removeEQBand(id: id)\n            if selectedBandID == id {\n                let remaining = engine.stereoEQConfiguration.editableBands\n                selectedBandID = remaining.isEmpty ? nil : remaining[min(previousIndex, remaining.count - 1)].id\n            }\n        } catch { }\n    }\n\n    private func selectAdjacentBand(offset: Int) {\n        guard !bands.isEmpty else { return }\n        let current = selectedBandID.flatMap { id in bands.firstIndex(where: { $0.id == id }) } ?? 0\n        let next = (current + offset + bands.count) % bands.count\n        selectedBandID = bands[next].id\n    }\n\n    private func suggestedFrequency() -> Double {''',
    "stable deletion selection"
)

text = replace_once(
    text,
    '''    private func drawResponse(context: inout GraphicsContext, size: CGSize) {\n        guard !displayBands.isEmpty else { return }\n        let count = max(180, Int(size.width / 3))\n        var path = Path()\n        for index in 0..<count {\n            let t = Double(index) / Double(max(1, count - 1))\n            let frequency = exp(log(minimumFrequency) + t * (log(graphMaximumFrequency) - log(minimumFrequency)))\n            let db = ProductionEQResponseMath.responseDB(bands: displayBands, sampleRate: sampleRate, frequencyHz: frequency)\n            let point = CGPoint(x: CGFloat(t) * size.width, y: yPosition(db, height: size.height))\n            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }\n        }\n        context.stroke(path, with: .color(.accentColor), lineWidth: 2.4)\n    }''',
    '''    private func drawResponse(context: inout GraphicsContext, size: CGSize) {\n        let program = ProductionEQResponseMath.compile(bands: displayBands, sampleRate: sampleRate)\n        guard !program.isEmpty else { return }\n        let count = max(180, Int(size.width / 3))\n        var path = Path()\n        for index in 0..<count {\n            let t = Double(index) / Double(max(1, count - 1))\n            let frequency = exp(log(minimumFrequency) + t * (log(graphMaximumFrequency) - log(minimumFrequency)))\n            let db = ProductionEQResponseMath.responseDB(program: program, sampleRate: sampleRate, frequencyHz: frequency)\n            let point = CGPoint(x: CGFloat(t) * size.width, y: yPosition(db, height: size.height))\n            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }\n        }\n        context.stroke(path, with: .color(.accentColor), lineWidth: 2.4)\n    }''',
    "single compile per graph draw"
)

text = replace_once(
    text,
    '''private enum ProductionEQResponseMath {\n    static func responseDB(bands: [EQBand], sampleRate: Double, frequencyHz: Double) -> Double {\n        guard sampleRate.isFinite, sampleRate > 0, frequencyHz > 0, frequencyHz < sampleRate * 0.5 else { return 0 }\n        var total = 0.0\n        for band in bands where band.enabled && band.type != .fir {\n            guard let sections = try? band.compiledSections(sampleRate: sampleRate) else { continue }\n            for section in sections {\n                total += sectionResponseDB(section.coefficients, sampleRate: sampleRate, frequencyHz: frequencyHz)\n            }\n        }\n        return min(max(total, -48), 48)\n    }''',
    '''private enum ProductionEQResponseMath {\n    static func compile(bands: [EQBand], sampleRate: Double) -> [N60BiquadCoefficients] {\n        var program: [N60BiquadCoefficients] = []\n        for band in bands where band.enabled && band.type != .fir {\n            guard let sections = try? band.compiledSections(sampleRate: sampleRate) else { continue }\n            program.append(contentsOf: sections.map(\\.coefficients))\n        }\n        return program\n    }\n\n    static func responseDB(\n        program: [N60BiquadCoefficients],\n        sampleRate: Double,\n        frequencyHz: Double\n    ) -> Double {\n        guard sampleRate.isFinite, sampleRate > 0, frequencyHz > 0, frequencyHz < sampleRate * 0.5 else { return 0 }\n        let total = program.reduce(0.0) { partial, coefficients in\n            partial + sectionResponseDB(coefficients, sampleRate: sampleRate, frequencyHz: frequencyHz)\n        }\n        return min(max(total, -48), 48)\n    }''',
    "compiled graph response program"
)

EQ.write_text(text)

validator = VALIDATOR.read_text()
validator = replace_once(
    validator,
    '''    "band.compiledSections(sampleRate: sampleRate)",\n    "Per-band FIR processing remains active",''',
    '''    "band.compiledSections(sampleRate: sampleRate)",\n    "ProductionEQResponseMath.compile",\n    "selectAdjacentBand(offset:",\n    "keyboardShortcut(\"n\", modifiers: [.command, .shift])",\n    "type == .fir && band.firKernel == nil",\n    "type == .allPass && configuration.phaseMode != .minimumPhase",\n    "Per-band FIR processing remains active",''',
    "validator refinement tokens"
)
VALIDATOR.write_text(validator)

with DOC.open("a") as handle:
    handle.write(r'''

## Interaction / presentation refinement

- Filter choices that the active control plane cannot accept are disabled instead of failing silently: an empty band cannot be switched to FIR until it owns a kernel, and user All-Pass is restricted to Minimum Phase.
- Add Band is available with Shift-Command-N; previous/next band selection uses Command-[ / Command-]; removal uses Command-Delete.
- Removing the selected band keeps selection on the nearest surviving neighbor rather than jumping unexpectedly to the first band.
- The response graph compiles each active band's control-plane sections once per graph draw and reuses that flattened coefficient program across plotted frequency points. It no longer redesigns the same filter sections for every pixel sample.
''')

print("Refined PR37 Equalizer workspace")
