#!/usr/bin/env python3
from pathlib import Path

path = Path("NotchSixty/Audio/CoreAudio/MultichannelCalibrationTransport.swift")
text = path.read_text(encoding="utf-8")
old = '''        guard physicalOutputChannelIndex < routePlan.physicalChannelCount else {\n            throw MultichannelCalibrationTransportError.outputChannelUnavailable(\n                index: physicalOutputChannelIndex,\n                availableChannels: Int(routePlan.physicalChannelCount)\n            )\n        }\n        guard let referenceOutput = orderedOutputs.first(where: { $0.uid == routePlan.referenceDeviceUID }) else {\n'''
new = '''        guard physicalOutputChannelIndex < routePlan.physicalChannelCount else {\n            throw MultichannelCalibrationTransportError.outputChannelUnavailable(\n                index: physicalOutputChannelIndex,\n                availableChannels: Int(routePlan.physicalChannelCount)\n            )\n        }\n        let physicalInputChannelCount = try Self.readChannelCount(\n            deviceID: input.deviceID,\n            scope: kAudioObjectPropertyScopeInput,\n            operation: "read physical measurement microphone channel count"\n        )\n        guard selectedInputChannelIndex >= 0,\n              selectedInputChannelIndex < physicalInputChannelCount else {\n            throw MultichannelCalibrationTransportError.invalidInputChannel(\n                index: selectedInputChannelIndex,\n                availableChannels: physicalInputChannelCount\n            )\n        }\n        guard let referenceOutput = orderedOutputs.first(where: { $0.uid == routePlan.referenceDeviceUID }) else {\n'''
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected one mic validation seam, found {count}")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
