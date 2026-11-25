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
    @State private var selectedTab: SettingsTab = .general
    @State private var displayResetMessage: String?
    @StateObject private var permissionStatus = PermissionStatusModel()
    @AppStorage(PreferenceKeys.Application.resumeProcessingOnOpen)
    private var resumeProcessingOnOpen = false

    init(
        preferences: ApplicationPreferences, product: ProductController, featureFlags: FeatureFlags,
        initialTab: SettingsTab = .general
    ) {
        self.preferences = preferences
        self.product = product
        self.featureFlags = featureFlags
        _selectedTab = State(initialValue: initialTab)
    }

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
        Group {
            if featureFlags.isEnabled(.settingsPage) {
                tabbedSettings
            } else {
                generalSettings
            }
        }
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

    /// The single scrolling list used while `e12.settings-page` is off (today's layout).
    private var generalSettings: some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    aboutCard
                    appearanceCard
                    volumeCard
                    presenceCard
                    presetsCard
                    schedulesCard
                    startupCard
                    permissionsCard
                    backupCard
                    developerToolsCard

                    #if DEBUG
                    developerSettings
                    #endif

                    if featureFlags.isEnabled(.virtualDriver) {
                        AudioInputPathSettingsSection(model: product.audioInputPath)
                    }

                    supportCard
                }
            }
            .padding(18)
        }
    }

    /// E12 S23: five tabs. Each tab is a scrolling page of cards.
    private var tabbedSettings: some View {
        TabView(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                tabPage(tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
    }

    private func tabPage(_ tab: SettingsTab) -> some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                tabCards(tab)
            }
            .padding(18)
        }
    }

    /// The cards of one tab. Internal so the layout test can host a tab at a given width (E12 S25, G99).
    @ViewBuilder
    func tabCards(_ tab: SettingsTab) -> some View {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .general:
                        appearanceCard
                        presenceCard
                        startupCard
                        presetsCard
                        schedulesCard
                        displaysCard
                        if featureFlags.isEnabled(.virtualDriver) {
                            AudioInputPathSettingsSection(model: product.audioInputPath)
                        }
                        if DeveloperToolsPolicy.offersSwitch(policy: FeatureFlags.buildPolicy) {
                            developerToolsCard
                        }
                        #if DEBUG
                        developerSettings
                        #endif
                    case .volume:
                        volumeCard
                    case .privacy:
                        permissionsCard
                    case .data:
                        backupCard
                        SettingsAutomaticBackupCard(manager: product.settingsData, preferences: preferences)
                        SettingsResetEraseCard(
                            manager: product.settingsData, preferences: preferences,
                            isIdle: product.audioEngine.lifecycleState == .idle)
                    case .about:
                        SettingsAboutView(
                            version: version,
                            build: build,
                            onCopyDiagnostics: copyDiagnostics
                        )
                    }
                }
    }

    private var displaysCard: some View {
        settingsCard(title: "Page Displays", systemImage: "gauge.with.dots.needle.bottom.50percent") {
            Button {
                resetPageDisplays()
            } label: {
                Label("Reset Page Displays", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.glass)

            Text("Puts the meter scale, the Equalizer graph range and analyser, and the Dynamics curve panels back to how they first looked. Your presets and sound settings are not changed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let displayResetMessage {
                Text(displayResetMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetPageDisplays() {
        product.profiles.eqProgramAnalyser.setOn(false)
        product.profiles.eqProgramAnalyser.setMode(.default)
        PageDisplayPreferences.reset()
        displayResetMessage = "Page displays were reset."
    }

    private var aboutCard: some View {
        settingsCard(title: "About", systemImage: "info.circle") {
            LabeledContent("Version") {
                Text(version).monospacedDigit()
            }
            LabeledContent("Build") {
                Text(build).monospacedDigit()
            }
        }
    }

    private var appearanceCard: some View {
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
    }

    private var volumeCard: some View {
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

            Text("How far Notch Sixty's volume moves each time you press a volume key. A fraction moves the slider by that part of its range. A dB step changes the level by a fixed amount, down to −80 dB and then silence, and shows the volume in dB (0 dB is full volume). This changes Notch Sixty's volume, not your speakers' own volume.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Show volume in menu bar", isOn: $preferences.showVolumeInMenuBar)
                .disabled(preferences.presence == .dock)
            Text("Shows the volume beside the menu bar icon. Needs “Menu Bar” or “Both” under Show Notch Sixty in.")
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
            Text("Briefly shows the volume when it changes. “Follow macOS Popup” puts it beside the macOS volume indicator, at the top right or, while another app is full screen, at the top centre. macOS does not let apps hide its own indicator.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Cover the macOS volume popup", isOn: $preferences.coverSystemVolumePopup)
                .disabled(
                    !preferences.showVolumePopup
                        || preferences.volumePopupPosition != .topRight
                )
            Text("Only with “Follow macOS Popup”. Draws Notch Sixty's popup over the macOS one so it does not show through. The macOS popup still appears underneath and may flash briefly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var presenceCard: some View {
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

            Text("“Menu Bar” keeps the controls available without a Dock icon. “Both” shows the app in the Dock and the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var presetsCard: some View {
        settingsCard(title: "Presets", systemImage: "music.note.list") {
            Toggle("Show A/B comparison in the toolbar", isOn: $abComparisonEnabled)
            Text("Adds A/B buttons beside the preset menu so you can store two sounds and switch between them. While a comparison is running the buttons stay visible until you finish it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// E15 S7: only while `e15.follow-output` is on, and only when the scheduler was built.
    @ViewBuilder
    private var schedulesCard: some View {
        if featureFlags.isEnabled(.followOutput), let scheduler = product.scheduler {
            ProfileScheduleCard(scheduler: scheduler, profiles: product.profiles)
        }
    }

    private var startupCard: some View {
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

            if featureFlags.isEnabled(.settingsPage) {
                Divider()
                Toggle("Resume processing when Notch Sixty opens", isOn: $resumeProcessingOnOpen)
                Text("If processing was running when you last quit Notch Sixty, start it again when the app opens, with the normal fade-in. It starts only if the same output device is connected, and not after a crash or force-quit. It never turns on Quiet Zone or room treatment; you arm those yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Opening Notch Sixty at login does not start audio. You press Start yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionsCard: some View {
        if featureFlags.isEnabled(.settingsPage) { return AnyView(permissionStatusCard) }
        return AnyView(legacyPermissionsCard)
    }

    /// E12 S24 (G35): each permission with its status and a button to the right System Settings pane.
    private var permissionStatusCard: some View {
        settingsCard(title: "Permissions", systemImage: "lock.shield") {
            ForEach(PermissionKind.allCases) { kind in
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        permissionText(kind)
                        Spacer(minLength: 8)
                        permissionControls(kind)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        permissionText(kind)
                        HStack(spacing: 10) { permissionControls(kind) }
                    }
                }
            }
            Text("If processing starts but you hear nothing after saying no to the System Audio permission, allow Notch Sixty in System Settings under Privacy & Security, then reopen the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionStatus.refresh()
        }
        .onAppear {
            product.resume.noteProcessingRan(target: product)
            permissionStatus.refresh()
        }
    }

    private func permissionText(_ kind: PermissionKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.title).font(.subheadline.weight(.medium))
            Text(kind.explanation).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func permissionControls(_ kind: PermissionKind) -> some View {
        Text(permissionStatus.state(kind).label)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("settings.permission.\(kind.rawValue).status")
        Button("Open System Settings") { permissionStatus.openSystemSettings(for: kind) }
            .buttonStyle(.glass)
    }

    private var legacyPermissionsCard: some View {
        settingsCard(title: "Permissions", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: 4) {
                Text("System Audio")
                    .font(.subheadline.weight(.medium))
                Text("macOS asks for this when Notch Sixty first needs to hear your Mac's audio.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text("Measurement Microphone")
                    .font(.subheadline.weight(.medium))
                Text("macOS asks for this only when you start a measurement that uses a microphone.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if featureFlags.isEnabled(.followOutput), let notifications = product.outputFollow.notifications {
                OutputFollowNotificationsRow(follow: product.outputFollow, notifications: notifications)
            }

            Text("If processing starts but you hear nothing after saying no to this permission, allow Notch Sixty in System Settings under Privacy & Security → Screen & System Audio Recording, then reopen the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var backupCard: some View {
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
                "A backup file holds your presets, speaker systems, "
                + "room correction projects, measurement sessions, "
                + "headphone profiles and app settings. Restoring never "
                + "changes Launch at Login or your macOS permissions."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(
                "A restored system never moves to a different device on its own. "
                + "If its device is not connected, it is marked Needs Mapping "
                + "and stays off until you choose a device."
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
    }

    private var developerToolsCard: some View {
        settingsCard(title: "Developer Tools", systemImage: "wrench.adjustable") {
            Toggle("Show developer tools", isOn: $showDeveloperTools)
            Text("Adds a Developer menu with Hardware Acceptance and Acoustic Research, the bench and research workspaces used to qualify a system.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var supportCard: some View {
        settingsCard(title: "Support", systemImage: "wrench.and.screwdriver") {
            Button {
                copyDiagnostics()
            } label: {
                Label("Copy Diagnostics", systemImage: "doc.on.doc")
            }
            .buttonStyle(.glass)

            Text("Copies the app version, macOS version, audio device and sample rate, active preset and system, bypass state and processing delay. It does not include audio or measurement recordings.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
