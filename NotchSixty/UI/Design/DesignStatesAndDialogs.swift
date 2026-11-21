import AppKit
import SwiftUI

// E34 S4: one way to be empty, busy, stopped or wrong, and one rule for dialogs.
// Swift UI only; nothing here touches the engine.

/// Pages that need live audio to show anything. Each shows the same stopped state while audio is stopped.
enum DesignLivePage: CaseIterable, Sendable {
    case metersLevels, metersDynamics, metersSpectrum, metersStereo, dynamicsTelemetry

    /// What the stopped state says on this page. One sentence, one Start button.
    var stoppedMessage: String {
        switch self {
        case .metersLevels, .metersDynamics: return "Audio is stopped. Start processing to see live meters."
        case .metersSpectrum: return "Audio is stopped. Start processing to see the spectrum."
        case .metersStereo: return "Audio is stopped. Start processing to see the stereo field."
        case .dynamicsTelemetry: return "Audio is stopped. Start processing to view live status."
        }
    }
}

enum DesignPageStateRule {
    /// Stopped wins over empty: nothing can arrive while audio is stopped.
    static func state(isRunning: Bool, hasContent: Bool, isBusy: Bool = false) -> DesignStateKind? {
        if !isRunning { return .stopped }
        if isBusy { return .busy }
        return hasContent ? nil : .empty
    }
}

/// The compact stopped state shown at the top of a page that needs live audio.
struct DesignStoppedBanner: View {
    let message: String
    var onStart: (() -> Void)?
    var identifier = "state.stopped"

    var body: some View {
        HStack(spacing: DesignSpacing.m.pt) {
            Image(systemName: DesignStateKind.stopped.iconName)
                .font(.title2)
                .foregroundStyle(DesignStateKind.stopped.level.color)
                .accessibilityHidden(true)
            Text(message).foregroundStyle(.secondary)
            Spacer()
            if let onStart {
                Button("Start", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("\(identifier).start")
            }
        }
        .padding(DesignSpacing.m.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .designSurface(.medium)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Dialog rule

enum DesignDialogSituation: CaseIterable, Sendable {
    /// Replaces or deletes the user's work.
    case destructiveAction
    /// Something the user can fix on the page (a bad file, a refused value, a failed start).
    case recoverableError
    /// A result or note the user may want to read (import notes, export done).
    case notice
    /// The app cannot continue (safe launch, unrecoverable engine failure).
    case cannotContinue
}

enum DesignDialogKind: Equatable, Sendable {
    case confirmationDialog, inlineMessage, alert
}

enum DesignDialogRule {
    static func kind(for situation: DesignDialogSituation) -> DesignDialogKind {
        switch situation {
        case .destructiveAction: return .confirmationDialog
        case .recoverableError, .notice: return .inlineMessage
        case .cannotContinue: return .alert
        }
    }
}

/// The one place a blocking AppKit dialog is built, for commands that run outside a view (open and save panels).
/// Used for destructive confirmations and the replace-or-add choice; never for errors.
@MainActor
enum DesignDialogs {
    /// Runs the confirmation. `buttons` are in alert order, the last being Cancel; returns the chosen index,
    /// or nil for Cancel.
    static func confirm(title: String, message: String, buttons: [String], warning: Bool = true) -> Int? {
        let alert = NSAlert()
        alert.alertStyle = warning ? .warning : .informational
        alert.messageText = title
        alert.informativeText = message
        for button in buttons { alert.addButton(withTitle: button) }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 0, index < buttons.count - 1 else { return nil }
        return index
    }
}

/// An error or note shown inline at the top of the page, with Dismiss. Colour is never the only signal.
struct DesignInlineMessage: View {
    var level: StatusLevel = .problem
    let title: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
            Image(systemName: level.iconName)
                .foregroundStyle(level.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button("Dismiss", action: onDismiss)
                .accessibilityIdentifier("inline.message.dismiss")
        }
        .padding(DesignSpacing.m.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .designTint(level.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inline.message")
    }
}

extension View {
    /// Shows `message` as the rule says: inline at the top with the design language on, the old alert with it off.
    /// Set the binding to nil to dismiss.
    func designMessage(
        _ title: String,
        level: StatusLevel = .problem,
        message: Binding<String?>
    ) -> some View {
        modifier(DesignMessageModifier(title: title, level: level, message: message))
    }
}

private struct DesignMessageModifier: ViewModifier {
    let title: String
    let level: StatusLevel
    @Binding var message: String?

    func body(content: Content) -> some View {
        if FeatureFlags.isEnabledProcessWide(.designLanguage) {
            content.safeAreaInset(edge: .top, spacing: 0) {
                if let text = message {
                    DesignInlineMessage(level: level, title: title, message: text) { message = nil }
                        .padding(DesignSpacing.s.pt)
                }
            }
        } else {
            content.alert(
                title,
                isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
            ) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }
}
