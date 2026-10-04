import AppKit
import Foundation
import SwiftUI

struct ProductionProfileToolbar: View {
    @ObservedObject var profiles: ProductProfileController
    @ObservedObject var engine: AudioIOEngine

    @State private var editorPrompt: EditorPrompt?
    @State private var draftName = ""
    @State private var interchangeMessage: String?

    private enum EditorPrompt {
        case newContent
        case renameContent
        case newSystem
        case renameSystem

        var title: String {
            switch self {
            case .newContent: return "New Content Preset"
            case .renameContent: return "Rename Content Preset"
            case .newSystem: return "New Playback System"
            case .renameSystem: return "Rename Playback System"
            }
        }

        var actionTitle: String {
            switch self {
            case .newContent, .newSystem: return "Create"
            case .renameContent, .renameSystem: return "Rename"
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            contentPresetMenu
                .controlSize(.small)
            systemMenu
                .controlSize(.small)

            if let error = profiles.lastErrorDescription {
                Button {
                    profiles.clearError()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help(error)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .alert(
            editorPrompt?.title ?? "Edit",
            isPresented: Binding(
                get: { editorPrompt != nil },
                set: { if !$0 { editorPrompt = nil } }
            )
        ) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { editorPrompt = nil }
            Button(editorPrompt?.actionTitle ?? "Save") {
                let prompt = editorPrompt
                editorPrompt = nil
                switch prompt {
                case .newContent:
                    profiles.saveCurrentContentPreset(named: draftName)
                case .renameContent:
                    profiles.renameSelectedContentPreset(to: draftName)
                case .newSystem:
                    profiles.saveCurrentSystemProfile(named: draftName)
                case .renameSystem:
                    profiles.renameSelectedSystemProfile(to: draftName)
                case .none:
                    break
                }
            }
        }
        .alert(
            "Preset Interchange",
            isPresented: Binding(
                get: { interchangeMessage != nil },
                set: { if !$0 { interchangeMessage = nil } }
            )
        ) {
            Button("OK") { interchangeMessage = nil }
        } message: {
            Text(interchangeMessage ?? "")
        }
    }

    private var contentPresetMenu: some View {
        Menu {
            Section("Content Presets") {
                ForEach(profiles.contentPresets) { preset in
                    Button {
                        profiles.selectContentPreset(preset.id)
                    } label: {
                        HStack {
                            if profiles.selectedContentPresetID == preset.id {
                                Image(systemName: "checkmark")
                            }
                            Text(preset.name)
                        }
                    }
                }
            }

            Divider()
            Button("New Preset…") {
                begin(.newContent, defaultName: "My Preset")
            }
            if profiles.canOverwriteSelectedContentPreset {
                Button("Save Changes") {
                    profiles.overwriteSelectedContentPreset()
                }
                .disabled(!profiles.selectedContentPresetIsDirty)

                Button("Rename…") {
                    begin(.renameContent, defaultName: profiles.selectedContentPresetName)
                }

                Button("Delete", role: .destructive) {
                    profiles.deleteSelectedContentPreset()
                }
            }

            Divider()
            Button("Import Preset / EQ…") {
                importPreset()
            }

            Menu("Export") {
                Button("REW Filter Text…") { exportREW() }
                Button("EasyEffects Equalizer…") { exportEasyEffects() }
                Button("CamillaDSP YAML…") { exportCamillaDSP() }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                Text("Content: \(profiles.selectedContentPresetName)\(profiles.selectedContentPresetIsDirty ? " •" : "")")
            }
        }
        .buttonStyle(.glass)
        .help(
            profiles.selectedContentPresetIsDirty
                ? "Content Preset — unsaved changes"
                : "Content Preset: EQ/voicing, phase mode, dynamics, and input/headroom gain"
        )
    }

    private var systemMenu: some View {
        Menu {
            Section("Playback Systems") {
                ForEach(profiles.systemProfiles) { system in
                    Button {
                        profiles.selectSystemProfile(system.id)
                    } label: {
                        HStack {
                            if profiles.selectedSystemProfileID == system.id {
                                Image(systemName: "checkmark")
                            }
                            Text(displayName(for: system))
                        }
                    }
                }
            }

            Divider()
            Button("New Playback System…") {
                begin(.newSystem, defaultName: "My System")
            }
            if profiles.selectedSystemProfile != nil {
                Button("Save Changes") {
                    profiles.overwriteSelectedSystemProfile()
                }
                .disabled(!profiles.selectedSystemProfileIsDirty)

                Button("Rename…") {
                    begin(.renameSystem, defaultName: profiles.selectedSystemProfileName)
                }

                Button("Delete", role: .destructive) {
                    profiles.deleteSelectedSystemProfile()
                }

                Divider()
                Button("Associate with Current Output") {
                    profiles.associateSelectedSystemWithCurrentOutput()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: profiles.selectedSystemOutputMatches
                    ? "hifispeaker.2"
                    : "hifispeaker.2.fill")
                Text("System: \(selectedSystemDisplayName)\(profiles.selectedSystemProfileIsDirty ? " •" : "")")
            }
        }
        .buttonStyle(.glass)
        .help(
            profiles.selectedSystemProfileIsDirty
                ? "Playback System — unsaved changes"
                : "Playback System: output association, crossover, alignment, output trim, room correction, and speaker correction"
        )
    }

    private var selectedSystemDisplayName: String {
        guard let system = profiles.selectedSystemProfile else {
            return profiles.selectedSystemProfileName
        }
        return displayName(for: system)
    }

    private func displayName(for system: PlaybackSystemProfile) -> String {
        guard let outputProfile = system.state.outputDeviceProfile, outputProfile.enabled else {
            return system.name
        }
        return "\(system.name) · \(outputProfile.systemDisplayName)"
    }

    private func begin(_ prompt: EditorPrompt, defaultName: String) {
        draftName = defaultName
        editorPrompt = prompt
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.title = "Import Preset or EQ"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["eqpreset", "txt", "json"]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let previousStereo = engine.stereoEQConfiguration
        let previousGain = engine.gainConfiguration
        let previousDynamics = engine.dynamicsConfiguration

        do {
            let data = try Data(contentsOf: url)
            let imported = try PresetInterchange.importPreset(
                data: data,
                fileName: url.lastPathComponent,
                baseStereo: engine.stereoEQConfiguration
            )
            do {
                try engine.replaceStereoEQConfiguration(imported.stereoEQ)
                if let inputPreampDB = imported.inputPreampDB {
                    try engine.setInputPreampDB(inputPreampDB)
                }
                if let dynamics = imported.dynamics {
                    try engine.replaceDynamicsConfiguration(dynamics)
                }
            } catch {
                try? engine.replaceStereoEQConfiguration(previousStereo)
                try? engine.setInputPreampDB(previousGain.inputPreampDB)
                try? engine.replaceDynamicsConfiguration(previousDynamics)
                throw error
            }

            profiles.saveCurrentContentPreset(named: imported.suggestedName)
            if imported.warnings.isEmpty {
                interchangeMessage = "Imported \(url.lastPathComponent) as \(imported.suggestedName)."
            } else {
                interchangeMessage = "Imported \(url.lastPathComponent) with notes:\n\n• " + imported.warnings.joined(separator: "\n• ")
            }
        } catch {
            interchangeMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func exportREW() {
        do {
            let exported = try PresetInterchange.exportREW(engine.stereoEQConfiguration)
            try save(exported.data, suggestedName: "\(safeExportName)-REW.txt", allowedFileTypes: ["txt"])
            showExportWarnings(exported.warnings, format: "REW")
        } catch {
            interchangeMessage = "REW export failed: \(error.localizedDescription)"
        }
    }

    private func exportEasyEffects() {
        do {
            let exported = try PresetInterchange.exportEasyEffects(
                engine.stereoEQConfiguration,
                inputGainDB: engine.gainConfiguration.inputPreampDB
            )
            try save(exported.data, suggestedName: "\(safeExportName)-EasyEffects.json", allowedFileTypes: ["json"])
            showExportWarnings(exported.warnings, format: "EasyEffects")
        } catch {
            interchangeMessage = "EasyEffects export failed: \(error.localizedDescription)"
        }
    }

    private func exportCamillaDSP() {
        do {
            let exported = try PresetInterchange.exportCamillaDSP(
                engine.stereoEQConfiguration,
                sampleRate: engine.selectedOutputDevice?.nominalSampleRate ?? 48_000,
                playbackDeviceName: engine.selectedOutputDevice?.name
            )
            try save(exported.data, suggestedName: "\(safeExportName)-CamillaDSP.yml", allowedFileTypes: ["yml", "yaml"])
            showExportWarnings(exported.warnings, format: "CamillaDSP")
        } catch {
            interchangeMessage = "CamillaDSP export failed: \(error.localizedDescription)"
        }
    }

    private var safeExportName: String {
        let name = profiles.selectedContentPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return clean.isEmpty ? "Notch-Sixty-Preset" : clean
    }

    private func save(_ data: Data, suggestedName: String, allowedFileTypes: [String]) throws {
        let panel = NSSavePanel()
        panel.title = "Export Preset"
        panel.nameFieldStringValue = suggestedName
        panel.allowedFileTypes = allowedFileTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
    }

    private func showExportWarnings(_ warnings: [String], format: String) {
        guard !warnings.isEmpty else { return }
        interchangeMessage = "\(format) export completed with notes:\n\n• " + warnings.joined(separator: "\n• ")
    }
}

private struct PresetInterchangeImport {
    var stereoEQ: StereoEQConfiguration
    var inputPreampDB: Double?
    var dynamics: DynamicsConfiguration?
    var suggestedName: String
    var warnings: [String]
}

private struct PresetInterchangeExport {
    var data: Data
    var warnings: [String]
}

private enum PresetInterchangeError: Error, LocalizedError {
    case unsupportedFormat
    case invalidJSON
    case noUsableFilters
    case tooManyBands(Int)
    case unsupportedChannelMode(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "The selected file is not a supported legacy .eqpreset, REW filter text, or EasyEffects equalizer preset."
        case .invalidJSON:
            return "The preset JSON is malformed or does not contain a supported equalizer payload."
        case .noUsableFilters:
            return "The file contains no usable EQ filters."
        case .tooManyBands(let count):
            return "The import contains \(count) bands, exceeding Notch Sixty’s \(EQConfiguration.maximumBandCount)-band limit."
        case .unsupportedChannelMode(let mode):
            return "This export format cannot represent the current \(mode) channel mode without changing its meaning."
        case .encodingFailed:
            return "The preset could not be encoded."
        }
    }
}

private enum PresetInterchange {
    private static let defaultQ = 0.707

    static func importPreset(data: Data, fileName: String, baseStereo: StereoEQConfiguration) throws -> PresetInterchangeImport {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext == "eqpreset" {
            return try importLegacyPreset(data: data, fileName: fileName, baseStereo: baseStereo)
        }
        if ext == "json" {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PresetInterchangeError.invalidJSON
            }
            if easyEffectsEqualizer(in: root) != nil {
                return try importEasyEffects(root: root, fileName: fileName, baseStereo: baseStereo)
            }
            if root["version"] != nil || root["settings"] != nil || root["bands"] != nil || root["leftBands"] != nil {
                return try importLegacyPreset(root: root, fileName: fileName, baseStereo: baseStereo)
            }
            throw PresetInterchangeError.unsupportedFormat
        }
        if ext == "txt" || ext.isEmpty {
            guard let text = String(data: data, encoding: .utf8) else { throw PresetInterchangeError.unsupportedFormat }
            return try importREW(text: text, fileName: fileName, baseStereo: baseStereo)
        }
        throw PresetInterchangeError.unsupportedFormat
    }

    // MARK: Legacy .eqpreset

    private static func importLegacyPreset(data: Data, fileName: String, baseStereo: StereoEQConfiguration) throws -> PresetInterchangeImport {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PresetInterchangeError.invalidJSON
        }
        return try importLegacyPreset(root: root, fileName: fileName, baseStereo: baseStereo)
    }

    private static func importLegacyPreset(root: [String: Any], fileName: String, baseStereo: StereoEQConfiguration) throws -> PresetInterchangeImport {
        let settings = (root["settings"] as? [String: Any]) ?? root
        let version = settings.int("version") ?? root.int("version") ?? 1
        var warnings: [String] = []
        var stereo = baseStereo
        stereo.bypassed = false

        let importedName = settings.string("name", "presetName")
            ?? root.string("name", "presetName")
            ?? (fileName as NSString).deletingPathExtension

        if version <= 1 {
            let rawBands = settings.arrayOfDictionaries("bands")
            let activeCount = settings.int("activeBandCount")
            let bands = try parseLegacyBands(rawBands, legacyVersion: 1, activeCount: activeCount, warnings: &warnings)
            guard !bands.isEmpty else { throw PresetInterchangeError.noUsableFilters }
            stereo.setChannelMode(.linked)
            stereo.setEditChannel(.linked)
            stereo.replaceEditableBands(bands)
            warnings.append("Legacy v1 stored one shared EQ bank; it was migrated to Linked mode.")
        } else {
            let modeText = settings.string("channelMode") ?? "linked"
            let mode = legacyChannelMode(modeText)
            stereo.setChannelMode(mode)

            let leftRaw = settings.arrayOfDictionaries("leftBands")
            let rightRaw = settings.arrayOfDictionaries("rightBands")
            let sharedRaw = settings.arrayOfDictionaries("bands")

            switch mode {
            case .linked:
                let source = !leftRaw.isEmpty ? leftRaw : sharedRaw
                let bands = try parseLegacyBands(source, legacyVersion: version, activeCount: nil, warnings: &warnings)
                guard !bands.isEmpty else { throw PresetInterchangeError.noUsableFilters }
                stereo.setEditChannel(.linked)
                stereo.replaceEditableBands(bands)
            case .independent:
                let left = try parseLegacyBands(leftRaw, legacyVersion: version, activeCount: nil, warnings: &warnings)
                let right = try parseLegacyBands(rightRaw, legacyVersion: version, activeCount: nil, warnings: &warnings)
                guard !left.isEmpty || !right.isEmpty else { throw PresetInterchangeError.noUsableFilters }
                stereo.setEditChannel(.left)
                stereo.replaceEditableBands(left)
                stereo.setEditChannel(.right)
                stereo.replaceEditableBands(right)
                stereo.setEditChannel(.left)
            case .midSide:
                let mid = try parseLegacyBands(leftRaw, legacyVersion: version, activeCount: nil, warnings: &warnings)
                let side = try parseLegacyBands(rightRaw, legacyVersion: version, activeCount: nil, warnings: &warnings)
                guard !mid.isEmpty || !side.isEmpty else { throw PresetInterchangeError.noUsableFilters }
                stereo.setEditChannel(.mid)
                stereo.replaceEditableBands(mid)
                stereo.setEditChannel(.side)
                stereo.replaceEditableBands(side)
                stereo.setEditChannel(.mid)
                warnings.append("Legacy v2 used left/right storage arrays for the active Mid/Side banks; they were migrated as Mid and Side according to channelMode.")
            }
        }

        if let phase = settings.string("processingMode", "phaseMode", "compareMode") {
            stereo.phaseMode = legacyPhaseMode(phase, warnings: &warnings)
        }

        let inputGain = settings.double("inputPreampDB", "inputGain", "preampGainDB")
            .map { clamp($0, to: DSPGainConfiguration.inputPreampRange) }

        let dynamicsDictionary = (settings["dynamics"] as? [String: Any])
            ?? (settings["dynamicsConfig"] as? [String: Any])
            ?? (settings["advancedProcessing"] as? [String: Any])
        let dynamics = dynamicsDictionary.map { migrateLegacyDynamics($0, warnings: &warnings) }

        if settings["globalBypass"] != nil || root["globalBypass"] != nil {
            warnings.append("Global Bypass is transient audition state and was intentionally not restored from the legacy preset.")
        }
        if version <= 2 {
            warnings.append("Historical Constant-Q and Linkwitz target state was not reliably serialized by the legacy app; absent values use commercial defaults rather than inferred settings.")
        }

        return PresetInterchangeImport(
            stereoEQ: stereo,
            inputPreampDB: inputGain,
            dynamics: dynamics ?? (version >= 1 ? DynamicsConfiguration() : nil),
            suggestedName: importedName,
            warnings: unique(warnings)
        )
    }

    private static func parseLegacyBands(
        _ rawBands: [[String: Any]],
        legacyVersion: Int,
        activeCount: Int?,
        warnings: inout [String]
    ) throws -> [EQBand] {
        if rawBands.count > EQConfiguration.maximumBandCount {
            throw PresetInterchangeError.tooManyBands(rawBands.count)
        }
        var result: [EQBand] = []
        for (index, raw) in rawBands.enumerated() {
            let type = legacyFilterType(raw["filterType"] ?? raw["type"], warnings: &warnings)
            if type == .fir {
                warnings.append("Legacy FIR band \(index + 1) had no reconstructible kernel in normal .eqpreset storage and was skipped.")
                continue
            }

            var q = raw.double("q", "Q") ?? defaultQ
            if legacyVersion <= 1, let bandwidth = raw.double("bandwidth", "bandwidthOctaves", "bw") {
                q = qFromBandwidthOctaves(bandwidth)
            }
            q = clamp(q.isFinite && q > 0 ? q : defaultQ, to: 0.1...20.0)

            let frequency = max(1.0, raw.double("frequency", "frequencyHz", "freq") ?? 1_000)
            let gain = clamp(raw.double("gain", "gainDB") ?? 0, to: StereoEQConfiguration.bandGainRange)
            let slope = legacySlope(raw["slope"])
            let bypassed = raw.bool("bypass", "bypassed") ?? false
            let explicitlyEnabled = raw.bool("enabled")
            let enabledByCount = activeCount.map { index < $0 } ?? true
            var enabled = explicitlyEnabled ?? !bypassed
            enabled = enabled && enabledByCount

            let targetHz = raw.double("linkwitzTargetHz", "targetFrequencyHz")
            let targetQ = raw.double("linkwitzTargetQ", "targetQ")
            if type == .linkwitzTransform, targetHz == nil {
                warnings.append("Linkwitz Transform band \(index + 1) did not contain a persisted target frequency; the commercial 40 Hz default was used.")
            }

            var dynamic = EQBandDynamicConfiguration()
            if let dyn = (raw["dynamic"] as? [String: Any]) ?? (raw["dynamicEQ"] as? [String: Any]) {
                dynamic.enabled = dyn.bool("enabled") ?? raw.bool("dynamicEQEnabled") ?? false
                if let value = dyn.double("thresholdDB", "threshold") { dynamic.thresholdDB = clamp(value, to: EQBandDynamicConfiguration.thresholdRange) }
                if let value = dyn.double("ratio") { dynamic.ratio = clamp(value, to: EQBandDynamicConfiguration.ratioRange) }
                if let value = dyn.double("rangeDB", "range") { dynamic.rangeDB = clamp(value, to: EQBandDynamicConfiguration.rangeRange) }
                if let value = dyn.double("attackMs", "attack") { dynamic.attackMs = clamp(value, to: EQBandDynamicConfiguration.attackRange) }
                if let value = dyn.double("releaseMs", "release") { dynamic.releaseMs = clamp(value, to: EQBandDynamicConfiguration.releaseRange) }
            } else if raw.bool("dynamicEQEnabled") == true {
                dynamic.enabled = type.supportsDynamicEQ
            }
            if dynamic.enabled && !type.supportsDynamicEQ {
                dynamic.enabled = false
                warnings.append("Dynamic EQ on legacy band \(index + 1) is unsupported for \(type.displayName) and was disabled rather than substituted.")
            }

            result.append(EQBand(
                enabled: enabled,
                type: type,
                frequencyHz: frequency,
                gainDB: gain,
                q: q,
                slope: slope,
                constantQ: raw.bool("constantQ") ?? false,
                linkwitzTargetHz: targetHz ?? 40,
                linkwitzTargetQ: targetQ ?? defaultQ,
                dynamic: dynamic
            ))
        }
        return result
    }

    private static func migrateLegacyDynamics(_ raw: [String: Any], warnings: inout [String]) -> DynamicsConfiguration {
        var result = DynamicsConfiguration()

        if let compressor = raw["compressor"] as? [String: Any] {
            result.compressor.enabled = compressor.bool("enabled") ?? result.compressor.enabled
            if let value = compressor.double("thresholdDB", "threshold") { result.compressor.thresholdDB = clamp(value, to: -60...0) }
            if let value = compressor.double("ratio") { result.compressor.ratio = clamp(value, to: 1...20) }
            if let value = compressor.double("kneeWidthDB", "knee") { result.compressor.kneeWidthDB = clamp(value, to: 0...20) }
            if let value = compressor.double("attackMs", "attack") { result.compressor.attackMs = clamp(value, to: 0.1...100) }
            if let value = compressor.double("releaseMs", "release") { result.compressor.releaseMs = clamp(value, to: 5...1_000) }
            if let value = compressor.double("makeupGainDB", "makeupGain", "makeup") { result.compressor.makeupGainDB = clamp(value, to: -24...24) }
        }

        if let pause = (raw["pauseGate"] as? [String: Any]) ?? (raw["pause_gate"] as? [String: Any]) {
            result.pauseGate.enabled = pause.bool("enabled") ?? result.pauseGate.enabled
            if let value = pause.double("thresholdDBFS", "threshold") { result.pauseGate.thresholdDBFS = clamp(value, to: -80 ... -40) }
            if let value = pause.double("holdMs", "hold") { result.pauseGate.holdMs = clamp(value, to: 100...2_000) }
            // Intentional semantic migration: legacy Attack opened/faded in and
            // legacy Release closed/faded out. Commercial naming is the inverse.
            if let legacyAttack = pause.double("attackMs", "attack") { result.pauseGate.releaseMs = clamp(legacyAttack, to: 10...500) }
            if let legacyRelease = pause.double("releaseMs", "release") { result.pauseGate.attackMs = clamp(legacyRelease, to: 1...100) }
            if let value = pause.double("hysteresisDB", "hysteresis") { result.pauseGate.hysteresisDB = clamp(value, to: 0...6) }
            warnings.append("Pause Gate timing was translated from legacy Attack=open/Release=close to the commercial Attack=fade-out/Release=fade-in convention.")
        }

        if let deEsser = (raw["deEsser"] as? [String: Any]) ?? (raw["deesser"] as? [String: Any]) {
            result.deEsser.enabled = deEsser.bool("enabled") ?? result.deEsser.enabled
            if let value = deEsser.double("frequencyHz", "frequency") { result.deEsser.frequencyHz = clamp(value, to: 2_000...10_000) }
            if let value = deEsser.double("detectionQ", "q") { result.deEsser.detectionQ = clamp(value, to: 0.5...8) }
            if let value = deEsser.double("thresholdDB", "threshold") { result.deEsser.thresholdDB = clamp(value, to: -60...0) }
            if let value = deEsser.double("ratio") { result.deEsser.ratio = clamp(value, to: 1...20) }
            if let value = deEsser.double("rangeDB", "range") { result.deEsser.rangeDB = clamp(value, to: -24...0) }
            if let value = deEsser.double("attackMs", "attack") { result.deEsser.attackMs = clamp(value, to: 0.1...100) }
            if let value = deEsser.double("releaseMs", "release") { result.deEsser.releaseMs = clamp(value, to: 10...1_000) }
        }

        if let limiter = raw["limiter"] as? [String: Any] {
            result.limiter.enabled = limiter.bool("enabled") ?? result.limiter.enabled
            if let value = limiter.double("ceilingDB", "ceiling") { result.limiter.ceilingDB = clamp(value, to: -20...0) }
            if let value = limiter.double("attackMs", "attack") { result.limiter.attackMs = clamp(value, to: 0.1...50) }
            if let value = limiter.double("releaseMs", "release") { result.limiter.releaseMs = clamp(value, to: 5...500) }
            if let value = limiter.double("lookAheadMs", "lookAhead") { result.limiter.lookAheadMs = clamp(value, to: 0...20) }
        }

        if let multiband = (raw["multibandCompressor"] as? [String: Any]) ?? (raw["multiband"] as? [String: Any]) {
            result.multibandCompressor.enabled = multiband.bool("enabled") ?? result.multibandCompressor.enabled
            if let value = multiband.double("lowMidFrequencyHz", "lowMidFrequency") { result.multibandCompressor.lowMidFrequencyHz = clamp(value, to: 40...250) }
            if let value = multiband.double("midHighFrequencyHz", "midHighFrequency") { result.multibandCompressor.midHighFrequencyHz = clamp(value, to: 1_000...8_000) }
            for prefix in ["low", "mid", "high"] {
                applyLegacyMultibandValues(multiband, prefix: prefix, to: &result)
            }
        }

        return result
    }

    private static func applyLegacyMultibandValues(_ raw: [String: Any], prefix: String, to result: inout DynamicsConfiguration) {
        func value(_ suffix: String) -> Double? { raw.double("\(prefix)\(suffix)") }
        switch prefix {
        case "low":
            if let v = value("ThresholdDB") { result.multibandCompressor.lowThresholdDB = clamp(v, to: -60...0) }
            if let v = value("Ratio") { result.multibandCompressor.lowRatio = clamp(v, to: 1...20) }
            if let v = value("AttackMs") { result.multibandCompressor.lowAttackMs = clamp(v, to: 1...200) }
            if let v = value("ReleaseMs") { result.multibandCompressor.lowReleaseMs = clamp(v, to: 10...1_000) }
            if let v = value("KneeDB") { result.multibandCompressor.lowKneeDB = clamp(v, to: 0...20) }
            if let v = value("MakeupGainDB") { result.multibandCompressor.lowMakeupGainDB = clamp(v, to: -12...12) }
        case "mid":
            if let v = value("ThresholdDB") { result.multibandCompressor.midThresholdDB = clamp(v, to: -60...0) }
            if let v = value("Ratio") { result.multibandCompressor.midRatio = clamp(v, to: 1...20) }
            if let v = value("AttackMs") { result.multibandCompressor.midAttackMs = clamp(v, to: 1...200) }
            if let v = value("ReleaseMs") { result.multibandCompressor.midReleaseMs = clamp(v, to: 10...1_000) }
            if let v = value("KneeDB") { result.multibandCompressor.midKneeDB = clamp(v, to: 0...20) }
            if let v = value("MakeupGainDB") { result.multibandCompressor.midMakeupGainDB = clamp(v, to: -12...12) }
        case "high":
            if let v = value("ThresholdDB") { result.multibandCompressor.highThresholdDB = clamp(v, to: -60...0) }
            if let v = value("Ratio") { result.multibandCompressor.highRatio = clamp(v, to: 1...20) }
            if let v = value("AttackMs") { result.multibandCompressor.highAttackMs = clamp(v, to: 1...200) }
            if let v = value("ReleaseMs") { result.multibandCompressor.highReleaseMs = clamp(v, to: 10...1_000) }
            if let v = value("KneeDB") { result.multibandCompressor.highKneeDB = clamp(v, to: 0...20) }
            if let v = value("MakeupGainDB") { result.multibandCompressor.highMakeupGainDB = clamp(v, to: -12...12) }
        default:
            break
        }
    }

    // MARK: REW

    private static func importREW(text: String, fileName: String, baseStereo: StereoEQConfiguration) throws -> PresetInterchangeImport {
        var bands: [EQBand] = []
        var warnings: [String] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let upper = trimmed.uppercased()
            if upper.contains(" NONE") || upper.hasSuffix("NONE") { continue }
            guard let token = regexCapture("(?:ON|OFF)\\s+([A-Z]+)", in: upper, group: 1),
                  let type = rewFilterType(token) else { continue }
            guard let frequency = regexNumber("FC\\s+([-+0-9.E]+)", in: upper) else { continue }
            let gain = regexNumber("GAIN\\s+([-+0-9.E]+)", in: upper) ?? 0
            var q = regexNumber("\\bQ\\s+([-+0-9.E]+)", in: upper)
            if q == nil, let bandwidth = regexNumber("BW(?:/60)?\\s+([-+0-9.E]+)", in: upper) {
                q = qFromBandwidthOctaves(bandwidth)
            }
            let bypassed = upper.contains(" OFF ") || upper.contains(": OFF")
            bands.append(EQBand(
                enabled: !bypassed,
                type: type,
                frequencyHz: max(1, frequency),
                gainDB: clamp(gain, to: StereoEQConfiguration.bandGainRange),
                q: clamp(q ?? defaultQ, to: 0.1...20),
                slope: .db12
            ))
        }
        guard !bands.isEmpty else { throw PresetInterchangeError.noUsableFilters }
        if bands.count > EQConfiguration.maximumBandCount { throw PresetInterchangeError.tooManyBands(bands.count) }

        var stereo = baseStereo
        stereo.setChannelMode(.linked)
        stereo.setEditChannel(.linked)
        stereo.bypassed = false
        stereo.replaceEditableBands(bands)
        warnings.append("REW filter text is a single EQ bank and was imported in Linked mode.")
        return PresetInterchangeImport(
            stereoEQ: stereo,
            inputPreampDB: nil,
            dynamics: nil,
            suggestedName: (fileName as NSString).deletingPathExtension,
            warnings: warnings
        )
    }

    static func exportREW(_ stereo: StereoEQConfiguration) throws -> PresetInterchangeExport {
        let bands = stereo.editableBands
        var lines = ["# Notch Sixty REW-compatible filter export", "# Channel lane: \(stereo.editChannel.displayName)"]
        var warnings: [String] = []
        var number = 1
        for band in bands {
            guard let token = rewToken(for: band.type) else {
                warnings.append("\(band.type.displayName) band at \(Int(band.frequencyHz.rounded())) Hz is not representable in REW filter text and was omitted.")
                continue
            }
            if band.slope != .db12 && band.type.supportsSlope {
                warnings.append("REW generic text does not preserve \(band.slope.displayName) on \(band.type.displayName); filter \(number) exports its Q only.")
            }
            let state = band.enabled ? "ON" : "OFF"
            lines.append(String(format: "Filter %d: %@ %@ Fc %.3f Hz Gain %+.3f dB Q %.5f", number, state, token, band.frequencyHz, band.gainDB, band.q))
            number += 1
        }
        guard number > 1 else { throw PresetInterchangeError.noUsableFilters }
        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { throw PresetInterchangeError.encodingFailed }
        return PresetInterchangeExport(data: data, warnings: unique(warnings))
    }

    // MARK: EasyEffects

    private static func importEasyEffects(root: [String: Any], fileName: String, baseStereo: StereoEQConfiguration) throws -> PresetInterchangeImport {
        guard let equalizer = easyEffectsEqualizer(in: root) else { throw PresetInterchangeError.invalidJSON }
        var warnings: [String] = []
        let left = try parseEasyEffectsBands(equalizer["left"] as? [String: Any], warnings: &warnings)
        let right = try parseEasyEffectsBands(equalizer["right"] as? [String: Any], warnings: &warnings)
        guard !left.isEmpty || !right.isEmpty else { throw PresetInterchangeError.noUsableFilters }

        var stereo = baseStereo
        stereo.bypassed = equalizer.bool("bypass") ?? false
        let split = equalizer.bool("split-channels") ?? !right.isEmpty
        if split && !right.isEmpty {
            stereo.setChannelMode(.independent)
            stereo.setEditChannel(.left)
            stereo.replaceEditableBands(left)
            stereo.setEditChannel(.right)
            stereo.replaceEditableBands(right)
            stereo.setEditChannel(.left)
        } else {
            stereo.setChannelMode(.linked)
            stereo.setEditChannel(.linked)
            stereo.replaceEditableBands(left.isEmpty ? right : left)
        }

        let inputGain = equalizer.double("input-gain").map { clamp($0, to: DSPGainConfiguration.inputPreampRange) }
        if let outputGain = equalizer.double("output-gain"), abs(outputGain) > 0.0001 {
            warnings.append("EasyEffects output-gain (\(outputGain) dB) was not imported because Notch Sixty owns output trim in the Playback System layer, not the Content Preset.")
        }
        return PresetInterchangeImport(
            stereoEQ: stereo,
            inputPreampDB: inputGain,
            dynamics: nil,
            suggestedName: (fileName as NSString).deletingPathExtension,
            warnings: unique(warnings)
        )
    }

    private static func parseEasyEffectsBands(_ raw: [String: Any]?, warnings: inout [String]) throws -> [EQBand] {
        guard let raw else { return [] }
        let ordered = raw.compactMap { key, value -> (Int, [String: Any])? in
            guard let dictionary = value as? [String: Any] else { return nil }
            let digits = key.filter(\.isNumber)
            return (Int(digits) ?? Int.max, dictionary)
        }.sorted { $0.0 < $1.0 }
        if ordered.count > EQConfiguration.maximumBandCount { throw PresetInterchangeError.tooManyBands(ordered.count) }

        return ordered.compactMap { index, dictionary in
            guard let typeString = dictionary.string("type"), let type = easyEffectsFilterType(typeString) else {
                warnings.append("EasyEffects band \(index) uses unsupported filter type \(dictionary.string("type") ?? "unknown") and was omitted.")
                return nil
            }
            let frequency = max(1, dictionary.double("frequency") ?? 1_000)
            let gain = clamp(dictionary.double("gain") ?? 0, to: StereoEQConfiguration.bandGainRange)
            let q = clamp(dictionary.double("q") ?? defaultQ, to: 0.1...20)
            return EQBand(
                enabled: !(dictionary.bool("mute") ?? false),
                type: type,
                frequencyHz: frequency,
                gainDB: gain,
                q: q,
                slope: easyEffectsSlope(dictionary.string("slope"))
            )
        }
    }

    static func exportEasyEffects(_ stereo: StereoEQConfiguration, inputGainDB: Double) throws -> PresetInterchangeExport {
        var warnings: [String] = []
        let leftBands: [EQBand]
        let rightBands: [EQBand]
        let split: Bool
        switch stereo.channelMode {
        case .linked:
            leftBands = stereo.linkedBands
            rightBands = stereo.linkedBands
            split = false
        case .independent:
            leftBands = stereo.leftBands
            rightBands = stereo.rightBands
            split = true
        case .midSide:
            throw PresetInterchangeError.unsupportedChannelMode(stereo.channelMode.displayName)
        }

        let left = easyEffectsBands(leftBands, warnings: &warnings)
        let right = easyEffectsBands(rightBands, warnings: &warnings)
        let equalizer: [String: Any] = [
            "balance": 0.0,
            "bypass": stereo.bypassed,
            "input-gain": inputGainDB,
            "output-gain": 0.0,
            "left": left,
            "right": right,
            "split-channels": split,
        ]
        let root: [String: Any] = [
            "output": [
                "blocklist": [],
                "equalizer#0": equalizer,
                "plugins_order": ["equalizer#0"],
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        warnings.append("EasyEffects output-gain is exported as 0 dB because Notch Sixty Playback System output trim is intentionally outside Content Preset ownership.")
        return PresetInterchangeExport(data: data, warnings: unique(warnings))
    }

    private static func easyEffectsBands(_ bands: [EQBand], warnings: inout [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        var outputIndex = 0
        for band in bands {
            guard let type = easyEffectsType(for: band.type) else {
                warnings.append("\(band.type.displayName) at \(Int(band.frequencyHz.rounded())) Hz is outside the audited EasyEffects subset and was omitted.")
                continue
            }
            result["band\(outputIndex)"] = [
                "frequency": band.frequencyHz,
                "gain": band.gainDB,
                "mode": "RLC (BT)",
                "mute": !band.enabled,
                "q": band.q,
                "slope": easyEffectsSlopeString(band.slope),
                "solo": false,
                "type": type,
                "width": 4.0,
            ] as [String: Any]
            outputIndex += 1
        }
        return result
    }

    // MARK: CamillaDSP

    static func exportCamillaDSP(
        _ stereo: StereoEQConfiguration,
        sampleRate: Double,
        playbackDeviceName: String?
    ) throws -> PresetInterchangeExport {
        var warnings: [String] = []
        let left: [EQBand]
        let right: [EQBand]
        switch stereo.channelMode {
        case .linked:
            left = stereo.linkedBands
            right = stereo.linkedBands
        case .independent:
            left = stereo.leftBands
            right = stereo.rightBands
        case .midSide:
            throw PresetInterchangeError.unsupportedChannelMode(stereo.channelMode.displayName)
        }

        var filterLines: [String] = []
        var leftNames: [String] = []
        var rightNames: [String] = []
        appendCamillaBands(left, channelPrefix: "L", filterLines: &filterLines, names: &leftNames, warnings: &warnings)
        appendCamillaBands(right, channelPrefix: "R", filterLines: &filterLines, names: &rightNames, warnings: &warnings)
        guard !leftNames.isEmpty || !rightNames.isEmpty else { throw PresetInterchangeError.noUsableFilters }

        let playback = yamlQuoted(playbackDeviceName ?? "CHANGE_ME_PLAYBACK")
        var lines: [String] = [
            "---",
            "title: \"Notch Sixty export\"",
            "description: \"Exported from the current Notch Sixty Content Preset. Review device names before use.\"",
            "devices:",
            "  samplerate: \(Int(sampleRate.rounded()))",
            "  chunksize: 1024",
            "  capture:",
            "    type: CoreAudio",
            "    channels: 2",
            "    device: \"CHANGE_ME_CAPTURE\"",
            "  playback:",
            "    type: CoreAudio",
            "    channels: 2",
            "    device: \(playback)",
            "filters:",
        ]
        if filterLines.isEmpty {
            lines.append("  {}")
        } else {
            lines.append(contentsOf: filterLines)
        }
        lines.append("pipeline:")
        if !leftNames.isEmpty {
            lines.append("  - type: Filter")
            lines.append("    channels: [0]")
            lines.append("    names:")
            leftNames.forEach { lines.append("      - \($0)") }
        }
        if !rightNames.isEmpty {
            lines.append("  - type: Filter")
            lines.append("    channels: [1]")
            lines.append("    names:")
            rightNames.forEach { lines.append("      - \($0)") }
        }
        warnings.append("CamillaDSP capture device is exported as CHANGE_ME_CAPTURE because Notch Sixty’s macOS system-audio capture route is not a portable CamillaDSP input-device identity.")
        warnings.append("This first commercial exporter covers the audited EQ/FIR subset. PR42 separately classifies physical speaker-matrix/crossover export before closure.")
        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { throw PresetInterchangeError.encodingFailed }
        return PresetInterchangeExport(data: data, warnings: unique(warnings))
    }

    private static func appendCamillaBands(
        _ bands: [EQBand],
        channelPrefix: String,
        filterLines: inout [String],
        names: inout [String],
        warnings: inout [String]
    ) {
        for (index, band) in bands.enumerated() where band.enabled {
            let name = "eq_\(channelPrefix.lowercased())_\(index + 1)"
            switch band.type {
            case .fir:
                guard let kernel = band.firKernel else {
                    warnings.append("FIR band \(index + 1) has no kernel and was omitted from CamillaDSP export.")
                    continue
                }
                filterLines.append("  \(name):")
                filterLines.append("    type: Conv")
                filterLines.append("    parameters:")
                filterLines.append("      type: Values")
                let values = kernel.taps.map { String(format: "%.9g", Double($0)) }.joined(separator: ", ")
                filterLines.append("      values: [\(values)]")
                names.append(name)
            case .peaking, .lowShelf, .highShelf, .lowPass, .highPass, .bandPass, .notch, .allPass, .tilt:
                filterLines.append("  \(name):")
                if (band.type == .lowPass || band.type == .highPass) && band.slope != .db12 {
                    filterLines.append("    type: BiquadCombo")
                    filterLines.append("    parameters:")
                    filterLines.append("      type: \(band.type == .lowPass ? "ButterworthLowpass" : "ButterworthHighpass")")
                    filterLines.append("      freq: \(yamlNumber(band.frequencyHz))")
                    filterLines.append("      order: \(band.slope.order)")
                } else {
                    filterLines.append("    type: \(band.type == .tilt ? "BiquadCombo" : "Biquad")")
                    filterLines.append("    parameters:")
                    filterLines.append("      type: \(camillaType(band.type))")
                    if band.type == .tilt {
                        filterLines.append("      gain: \(yamlNumber(band.gainDB))")
                    } else {
                        filterLines.append("      freq: \(yamlNumber(band.frequencyHz))")
                        if band.type == .peaking || band.type == .lowShelf || band.type == .highShelf {
                            filterLines.append("      gain: \(yamlNumber(band.gainDB))")
                        }
                        filterLines.append("      q: \(yamlNumber(band.q))")
                    }
                }
                if (band.type == .lowShelf || band.type == .highShelf) && band.slope != .db12 {
                    warnings.append("CamillaDSP shelf export uses the band Q and does not reproduce Notch Sixty’s cascaded \(band.slope.displayName) shelf exactly.")
                }
                names.append(name)
            case .linkwitzTransform:
                warnings.append("Linkwitz Transform at \(Int(band.frequencyHz.rounded())) Hz requires coefficient-level export and was omitted from this CamillaDSP subset rather than approximated.")
            }
        }
    }

    // MARK: Mapping / helpers

    private static func legacyChannelMode(_ value: String) -> EQChannelMode {
        let normalized = normalize(value)
        if normalized.contains("midside") || normalized == "ms" { return .midSide }
        if normalized.contains("stereo") || normalized.contains("independent") { return .independent }
        return .linked
    }

    private static func legacyPhaseMode(_ value: String, warnings: inout [String]) -> EQPhaseMode {
        let normalized = normalize(value)
        if normalized.contains("linear") { return .linearPhase }
        if normalized.contains("mixed") { return .mixedPhase }
        if normalized.contains("flat") || normalized.contains("delta") {
            warnings.append("Legacy Flat/Delta was comparison state, not EQ phase state; the imported preset uses Minimum Phase and Notch Sixty’s current Reference/Delta audition controls remain transient.")
        }
        return .minimumPhase
    }

    private static func legacyFilterType(_ raw: Any?, warnings: inout [String]) -> EQFilterType {
        if let number = raw as? NSNumber {
            switch number.intValue {
            case 0: return .peaking
            case 1: return .lowPass
            case 2: return .highPass
            case 3: return .lowShelf
            case 4: return .highShelf
            case 5: return .bandPass
            case 6: return .notch
            case 7: return .allPass
            case 8: return .fir
            case 9: return .linkwitzTransform
            case 10: return .tilt
            default:
                warnings.append("Unknown legacy filter raw value \(number.intValue) was migrated as Parametric.")
                return .peaking
            }
        }
        guard let text = raw as? String else { return .peaking }
        return mappedFilterType(text) ?? {
            warnings.append("Unknown legacy filter type \(text) was migrated as Parametric.")
            return .peaking
        }()
    }

    private static func mappedFilterType(_ text: String) -> EQFilterType? {
        switch normalize(text) {
        case "pk", "peq", "pa", "parametric", "peak", "peaking", "bell": return .peaking
        case "ls", "lowshelf", "loshelf": return .lowShelf
        case "hs", "highshelf", "hishelf": return .highShelf
        case "lp", "lowpass": return .lowPass
        case "hp", "highpass": return .highPass
        case "bp", "bandpass": return .bandPass
        case "notch": return .notch
        case "ap", "allpass": return .allPass
        case "fir", "convolution": return .fir
        case "linkwitz", "linkwitztransform": return .linkwitzTransform
        case "tilt", "tilteq": return .tilt
        default: return nil
        }
    }

    private static func legacySlope(_ raw: Any?) -> EQFilterSlope {
        if let number = raw as? NSNumber, let slope = EQFilterSlope(rawValue: number.intValue) { return slope }
        if let text = raw as? String {
            let normalized = normalize(text)
            let digits = normalized.filter(\.isNumber)
            if let value = Int(digits), let slope = EQFilterSlope(rawValue: value) { return slope }
            if normalized.hasPrefix("x"), let multiplier = Int(normalized.dropFirst()) {
                return EQFilterSlope(rawValue: min(96, max(6, multiplier * 12))) ?? .db12
            }
        }
        return .db12
    }

    private static func rewFilterType(_ token: String) -> EQFilterType? {
        switch token.uppercased() {
        case "PK", "PEQ", "PA", "PARAMETRIC": return .peaking
        case "LS", "LOWSHELF": return .lowShelf
        case "HS", "HIGHSHELF": return .highShelf
        case "LP", "LOWPASS": return .lowPass
        case "HP", "HIGHPASS": return .highPass
        case "BP", "BANDPASS": return .bandPass
        case "NOTCH": return .notch
        default: return nil
        }
    }

    private static func rewToken(for type: EQFilterType) -> String? {
        switch type {
        case .peaking: return "PK"
        case .lowShelf: return "LS"
        case .highShelf: return "HS"
        case .lowPass: return "LP"
        case .highPass: return "HP"
        case .bandPass: return "BP"
        case .notch: return "NOTCH"
        case .allPass, .linkwitzTransform, .tilt, .fir: return nil
        }
    }

    private static func easyEffectsEqualizer(in root: [String: Any]) -> [String: Any]? {
        guard let output = root["output"] as? [String: Any] else { return nil }
        if let exact = output["equalizer#0"] as? [String: Any] { return exact }
        if let legacy = output["equalizer"] as? [String: Any] { return legacy }
        for (key, value) in output where key.lowercased().hasPrefix("equalizer") {
            if let dictionary = value as? [String: Any] { return dictionary }
        }
        return nil
    }

    private static func easyEffectsFilterType(_ value: String) -> EQFilterType? { mappedFilterType(value) }

    private static func easyEffectsType(for type: EQFilterType) -> String? {
        switch type {
        case .peaking: return "Bell"
        case .lowShelf: return "Lo-shelf"
        case .highShelf: return "Hi-shelf"
        case .lowPass: return "Lo-pass"
        case .highPass: return "Hi-pass"
        case .bandPass: return "Band-pass"
        case .notch: return "Notch"
        case .allPass, .fir, .linkwitzTransform, .tilt: return nil
        }
    }

    private static func easyEffectsSlope(_ value: String?) -> EQFilterSlope {
        guard let value else { return .db12 }
        let normalized = normalize(value)
        if normalized.hasPrefix("x"), let multiplier = Int(normalized.dropFirst()) {
            return EQFilterSlope(rawValue: min(96, max(6, multiplier * 12))) ?? .db12
        }
        return legacySlope(value)
    }

    private static func easyEffectsSlopeString(_ slope: EQFilterSlope) -> String {
        let multiplier = max(1, slope.rawValue / 12)
        return "x\(multiplier)"
    }

    private static func camillaType(_ type: EQFilterType) -> String {
        switch type {
        case .peaking: return "Peaking"
        case .lowShelf: return "Lowshelf"
        case .highShelf: return "Highshelf"
        case .lowPass: return "Lowpass"
        case .highPass: return "Highpass"
        case .bandPass: return "Bandpass"
        case .notch: return "Notch"
        case .allPass: return "Allpass"
        case .tilt: return "Tilt"
        case .fir: return "Conv"
        case .linkwitzTransform: return "Free"
        }
    }

    private static func qFromBandwidthOctaves(_ bandwidth: Double) -> Double {
        guard bandwidth.isFinite, bandwidth > 0 else { return defaultQ }
        let power = pow(2.0, bandwidth)
        let denominator = power - 1.0
        guard denominator > 0 else { return defaultQ }
        return sqrt(power) / denominator
    }

    private static func regexNumber(_ pattern: String, in text: String) -> Double? {
        guard let capture = regexCapture(pattern, in: text, group: 1) else { return nil }
        return Double(capture)
    }

    private static func regexCapture(_ pattern: String, in text: String, group: Int) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              group < match.numberOfRanges,
              let captureRange = Range(match.range(at: group), in: text) else { return nil }
        return String(text[captureRange])
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return min(max(0, range.lowerBound), range.upperBound) }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func yamlNumber(_ value: Double) -> String {
        String(format: "%.9g", value)
    }

    private static func yamlQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func unique(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { seen.insert($0).inserted }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key] as? String { return value }
        }
        return nil
    }

    func double(_ keys: String...) -> Double? {
        for key in keys {
            if let value = self[key] as? NSNumber { return value.doubleValue }
            if let value = self[key] as? String, let number = Double(value) { return number }
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        for key in keys {
            if let value = self[key] as? NSNumber { return value.intValue }
            if let value = self[key] as? String, let number = Int(value) { return number }
        }
        return nil
    }

    func bool(_ keys: String...) -> Bool? {
        for key in keys {
            if let value = self[key] as? Bool { return value }
            if let value = self[key] as? NSNumber { return value.boolValue }
            if let value = self[key] as? String {
                switch value.lowercased() {
                case "true", "yes", "on", "1": return true
                case "false", "no", "off", "0": return false
                default: break
                }
            }
        }
        return nil
    }

    func arrayOfDictionaries(_ key: String) -> [[String: Any]] {
        self[key] as? [[String: Any]] ?? []
    }
}
