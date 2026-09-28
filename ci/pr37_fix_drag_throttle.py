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
    '''    @State private var dragPreview: EQBand?\n    @State private var pendingPublishTask: Task<Void, Never>?''',
    '''    @State private var dragPreview: EQBand?\n    @State private var pendingDragBand: EQBand?\n    @State private var pendingPublishTask: Task<Void, Never>?''',
    "pending drag state"
)

text = text.replace(
    '''            pendingPublishTask?.cancel()\n            pendingPublishTask = nil\n            dragPreview = nil''',
    '''            pendingPublishTask?.cancel()\n            pendingPublishTask = nil\n            pendingDragBand = nil\n            dragPreview = nil'''
)

text = replace_once(
    text,
    '''                    pendingPublishTask?.cancel()\n                    pendingPublishTask = nil\n                    let sanitized = sanitize(band)\n                    dragPreview = nil\n                    try? engine.updateEQBand(sanitized)''',
    '''                    pendingPublishTask?.cancel()\n                    pendingPublishTask = nil\n                    pendingDragBand = nil\n                    let sanitized = sanitize(band)\n                    dragPreview = nil\n                    try? engine.updateEQBand(sanitized)''',
    "commit clears pending drag"
)

text = replace_once(
    text,
    '''                pendingPublishTask?.cancel()\n                pendingPublishTask = nil\n                dragPreview = nil\n                try? engine.updateEQBand(sanitize(updated))''',
    '''                pendingPublishTask?.cancel()\n                pendingPublishTask = nil\n                pendingDragBand = nil\n                dragPreview = nil\n                try? engine.updateEQBand(sanitize(updated))''',
    "inspector clears pending drag"
)

text = replace_once(
    text,
    '''        pendingPublishTask?.cancel()\n        pendingPublishTask = nil\n        dragPreview = nil\n        selectedBandID = bands.first?.id''',
    '''        pendingPublishTask?.cancel()\n        pendingPublishTask = nil\n        pendingDragBand = nil\n        dragPreview = nil\n        selectedBandID = bands.first?.id''',
    "bank switch clears pending drag"
)

text = replace_once(
    text,
    '''    private func scheduleCoalescedPublish(_ band: EQBand) {\n        pendingPublishTask?.cancel()\n        let sanitized = sanitize(band)\n        pendingPublishTask = Task { @MainActor in\n            try? await Task.sleep(nanoseconds: 33_000_000)\n            guard !Task.isCancelled else { return }\n            try? engine.updateEQBand(sanitized)\n        }\n    }''',
    '''    private func scheduleCoalescedPublish(_ band: EQBand) {\n        pendingDragBand = sanitize(band)\n        guard pendingPublishTask == nil else { return }\n\n        pendingPublishTask = Task { @MainActor in\n            while !Task.isCancelled {\n                guard let next = pendingDragBand else { break }\n                pendingDragBand = nil\n                try? engine.updateEQBand(next)\n                try? await Task.sleep(nanoseconds: 33_000_000)\n                guard !Task.isCancelled else { break }\n            }\n            pendingPublishTask = nil\n        }\n    }''',
    "latest-value drag throttle"
)
EQ.write_text(text)

validator = VALIDATOR.read_text()
validator = replace_once(
    validator,
    '''    "scheduleCoalescedPublish",\n    "33_000_000",''',
    '''    "scheduleCoalescedPublish",\n    "pendingDragBand = sanitize(band)",\n    "guard pendingPublishTask == nil else { return }",\n    "while !Task.isCancelled",\n    "try? engine.updateEQBand(next)",\n    "33_000_000",''',
    "throttle validator tokens"
)
VALIDATOR.write_text(validator)

with DOC.open("a") as handle:
    handle.write(r'''

## Drag publication semantics

The graph uses a latest-value throttle rather than a debounce. The first drag value publishes immediately, pointer-rate updates replace one pending value, and the publisher advances at most once per 33 ms while dragging. Gesture completion cancels the throttle and publishes the final exact band state. This keeps audible interaction live without allowing pointer event rate to become graph-publication rate.
''')

print("Converted PR37 graph dragging to latest-value throttle")
