from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path, old, new):
    p = ROOT / path
    text = p.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"patch anchor count {text.count(old)} for {path}: {old[:100]!r}")
    p.write_text(text.replace(old, new, 1))


def add_telemetry(anchor, kind):
    p = ROOT / "NotchSixty/UI/ProductionDynamicsView.swift"
    text = p.read_text()
    if text.count(anchor) != 1:
        raise SystemExit(f"telemetry anchor count {text.count(anchor)}: {anchor[:100]!r}")
    p.write_text(text.replace(anchor, anchor + f"            ProductionDynamicsTelemetryView(engine: engine, kind: {kind})\n", 1))


def apply():
    replace_once(
        "NotchSixty/Audio/AudioIOEngine.swift",
        "    func pollMainsHumTracking(minimumConfidence: Float = 0.70) {",
        "    func detectMainsHumOnce(minimumConfidence: Float = 0.55) async throws -> Bool {\n        guard lifecycle.state == .running else { return false }\n        let trackingWasEnabled = dynamicsConfiguration.mainsNotch.continuousTracking\n        if !trackingWasEnabled {\n            var detecting = dynamicsConfiguration\n            detecting.mainsNotch.continuousTracking = true\n            try replaceDynamicsConfiguration(detecting)\n        }\n        defer {\n            if !trackingWasEnabled {\n                var restored = dynamicsConfiguration\n                restored.mainsNotch.continuousTracking = false\n                try? replaceDynamicsConfiguration(restored)\n            }\n        }\n        try await Task.sleep(nanoseconds: 1_150_000_000)\n        return try applyDetectedMainsHum(minimumConfidence: minimumConfidence)\n    }\n\n    func pollMainsHumTracking(minimumConfidence: Float = 0.70) {",
    )

    replace_once(
        "NotchSixty/UI/ProductionDynamicsView.swift",
        "    @State private var selectedModule: ProductionDynamicsModule = .compressor\n",
        "    @State private var selectedModule: ProductionDynamicsModule = .compressor\n    @State private var mainsDetectInFlight = false\n    @State private var mainsDetectionMessage: String?\n",
    )

    add_telemetry(
        "        ) {\n",
        ".compressor",
    )
    # The first generic ') {' belongs to compressor by construction. Patch remaining
    # editors with their unique moduleCard opening lines.
    anchors = [
        ("        moduleCard(module: .multiband,", ".multiband"),
        ("        moduleCard(module: .expander,", ".expander"),
        ("        moduleCard(module: .pauseGate,", ".pauseGate"),
        ("        moduleCard(module: .gainRider,", ".gainRider"),
        ("        moduleCard(module: .denoiser,", ".denoiser"),
        ("        moduleCard(module: .deEsser,", ".deEsser"),
        ("        moduleCard(module: .mainsHum,", ".mainsHum"),
        ("        moduleCard(module: .loudnessMatch,", ".loudnessMatch"),
        ("        moduleCard(module: .dialogueLeveler,", ".dialogue"),
        ("        moduleCard(module: .limiter,", ".limiter"),
    ]
    p = ROOT / "NotchSixty/UI/ProductionDynamicsView.swift"
    text = p.read_text()
    for prefix, kind in anchors:
        start = text.find(prefix)
        if start < 0:
            raise SystemExit(f"missing module anchor {prefix}")
        brace = text.find(") {\n", start)
        if brace < 0:
            raise SystemExit(f"missing module content brace {prefix}")
        insert_at = brace + len(") {\n")
        text = text[:insert_at] + f"            ProductionDynamicsTelemetryView(engine: engine, kind: {kind})\n" + text[insert_at:]
    p.write_text(text)

    replace_once(
        "NotchSixty/UI/ProductionDynamicsView.swift",
        "            Text(\"Live rider gain will be added through its own demand-gated telemetry channel rather than enabling unrelated meters.\")\n                .font(.caption)\n                .foregroundStyle(.secondary)\n",
        "            Text(\"The live readout above is derived from existing Gain Rider runtime state and does not activate unrelated metering or analysis.\")\n                .font(.caption)\n                .foregroundStyle(.secondary)\n",
    )

    replace_once(
        "NotchSixty/UI/ProductionDynamicsView.swift",
        "            HStack {\n                Toggle(\"Continuous Tracking\", isOn: boolBinding({ $0.mainsNotch.continuousTracking }, { $0.mainsNotch.continuousTracking = $1 }))\n                Spacer()\n                Button(\"Apply Detected Frequency\") { _ = try? engine.applyDetectedMainsHum() }\n                    .buttonStyle(.glass)\n            }\n",
        "            HStack {\n                Toggle(\"Continuous Tracking\", isOn: boolBinding({ $0.mainsNotch.continuousTracking }, { $0.mainsNotch.continuousTracking = $1 }))\n                Spacer()\n                Button(mainsDetectInFlight ? \"Detecting…\" : \"Detect\") {\n                    guard !mainsDetectInFlight else { return }\n                    mainsDetectInFlight = true\n                    mainsDetectionMessage = nil\n                    Task { @MainActor in\n                        do {\n                            let applied = try await engine.detectMainsHumOnce()\n                            mainsDetectionMessage = applied ? \"Detected frequency applied.\" : \"No stable mains tone detected.\"\n                        } catch {\n                            mainsDetectionMessage = error.localizedDescription\n                        }\n                        mainsDetectInFlight = false\n                    }\n                }\n                .buttonStyle(.glassProminent)\n                .disabled(mainsDetectInFlight || engine.lifecycleState != .running)\n            }\n            if let mainsDetectionMessage {\n                Text(mainsDetectionMessage).font(.caption).foregroundStyle(.secondary)\n            }\n",
    )

    replace_once(
        "NotchSixty.xcodeproj/project.pbxproj",
        "\t\tA40000000000000000000012 /* ProductionDynamicsView.swift in Sources */ = {isa = PBXBuildFile; fileRef = A40000000000000000000022 /* ProductionDynamicsView.swift */; };",
        "\t\tA40000000000000000000012 /* ProductionDynamicsView.swift in Sources */ = {isa = PBXBuildFile; fileRef = A40000000000000000000022 /* ProductionDynamicsView.swift */; };\n\t\tA40000000000000000000013 /* ProductionDynamicsTelemetryView.swift in Sources */ = {isa = PBXBuildFile; fileRef = A40000000000000000000023 /* ProductionDynamicsTelemetryView.swift */; };",
    )
    replace_once(
        "NotchSixty.xcodeproj/project.pbxproj",
        "\t\tA40000000000000000000022 /* ProductionDynamicsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProductionDynamicsView.swift; sourceTree = \"<group>\"; };",
        "\t\tA40000000000000000000022 /* ProductionDynamicsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProductionDynamicsView.swift; sourceTree = \"<group>\"; };\n\t\tA40000000000000000000023 /* ProductionDynamicsTelemetryView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProductionDynamicsTelemetryView.swift; sourceTree = \"<group>\"; };",
    )
    replace_once(
        "NotchSixty.xcodeproj/project.pbxproj",
        "A40000000000000000000021 /* ProductionEqualizerView.swift */, A40000000000000000000022 /* ProductionDynamicsView.swift */,);",
        "A40000000000000000000021 /* ProductionEqualizerView.swift */, A40000000000000000000022 /* ProductionDynamicsView.swift */, A40000000000000000000023 /* ProductionDynamicsTelemetryView.swift */,);",
    )
    replace_once(
        "NotchSixty.xcodeproj/project.pbxproj",
        "\t\t\t\tA40000000000000000000012 /* ProductionDynamicsView.swift in Sources */,",
        "\t\t\t\tA40000000000000000000012 /* ProductionDynamicsView.swift in Sources */,\n\t\t\t\tA40000000000000000000013 /* ProductionDynamicsTelemetryView.swift in Sources */,",
    )
