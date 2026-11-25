import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct ProductionHelpMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Notch Sixty Help") {
            openWindow(id: ProductionReferenceNavigator.windowID)
        }
        .keyboardShortcut("?", modifiers: .command)
    }
}

/// The Developer menu: bench and research workspaces kept out of the sidebar.
/// Shown only when the user has turned on "Show developer tools" in Settings.
struct ProductionDeveloperCommands: Commands {
    @ObservedObject var navigation: ProductionNavigation
    @AppStorage(PreferenceKeys.Application.showDeveloperTools)
    private var showDeveloperTools = false

    var body: some Commands {
        if DeveloperToolsPolicy.isShown(
            stored: showDeveloperTools,
            settingsPageEnabled: FeatureFlags.isEnabledProcessWide(.settingsPage),
            policy: FeatureFlags.buildPolicy,
            arguments: ProcessInfo.processInfo.arguments
        ) {
            CommandMenu("Developer") {
                ProductionDeveloperMenuItems(navigation: navigation)
            }
        }
    }
}

struct ProductionDeveloperMenuItems: View {
    @ObservedObject var navigation: ProductionNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(ProductionSection.developerTools) { section in
            Button(section.title) {
                openWindow(id: "main")
                navigation.selection = section
            }
        }
    }
}

final class NotchSixtyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension View {
    /// Notch Sixty uses switches, never checkboxes. Applied at each window's
    /// root; the style is inherited, so every Toggle below it, including
    /// those in Forms, renders as a switch without a per-call modifier.
    func productionToggleStyle() -> some View {
        toggleStyle(.switch)
    }

    /// Settings' rows are compact, so its switches are two sizes down.
    func productionCompactToggleStyle() -> some View {
        toggleStyle(CompactSwitchToggleStyle())
    }
}

struct CompactSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
}

@main
struct NotchSixtyApp: App {
    @NSApplicationDelegateAdaptor(NotchSixtyAppDelegate.self) private var appDelegate
    @StateObject private var product: ProductController
    @StateObject private var preferences: ApplicationPreferences
    @StateObject private var featureFlags: FeatureFlags
    @StateObject private var navigation = ProductionNavigation()

    /// Held until the process exits; see `ProductInstanceLock`.
    private static var instanceLock: ProductInstanceLock?

    init() {
        Self.claimSingleInstance()
        _product = StateObject(wrappedValue: ProductController())
        _preferences = StateObject(wrappedValue: ApplicationPreferences())
        _featureFlags = StateObject(wrappedValue: FeatureFlags())
    }

    /// A second process (another copy of the app with the same bundle
    /// identifier, or a relaunch while one is still alive) hands focus to
    /// the running instance and exits before it creates any audio or
    /// recovery state. XCTest hosts are exempt and use in-memory recovery.
    private static func claimSingleInstance() {
        guard !ProductProcessEnvironment.isHostingTests else { return }
        switch ProductInstanceLock.acquire() {
        case .acquired(let lock):
            instanceLock = lock
        case .heldByAnotherInstance:
            let ownPID = ProcessInfo.processInfo.processIdentifier
            if let bundleID = Bundle.main.bundleIdentifier {
                NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleID)
                    .first { $0.processIdentifier != ownPID }?
                    .activate()
            }
            exit(EXIT_SUCCESS)
        case .unavailable:
            // Without the lock, fall back to the recovery record alone
            // rather than refusing to launch.
            break
        }
    }

    private var trayInserted: Binding<Bool> {
        Binding(
            get: { preferences.isTrayInserted },
            set: { preferences.setTrayInserted($0) }
        )
    }

    var body: some Scene {
        Window("Notch Sixty", id: "main") {
            ProductionRootView(
                product: product, navigation: navigation, trayInserted: preferences.isTrayInserted)
                .environmentObject(featureFlags)
                .productionToggleStyle()
                .task {
                    product.prepareForUse()
                    preferences.apply(to: product.audioEngine)
                    if featureFlags.isEnabled(.settingsPage) {
                        product.settingsData.backUpAutomaticallyIfDue(preferences: preferences)
                    }
                    await product.resumeProcessingIfNeeded()
                }
        }
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            ProductionDeveloperCommands(navigation: navigation)
            ProductionMenuCommands(navigation: navigation, product: product)
        }

        MenuBarExtra(isInserted: trayInserted) {
            ProductionMenuBarView(product: product)
                .environmentObject(featureFlags)
                .productionToggleStyle()
                .task {
                    product.prepareForUse()
                    preferences.apply(to: product.audioEngine)
                }
        } label: {
            MenuBarVolumeLabel(engine: product.audioEngine, preferences: preferences)
        }
        .menuBarExtraStyle(.window)

        Settings {
            ProductionSettingsView(
                preferences: preferences,
                product: product,
                featureFlags: featureFlags
            )
            .productionCompactToggleStyle()
        }

        Window("Notch Sixty Help", id: ProductionReferenceNavigator.windowID) {
            ProductionHelpView(navigator: product.reference)
                .productionToggleStyle()
        }
        .defaultSize(width: 960, height: 720)
        .commands {
            CommandGroup(replacing: .help) {
                ProductionHelpMenuCommand()
            }
        }

        #if DEBUG
        Window("Engineering Validation", id: "engineering-validation") {
            EngineeringValidationView(engine: product.audioEngine)
                .productionToggleStyle()
                .task { product.prepareForUse() }
        }
        .defaultSize(width: 1000, height: 760)

        Window("Design Gallery", id: "design-gallery") {
            DesignGalleryView()
        }
        .defaultSize(width: 1000, height: 780)
        #endif
    }
}
