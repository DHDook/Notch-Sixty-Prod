import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum ApplicationAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum ApplicationPresenceMode: String, CaseIterable, Identifiable {
    case dock
    case tray
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dock: return "Dock"
        case .tray: return "Menu Bar"
        case .both: return "Both"
        }
    }
}

/// The volume-key step size. Raw values are persisted: positive ones are
/// slider fractions (1/16 …), negative ones are dB steps in tenths of a dB.
enum ApplicationVolumeStepResolution: Int, CaseIterable, Identifiable {
    case standard = 16
    case fine = 32
    case precision = 64
    case halfDecibel = -5
    case oneDecibel = -10
    case oneAndHalfDecibels = -15
    case threeDecibels = -30

    var id: Int { rawValue }

    static let fractions: [Self] = [.standard, .fine, .precision]
    /// ⅙, ⅓, ½ and 1 stop of power (1 stop = 3 dB), all on a 0.5 dB grid.
    static let decibelSteps: [Self] = [.halfDecibel, .oneDecibel, .oneAndHalfDecibels, .threeDecibels]

    /// Reads a stored raw value. The first dB build offered 2 and 4 dB
    /// (−20, −40); those map to the nearest current steps rather than
    /// falling back to 1/16.
    init?(storedValue: Int) {
        switch storedValue {
        case -20: self = .oneAndHalfDecibels
        case -40: self = .threeDecibels
        default: self.init(rawValue: storedValue)
        }
    }

    var usesDecibels: Bool { rawValue < 0 }

    /// Steps that land on .5 values keep one decimal in every readout, so
    /// the menu bar text never changes width.
    var readoutShowsTenths: Bool { usesDecibels && rawValue % 10 != 0 }

    var keyStep: MasterVolumeKeyStep {
        usesDecibels
            ? .decibels(Double(-rawValue) / 10)
            : .fraction(denominator: rawValue)
    }

    var displayName: String {
        switch self {
        case .standard: return "1/16"
        case .fine: return "1/32"
        case .precision: return "1/64"
        case .halfDecibel: return "0.5 dB"
        case .oneDecibel: return "1 dB"
        case .oneAndHalfDecibels: return "1.5 dB"
        case .threeDecibels: return "3 dB"
        }
    }
}

enum VolumeFeedbackPresentation {
    static func percentage(_ level: Double) -> Int {
        guard level.isFinite else { return 0 }
        return Int((min(max(level, 0.0), 1.0) * 100.0).rounded())
    }

    /// With `decibels`, the software taper's attenuation: "−12 dB" climbing
    /// to "0 dB" at full scale, and "−∞ dB" at silence.
    /// `alwaysTenths` keeps one decimal ("−27.0 dB") so a 0.5 dB step
    /// never changes the readout's width in the menu bar.
    static func readout(
        level: Double,
        muted: Bool,
        decibels: Bool = false,
        alwaysTenths: Bool = false
    ) -> String {
        if muted { return "Muted" }
        guard decibels else { return "\(percentage(level))%" }
        return decibelReadout(
            MasterVolumeConfiguration.softwareTaperDB(forLevel: level),
            alwaysTenths: alwaysTenths
        )
    }

    /// Marks on the fader in the percent step modes, where position is the
    /// level itself and the readout is a percentage.
    static let faderTickPercents: [Int] = [0, 25, 50, 75, 100]

    /// Marks on the dB-linear fader: evenly spaced, since position is dB.
    static let decibelFaderTickDecibels: [Double] = [0, -10, -20, -30, -40, -50, -60, -70]

    static func faderTickLabel(_ decibels: Double?) -> String {
        guard let decibels else { return "−∞" }
        return decibels == 0 ? "0" : "−\(Int(-decibels))"
    }

    /// The widest strings `readout` can return in one mode, with 8 standing
    /// in for any digit (digits are tabular, so all share one width).
    /// The menu bar reserves the widest of these so the readout never
    /// changes its width as the level moves. In percent mode the slot is
    /// exactly "100%" so that readout sits flush; the menu bar shows a
    /// speaker-slash symbol, not text, when muted.
    static func readoutWidthTemplates(decibels: Bool, alwaysTenths: Bool) -> [String] {
        guard decibels else { return ["100%"] }
        return [alwaysTenths ? "−88.8 dB" : "−88 dB", "−∞ dB"]
    }

    static func decibelReadout(_ decibels: Double?, alwaysTenths: Bool = false) -> String {
        guard let decibels else { return "−∞ dB" }
        let tenths = (decibels * 10).rounded()
        guard tenths < 0 else { return alwaysTenths ? "0.0 dB" : "0 dB" }
        let magnitude = -tenths / 10
        let number = magnitude.rounded() == magnitude && !alwaysTenths
            ? String(format: "%.0f", magnitude)
            : String(format: "%.1f", magnitude)
        return "−\(number) dB"
    }
}

enum VolumeFeedbackPopupPosition: String, CaseIterable, Identifiable {
    case bottomCenter
    case topRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bottomCenter: return "Bottom Center"
        case .topRight: return "Follow macOS Popup"
        }
    }
}

/// Where macOS draws its own volume popup. Measured on macOS 27 from the
/// on-screen window list (owner MenuBarAgent, level 101): a 352 × 149 pt
/// window flush under the menu bar, 87 pt in from the screen's right edge,
/// shown for about 1.44 s per key press. The window frame includes its
/// transparent shadow margin, so covering the whole frame covers the popup.
enum SystemVolumePopupGeometry {
    static let size = CGSize(width: 352, height: 149)
    static let trailingInset: CGFloat = 87
    static let windowLevel = NSWindow.Level.popUpMenu
    static let displayDuration: TimeInterval = 1.44

    static func frame(in visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.maxX - trailingInset - size.width,
            y: visibleFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// While another app is full screen, macOS moves its popup to the top
    /// centre of that screen. UNMEASURED: assumes the same window size, centred
    /// on the full screen frame and flush with its top edge. Replace with the
    /// bench measurement (docs/epics/E5.md, "Bench checks").
    static func fullScreenFrame(in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}

/// Whether the frontmost app is full screen on a given display, from the
/// public on-screen window list (owner, layer and bounds need no Screen
/// Recording permission). Checked once per popup, never polled.
enum FullScreenAppDetector {
    /// `windows` is `CGWindowListCopyWindowInfo` output, whose bounds are in
    /// global top-left coordinates; `primaryScreenHeight` converts them to
    /// AppKit's bottom-left space. Full screen means a normal-layer window of
    /// `ownerPID` covering `screenFrame` exactly, menu bar area included.
    static func isFullScreen(
        windows: [[String: Any]],
        ownerPID: pid_t,
        screenFrame: CGRect,
        primaryScreenHeight: CGFloat
    ) -> Bool {
        let tolerance: CGFloat = 1
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return false }
            let appKitBounds = CGRect(
                x: bounds.minX,
                y: primaryScreenHeight - bounds.maxY,
                width: bounds.width,
                height: bounds.height
            )
            return abs(appKitBounds.minX - screenFrame.minX) <= tolerance
                && abs(appKitBounds.minY - screenFrame.minY) <= tolerance
                && abs(appKitBounds.width - screenFrame.width) <= tolerance
                && abs(appKitBounds.height - screenFrame.height) <= tolerance
        }
    }

    @MainActor
    static func frontmostAppIsFullScreen(on screen: NSScreen) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]]
        else { return false }
        return isFullScreen(
            windows: windows,
            ownerPID: pid,
            screenFrame: screen.frame,
            primaryScreenHeight: primary.frame.height
        )
    }
}

enum VolumeFeedbackPopupStyle: Equatable {
    /// Translucent Liquid Glass.
    case glass
    /// Opaque base under a glass rim, so a covered system popup cannot show through.
    case solidGlass
}

/// Frame, style, window level and display time of Notch Sixty's popup.
struct VolumeFeedbackPopupLayout: Equatable {
    static let standardSize = CGSize(width: 264, height: 88)
    /// Cover mode spans the system popup's full width but not its full
    /// height: that frame includes a transparent shadow margin, and our
    /// one-row content looked empty in it. The panel sits just under the menu
    /// bar, where the visible system popup starts.
    static let coverHeight: CGFloat = 104
    static let coverTopInset: CGFloat = 6
    static let gapBesideSystemPopup: CGFloat = 8

    let frame: CGRect
    let style: VolumeFeedbackPopupStyle
    let level: NSWindow.Level
    let displayDuration: TimeInterval

    /// Covering applies only with Follow macOS Popup. `fullScreenFrame` is the
    /// screen's full frame when another app is full screen there; the popup
    /// then follows the system one to the top centre.
    static func make(
        position: VolumeFeedbackPopupPosition,
        coverSystemPopup: Bool,
        visibleFrame: CGRect,
        fullScreenFrame: CGRect? = nil
    ) -> VolumeFeedbackPopupLayout {
        let size = standardSize
        switch position {
        case .bottomCenter:
            return VolumeFeedbackPopupLayout(
                frame: CGRect(
                    x: visibleFrame.midX - size.width / 2,
                    y: visibleFrame.minY + 84,
                    width: size.width,
                    height: size.height
                ),
                style: .glass,
                level: .floating,
                displayDuration: 1.4
            )
        case .topRight:
            let system = fullScreenFrame.map(SystemVolumePopupGeometry.fullScreenFrame(in:))
                ?? SystemVolumePopupGeometry.frame(in: visibleFrame)
            if coverSystemPopup {
                // One level above the system popup, and up longer than it, so
                // it never peeks out before or after ours.
                return VolumeFeedbackPopupLayout(
                    frame: CGRect(
                        x: system.minX,
                        y: system.maxY - coverTopInset - coverHeight,
                        width: system.width,
                        height: coverHeight
                    ),
                    style: .solidGlass,
                    level: NSWindow.Level(
                        rawValue: SystemVolumePopupGeometry.windowLevel.rawValue + 1
                    ),
                    displayDuration: SystemVolumePopupGeometry.displayDuration + 0.4
                )
            }
            // Beside the system popup: to its left, centred on it vertically.
            return VolumeFeedbackPopupLayout(
                frame: CGRect(
                    x: system.minX - gapBesideSystemPopup - size.width,
                    y: system.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                style: .glass,
                level: .floating,
                displayDuration: 1.4
            )
        }
    }
}

// Presentation only: no audio callback, key interception, driver, or system
// HUD manipulation. Cover mode draws a window above the system popup; it
// never hides, moves or alters it.
@MainActor
final class VolumeFeedbackHUDController {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(
        _ configuration: MasterVolumeConfiguration,
        position: VolumeFeedbackPopupPosition,
        coverSystemPopup: Bool,
        decibels: Bool,
        alwaysTenths: Bool
    ) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let followsFullScreen = position == .topRight
            && FullScreenAppDetector.frontmostAppIsFullScreen(on: screen)
        let layout = VolumeFeedbackPopupLayout.make(
            position: position,
            coverSystemPopup: coverSystemPopup,
            visibleFrame: screen.visibleFrame,
            fullScreenFrame: followsFullScreen ? screen.frame : nil
        )
        let window: NSPanel
        if let panel {
            window = panel
        } else {
            window = NSPanel(
                contentRect: layout.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            panel = window
        }

        window.level = layout.level
        window.contentView = NSHostingView(
            rootView: VolumeFeedbackHUDView(
                configuration: configuration,
                style: layout.style,
                decibels: decibels,
                alwaysTenths: alwaysTenths
            )
            .frame(width: layout.frame.width, height: layout.frame.height)
        )
        window.setFrame(layout.frame, display: true)
        window.orderFrontRegardless()
        dismissal?.cancel()
        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(layout.displayDuration))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
    }
}

struct VolumeFeedbackHUDView: View {
    let configuration: MasterVolumeConfiguration
    let style: VolumeFeedbackPopupStyle
    let decibels: Bool
    let alwaysTenths: Bool

    private var readout: String {
        VolumeFeedbackPresentation.readout(
            level: configuration.level,
            muted: configuration.muted,
            decibels: decibels,
            alwaysTenths: alwaysTenths
        )
    }

    /// The slider position, which on the loudness taper is also the
    /// relative loudness, in both readout modes.
    private var barPosition: Double {
        if configuration.muted { return 0 }
        return min(max(configuration.level, 0), 1)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: style == .solidGlass ? 28 : 22)
    }

    var body: some View {
        content
            .padding(.horizontal, style == .solidGlass ? 28 : 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular, in: shape)
            .background {
                // Glass over an opaque base: the rim and highlight stay, but
                // nothing behind the window (the system popup) shows through.
                if style == .solidGlass {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Notch Sixty volume " + readout
            )
    }

    private var content: some View {
        HStack(spacing: style == .solidGlass ? 18 : 14) {
            Image(
                systemName: configuration.muted
                    ? "speaker.slash.fill" : "speaker.wave.2.fill"
            )
            .font(style == .solidGlass ? .largeTitle : .title2)
            .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("NOTCH SIXTY")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(readout)
                    .font(style == .solidGlass ? .title3.weight(.semibold) : .headline)
                    .monospacedDigit()
                }
                ProgressView(value: barPosition)
                .tint(.orange)
            }
        }
    }
}

struct MenuBarVolumeLabel: View {
    var engine: AudioIOEngine
    @ObservedObject var preferences: ApplicationPreferences

    private var readout: String {
        VolumeFeedbackPresentation.readout(
            level: engine.masterVolumeConfiguration.level,
            muted: engine.masterVolumeConfiguration.muted,
            decibels: preferences.showsDecibelReadout(for: engine),
            alwaysTenths: preferences.decibelReadoutShowsTenths
        )
    }

    @Environment(\.displayScale) private var displayScale

    private var widthTemplates: [String] {
        VolumeFeedbackPresentation.readoutWidthTemplates(
            decibels: preferences.showsDecibelReadout(for: engine),
            alwaysTenths: preferences.decibelReadoutShowsTenths
        )
    }

    /// The status item ignores most layout modifiers, so the label is drawn
    /// to a template image. The readout sits in a slot as wide as the widest
    /// string the current mode can show, so the item's width, and every
    /// menu-bar item beside it, stays put as the digits change.
    private var labelImage: NSImage? {
        let label = HStack(spacing: 5) {
            Image("TrayIcon")
                .renderingMode(.template)
            if preferences.showVolumeInMenuBar {
                ZStack(alignment: .leading) {
                    ForEach(widthTemplates, id: \.self) { Text($0).hidden() }
                }
                .overlay(alignment: .leading) {
                    if engine.masterVolumeConfiguration.muted {
                        Image(systemName: "speaker.slash.fill")
                    } else {
                        Text(readout)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            }
        }
        .foregroundStyle(.black)
        let renderer = ImageRenderer(content: label)
        renderer.scale = displayScale
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }

    var body: some View {
        Group {
            if let labelImage {
                Image(nsImage: labelImage)
            } else {
                Image("TrayIcon").renderingMode(.template)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Notch Sixty" + (
                preferences.showVolumeInMenuBar
                ? ", volume " + readout : ""
            )
        )
    }
}

@MainActor
final class ApplicationPreferences: ObservableObject {
    private typealias Key = PreferenceKeys.Application

    private let defaults: UserDefaults
    private weak var audioEngine: AudioIOEngine?

    @Published var appearance: ApplicationAppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    @Published var presence: ApplicationPresenceMode {
        didSet {
            defaults.set(presence.rawValue, forKey: Key.presence)
            applyActivationPolicy()
        }
    }

    @Published var volumeStepResolution: ApplicationVolumeStepResolution {
        didSet {
            defaults.set(volumeStepResolution.rawValue, forKey: Key.volumeStepResolution)
            audioEngine?.setSoftwareVolumeKeyStep(volumeStepResolution.keyStep)
        }
    }

    @Published var showVolumeInMenuBar: Bool {
        didSet { defaults.set(showVolumeInMenuBar, forKey: Key.showVolumeInMenuBar) }
    }

    @Published var showVolumePopup: Bool {
        didSet {
            defaults.set(showVolumePopup, forKey: Key.showVolumePopup)
            if !showVolumePopup { volumeHUD.dismiss() }
        }
    }

    @Published var volumePopupPosition: VolumeFeedbackPopupPosition {
        didSet { defaults.set(volumePopupPosition.rawValue, forKey: Key.volumePopupPosition) }
    }

    /// The stored choice; it only takes effect with Follow macOS Popup.
    @Published var coverSystemVolumePopup: Bool {
        didSet { defaults.set(coverSystemVolumePopup, forKey: Key.coverSystemVolumePopup) }
    }

    var coversSystemVolumePopup: Bool {
        coverSystemVolumePopup && volumePopupPosition == .topRight
    }

    private let volumeHUD = VolumeFeedbackHUDController()
    private var volumeFeedbackObservation: ObservationSubscription?

    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginError: String?
    private var appearanceObservation: NSKeyValueObservation?
    private var didApplyInitialPreferences = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = ApplicationAppearanceMode(
            rawValue: defaults.string(forKey: Key.appearance) ?? ""
        ) ?? .system
        presence = ApplicationPresenceMode(
            rawValue: defaults.string(forKey: Key.presence) ?? ""
        ) ?? .both
        volumeStepResolution = ApplicationVolumeStepResolution(
            storedValue: defaults.integer(forKey: Key.volumeStepResolution)
        ) ?? .standard
        showVolumeInMenuBar = defaults.object(forKey: Key.showVolumeInMenuBar) as? Bool ?? true
        showVolumePopup = defaults.bool(forKey: Key.showVolumePopup)
        volumePopupPosition = VolumeFeedbackPopupPosition(
            rawValue: defaults.string(forKey: Key.volumePopupPosition) ?? ""
        ) ?? .bottomCenter
        coverSystemVolumePopup = defaults.bool(forKey: Key.coverSystemVolumePopup)
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        launchAtLoginError = nil
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyApplicationIcon()
            }
        }
    }

    var isTrayInserted: Bool { presence != .dock }

    var launchAtLoginStatusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Requires approval in System Settings"
        case .notRegistered:
            return "Off"
        case .notFound:
            return "Unavailable"
        @unknown default:
            return "Unknown"
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLoginStatus()
    }

    func setTrayInserted(_ inserted: Bool) {
        if inserted {
            if presence == .dock { presence = .both }
        } else if presence != .dock {
            // Never strand a tray-only app with no visible app surface.
            presence = .dock
        }
    }

    /// dB readouts follow a dB step size, but only on the software volume,
    /// whose taper defines the dB value; device-mode volume stays in percent.
    func showsDecibelReadout(for engine: AudioIOEngine) -> Bool {
        volumeStepResolution.usesDecibels
            && engine.masterVolumeCapabilities.controlMode == .softwareDSP
    }

    var decibelReadoutShowsTenths: Bool { volumeStepResolution.readoutShowsTenths }

    func apply(to audioEngine: AudioIOEngine) {
        self.audioEngine = audioEngine
        audioEngine.setSoftwareVolumeKeyStep(volumeStepResolution.keyStep)
        guard !didApplyInitialPreferences else { return }
        didApplyInitialPreferences = true
        volumeFeedbackObservation = ObservationSubscription(
            value: { audioEngine.masterVolumeConfiguration },
            onChange: { [weak self] configuration in
                guard let self, self.showVolumePopup else { return }
                self.volumeHUD.show(
                    configuration,
                    position: self.volumePopupPosition,
                    coverSystemPopup: self.coversSystemVolumePopup,
                    decibels: self.showsDecibelReadout(for: audioEngine),
                    alwaysTenths: self.decibelReadoutShowsTenths
                )
            }
        )
        applyAppearance()
        applyActivationPolicy()
    }


    func makeBackupSnapshot() -> NotchSixtyBackupPreferences {
        NotchSixtyBackupPreferences(
            appearance: appearance.rawValue,
            presence: presence.rawValue,
            volumeStepResolution: volumeStepResolution.rawValue,
            showVolumeInMenuBar: showVolumeInMenuBar,
            showVolumePopup: showVolumePopup,
            volumePopupPosition: volumePopupPosition.rawValue,
            coverSystemVolumePopup: coverSystemVolumePopup
        )
    }

    /// Restores only portable app-owned preferences. macOS permission grants
    /// and Launch at Login are intentionally excluded from the backup format.
    func restoreBackupSnapshot(
        _ snapshot: NotchSixtyBackupPreferences
    ) throws {
        try snapshot.validate()
        guard let appearance =
                ApplicationAppearanceMode(rawValue: snapshot.appearance),
              let presence =
                ApplicationPresenceMode(rawValue: snapshot.presence),
              let resolution =
                ApplicationVolumeStepResolution(
                    storedValue: snapshot.volumeStepResolution
                ) else {
            throw NotchSixtyBackupError.invalidPreferences
        }

        self.appearance = appearance
        self.presence = presence
        self.volumeStepResolution = resolution
        if let show = snapshot.showVolumeInMenuBar { showVolumeInMenuBar = show }
        if let show = snapshot.showVolumePopup { showVolumePopup = show }
        if let position = snapshot.volumePopupPosition.flatMap(
            VolumeFeedbackPopupPosition.init(rawValue:)
        ) {
            volumePopupPosition = position
        }
        if let cover = snapshot.coverSystemVolumePopup { coverSystemVolumePopup = cover }
    }

    private func applyAppearance() {
        switch appearance {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        applyApplicationIcon()
    }

    private func applyApplicationIcon() {
        let useDarkIcon: Bool
        switch appearance {
        case .light:
            useDarkIcon = false
        case .dark:
            useDarkIcon = true
        case .system:
            useDarkIcon = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        let assetName = NSImage.Name(useDarkIcon ? "DockIconDark" : "DockIconLight")
        if let icon = NSImage(named: assetName) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = presence == .tray ? .accessory : .regular
        _ = NSApplication.shared.setActivationPolicy(policy)
    }
}
