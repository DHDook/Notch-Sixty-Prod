import AppKit
import SwiftUI

/// E12 S23 (G33): the Settings tabs and where later settings go. Each later epic adds to the tab named here, so the
/// window never grows back into one long list.
///
/// - E15 "follow system output" goes on General.
/// - E16 hotkeys add a Shortcuts tab.
/// - E18 support bundle, crash reports and "What's new" go on About.
/// - The V2 "Audio input path" section gets its own tab (it sits on General until then).
enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, volume, privacy, data, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .volume: return "Volume"
        case .privacy: return "Privacy"
        case .data: return "Data"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .volume: return "speaker.wave.2"
        case .privacy: return "lock.shield"
        case .data: return "externaldrive.badge.timemachine"
        case .about: return "info.circle"
        }
    }

    /// The cards each tab holds, by title. Tests read this; the view builds the same cards.
    func cardTitles(offersDeveloperSwitch: Bool, offersInterfaceMode: Bool = false) -> [String] {
        switch self {
        case .general:
            var titles = (offersInterfaceMode ? ["Interface"] : []) + ["Appearance", "App Presence", "Startup", "Presets", "Page Displays"]
            if offersDeveloperSwitch { titles.append("Developer Tools") }
            return titles
        case .volume: return ["Volume & Feedback"]
        case .privacy: return ["Permissions"]
        case .data: return ["Backup & Restore", "Automatic Backups", "Reset & Erase"]
        case .about: return ["About", "Licences", "Privacy Statement", "Help & Support"]
        }
    }
}

/// E12 S23 (G40): the text and links on the About tab.
enum SettingsAboutContent {
    static let privacyStatement =
        "Notch Sixty processes your audio on this Mac. It does not send your audio, measurements, "
        + "settings or usage to anyone, and it has no network access. It asks for the microphone only when you "
        + "start a measurement, and for the camera only when you turn on head tracking. Backups are files "
        + "you save yourself."

    /// Opens the in-app Help window. The website address for support and the privacy policy is set by E18 (G98).
    static let supportURL: URL? = nil
    static let privacyPolicyURL: URL? = nil

    /// The licences text shipped in the app (`ThirdPartyNotices.txt`, from `THIRD_PARTY_NOTICES.md`).
    static func licenceText(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// The About tab: version, licences, privacy statement, help and support, diagnostics.
struct SettingsAboutView: View {
    let version: String
    let build: String
    let onCopyDiagnostics: () -> Void
    var licenceText: String? = SettingsAboutContent.licenceText()

    @Environment(\.openWindow) private var openWindow
    @State private var showsLicences = false

    var body: some View {
        card("About", "info.circle") {
            LabeledContent("Version") { Text(version).monospacedDigit() }
            LabeledContent("Build") { Text(build).monospacedDigit() }
        }
        card("Licences", "doc.text") {
            Text("Notch Sixty includes open-source software. Its licence and acknowledgements are listed here.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            DisclosureGroup("Show licences and acknowledgements", isExpanded: $showsLicences) {
                ScrollView {
                    Text(licenceText ?? "The licence text could not be found in this build.")
                        .font(DesignType.caption.font.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
            }
        }
        card("Privacy Statement", "hand.raised") {
            Text(SettingsAboutContent.privacyStatement)
                .fixedSize(horizontal: false, vertical: true)
            if let url = SettingsAboutContent.privacyPolicyURL {
                Link("Read the full privacy policy", destination: url)
            }
        }
        card("Help & Support", "questionmark.circle") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSpacing.m.pt) { buttons }
                VStack(alignment: .leading, spacing: DesignSpacing.m.pt) { buttons }
            }
            Text("Copy Diagnostics copies the app version, macOS version, audio device and sample rate, active preset and system, bypass state and processing delay. It does not include audio or measurement recordings.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            openWindow(id: ProductionReferenceNavigator.windowID)
        } label: {
            Label("Open Help", systemImage: "book")
        }
        .buttonStyle(.glass)
        if let url = SettingsAboutContent.supportURL {
            Link(destination: url) { Label("Get Support", systemImage: "lifepreserver") }
        }
        Button(action: onCopyDiagnostics) {
            Label("Copy Diagnostics", systemImage: "doc.on.doc")
        }
        .buttonStyle(.glass)
    }

    private func card<Content: View>(
        _ title: String, _ systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Label(title, systemImage: systemImage).font(DesignType.sectionTitle.font)
            content()
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }
}
