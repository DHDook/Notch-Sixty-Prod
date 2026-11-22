import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct ProductionSettingsView: View {
    @ObservedObject var preferences: ApplicationPreferences
    @ObservedObject var product: ProductController
    @ObservedObject var featureFlags: FeatureFlags
    @State private var backupMessage: String?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    @AppStorage(ProductionProfileToolbarPolicy.abComparisonEnabledKey)
    private var abComparisonEnabled = false

    @AppStorage(PreferenceKeys.Application.showDeveloperTools)
    private var showDeveloperTools = false

    private var diagnosticsReport: String {
        product.diagnosticsReport(
            version: version,
            build: build
        )
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport, forType: .string)
    }


    private func saveBackup() {
        let panel = NSSavePanel()
        panel.title = "Save Notch Sixty Backup"
        panel.prompt = "Save Backup"
        panel.nameFieldStringValue = "Notch-Sixty-Backup.n60backup"
        panel.allowedContentTypes = [UTType(filenameExtension: "n60backup") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try product.backup.exportData(
                preferences: preferences.makeBackupSnapshot(),
                appVersion: version,
                appBuild: build
            )
            try data.write(to: url, options: .atomic)
            let bundle = try product.backup.inspect(data)
            backupMessage =
                "Backup saved: \(bundle.profiles.contentPresets.count) presets · "
                + "\(bundle.profiles.systemProfiles.count) playback systems · "
                + "\(bundle.roomCorrectionProjects.count) room projects · "
                + "\(bundle.measurementLabSessions.count) lab sessions · "
                + "\(bundle.binauralAssets.count) binaural profiles."
        } catch {
            backupMessage =
                "Backup failed: \(error.localizedDescription)"
        }
    }

    private func restoreBackup() {
        guard product.audioEngine.lifecycleState == .idle else {
            backupMessage =
                "Stop audio processing before restoring a backup."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Restore Notch Sixty Backup"
        panel.prompt = "Review Backup"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "n60backup") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            let bundle = try product.backup.inspect(data)

            guard DesignDialogs.confirm(
                title: "Restore this Notch Sixty backup?",
                message: "This will replace saved Content Presets and Playback Systems "
                    + "and restore \(bundle.roomCorrectionProjects.count) Room Correction "
                    + "projects, \(bundle.measurementLabSessions.count) Measurement Lab "
                    + "sessions, and \(bundle.binauralAssets.count) binaural profiles. "
                    + "Hardware bindings that are not available on this Mac will be "
                    + "marked Needs Mapping and cannot activate until reviewed.",
                buttons: ["Restore", "Cancel"]) != nil else {
                return
            }

            product.abComparison.clearAll()
            let restored = try product.backup.restore(data)
            try preferences.restoreBackupSnapshot(
                restored.preferences
            )
            product.roomCorrectionProjects.prepareForUse()

            var message =
                "Restore complete: \(restored.report.contentPresetCount) presets · "
                + "\(restored.report.playbackSystemCount) playback systems · "
                + "\(restored.report.roomCorrectionProjectCount) room projects · "
                + "\(restored.report.measurementLabSessionCount) lab sessions · "
                + "\(restored.report.binauralAssetCount) binaural profiles"
            if restored.report.hardwareMappingRequiredCount > 0 {
                message +=
                    " · \(restored.report.hardwareMappingRequiredCount) systems need hardware mapping"
            }
            backupMessage = message + "."
        } catch {
            backupMessage =
                "Restore failed: \(error.localizedDescription)"
        }
    }

    var body: some View {
        generalSettings
            .task {
                preferences.apply(to: product.audioEngine)
                preferences.refreshLaunchAtLoginStatus()
            }
            .navigationTitle("Settings")
            .frame(
                minWidth: 520,
                idealWidth: 560,
                minHeight: 520,
                idealHeight: 720
            )
    }

    private var generalSettings: some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    settingsCard(title: "About", systemImage: "info.circle") {
                        LabeledContent("Version") {
                            Text(version).monospacedDigit()
                        }
                        LabeledContent("Build") {
                            Text(build).monospacedDigit()
                        }
                    }

                    settingsCard(title: "Appearance", systemImage: "circle.lefthalf.filled") {
                        HStack(spacing: 10) {
                            Text("Appearance")
                            Picker("", selection: $preferences.appearance) {
                                ForEach(ApplicationAppearanceMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }

                    settingsCard(title: "Volume & Feedback", systemImage: "speaker.wave.2") {
                        HStack(spacing: 10) {
                            Text("Step size")
                            Spacer()
                            Picker("Volume key step size", selection: $preferences.volumeStepResolution) {
                                Section("Fraction of range") {
                                    ForEach(ApplicationVolumeStepResolution.fractions) { resolution in
                                        Text(resolution.displayName).tag(resolution)
                                    }
                                }
                                Section("Decibels") {
                                    ForEach(ApplicationVolumeStepResolution.decibelSteps) { resolution in
                                        Text(resolution.displayName).tag(resolution)
                                    }
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }

                        Text("Controls Notch Sixty's software master-volume change for each intercepted volume-key press. Fractions move the slider by 1/16, 1/32 or 1/64 of its range. dB steps change the level by a fixed amount, down to −80 dB and then silence, and show the volume in dB (0 dB at full volume) in the menu bar and popup. The physical output-device volume is not stepped by this setting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Toggle("Show volume in menu bar", isOn: $preferences.showVolumeInMenuBar)
                            .disabled(preferences.presence == .dock)
                        Text("Show Notch Sixty's master-volume percentage beside the tray icon. Requires Menu Bar or Both in App Presence.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Show volume popup", isOn: $preferences.showVolumePopup)
                        HStack(spacing: 10) {
                            Text("Popup position")
                            Spacer()
                            Picker("Volume popup position", selection: $preferences.volumePopupPosition) {
                                ForEach(VolumeFeedbackPopupPosition.allCases) { position in
                                    Text(position.displayName).tag(position)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                        .disabled(!preferences.showVolumePopup)
                        Text("Briefly display Notch Sixty's volume when it changes. Follow macOS Popup appears beside the macOS volume indicator, at the top right or, while another app is full screen, the top centre. macOS gives sandboxed apps no public way to hide its indicator.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Cover the macOS volume popup", isOn: $preferences.coverSystemVolumePopup)
                            .disabled(
                                !preferences.showVolumePopup
                                    || preferences.volumePopupPosition != .topRight
                            )
                        Text("Follow macOS Popup only. Draws Notch Sixty's popup over the macOS one, with a solid glass style so it does not show through. The macOS popup still appears underneath and may flash briefly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(title: "App Presence", systemImage: "macwindow.on.rectangle") {
                        HStack(spacing: 10) {
                            Text("Show Notch Sixty in")
                            Picker("", selection: $preferences.presence) {
                                ForEach(ApplicationPresenceMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }

                        Text("Menu Bar mode keeps processing and preset controls available without a Dock icon. Both shows the app in both places.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(title: "Presets", systemImage: "music.note.list") {
                        Toggle("Show A/B comparison in the toolbar", isOn: $abComparisonEnabled)
                        Text("Adds the A/B controls beside the Content Preset menu for capturing and auditioning two content-DSP states. While an A/B audition is running the controls stay visible until you exit it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(title: "Startup", systemImage: "power") {
                        Toggle(
                            "Launch at Login",
                            isOn: Binding(
                                get: { preferences.launchAtLoginEnabled },
                                set: { preferences.setLaunchAtLogin($0) }
                            )
                        )

                        LabeledContent("Status") {
                            Text(preferences.launchAtLoginStatusDescription)
                                .foregroundStyle(.secondary)
                        }

                        if let error = preferences.launchAtLoginError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }

                        Text("Launch at Login is optional and does not automatically start audio processing. Processing remains an explicit user action in v1.0.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(title: "Permissions", systemImage: "lock.shield") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("System Audio")
                                .font(.subheadline.weight(.medium))
                            Text("Requested by macOS when processing needs system-audio capture.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Measurement Microphone")
                                .font(.subheadline.weight(.medium))
                            Text("Requested only when you start a microphone-based measurement or calibration workflow.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text("If processing starts but receives no system audio after permission was denied, allow Notch Sixty under Privacy & Security → Screen & System Audio Recording, then relaunch the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    settingsCard(
                        title: "Backup & Restore",
                        systemImage: "externaldrive.badge.timemachine"
                    ) {
                        HStack(spacing: 10) {
                            Button {
                                saveBackup()
                            } label: {
                                Label(
                                    "Save Backup…",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                            .buttonStyle(.glass)

                            Button {
                                restoreBackup()
                            } label: {
                                Label(
                                    "Restore Backup…",
                                    systemImage: "square.and.arrow.down"
                                )
                            }
                            .buttonStyle(.glass)
                            .disabled(
                                product.audioEngine.lifecycleState != .idle
                            )
                        }

                        Text(
                            "The .n60backup bundle includes saved presets and "
                            + "Playback Systems, Room Correction projects, "
                            + "Measurement Lab sessions, binaural profiles, "
                            + "and portable app preferences. Launch at Login, "
                            + "macOS permissions, and physical acceptance "
                            + "authority are never changed by restore."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(
                            "Restored hardware bindings are never silently "
                            + "reassigned. Systems that reference unavailable "
                            + "devices are marked Needs Mapping and remain "
                            + "blocked from activation until reviewed."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if let backupMessage {
                            Text(backupMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    settingsCard(title: "Developer Tools", systemImage: "wrench.adjustable") {
                        Toggle("Show developer tools", isOn: $showDeveloperTools)
                        Text("Adds a Developer menu with Hardware Acceptance and Acoustic Research, the bench and research workspaces used to qualify a system.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    #if DEBUG
                    developerSettings
                    #endif

                    settingsCard(title: "Support", systemImage: "wrench.and.screwdriver") {
                        Button {
                            copyDiagnostics()
                        } label: {
                            Label("Copy Diagnostics", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.glass)

                        Text("Copies app/build, macOS, audio device/rate, active preset/system, bypass state, and DSP latency. It does not include captured audio or room-measurement samples.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
        }
    }

    #if DEBUG
    /// Debug builds only: switch unfinished features on for local testing.
    private var developerSettings: some View {
        settingsCard(title: "Developer", systemImage: "hammer") {
            if featureFlags.known.isEmpty {
                Text("No features are in development behind a flag.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(featureFlags.known) { flag in
                    Toggle(
                        "\(flag.title) (\(flag.epic))",
                        isOn: Binding(
                            get: { featureFlags.isEnabled(flag) },
                            set: { featureFlags.setEnabled($0, for: flag) }
                        )
                    )
                    .disabled(featureFlags.isForcedByLaunchArgument(flag))
                }
                Button("Reset to Defaults") { featureFlags.resetOverrides() }
                    .buttonStyle(.glass)
            }
            Text("Unfinished epics merge behind these flags, off by default. Release builds ignore these switches; testers can enable flags with the launch argument \(FeatureFlags.launchArgument) id1,id2.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    #endif

    private func settingsCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

}
