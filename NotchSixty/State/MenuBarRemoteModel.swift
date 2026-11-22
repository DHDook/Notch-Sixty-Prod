import Foundation

// E12 S13 (behind `e12.dashboard-remote`): which surface hosts the remote-control panel, and which controls and named
// slots the panel carries. Pure values, so the surface rule (a control lives in exactly one place) is testable.

/// Where the remote panel is shown. With the flag off the legacy menu bar panel is used and the toolbar shows nothing.
enum RemoteHost: Equatable, Sendable {
    case legacyMenuBar
    case menuBar
    case toolbarPopover

    /// The single host for a given flag and menu bar setting.
    static func resolve(flagOn: Bool, trayInserted: Bool) -> RemoteHost {
        guard flagOn else { return .legacyMenuBar }
        return trayInserted ? .menuBar : .toolbarPopover
    }

    /// Every surface that shows the panel at once. Always exactly one element.
    static func visibleHosts(flagOn: Bool, trayInserted: Bool) -> [RemoteHost] {
        [resolve(flagOn: flagOn, trayInserted: trayInserted)]
    }
}

/// Everyday controls that live in the remote and nowhere else (surface rule, owner 16 Nov 2026).
enum RemoteControl: String, CaseIterable, Sendable {
    case processing, volume, mute, balance, output, preset, openApp
}

/// Named slots later slices fill, so they do not redesign the panel.
enum RemoteSlot: String, CaseIterable, Sendable {
    case quickControls
    case correctionStrength
    case seatPresets
    case ratePicker
    case beforeAfter

    var owner: String {
        switch self {
        case .quickControls, .ratePicker: return "E30"
        case .correctionStrength: return "E30"
        case .seatPresets: return "E10 S11"
        case .beforeAfter: return "E12 S27"
        }
    }

    /// Each owner slice sets its slot true when it wires its control. An empty slot draws nothing. The before/after
    /// button (E12 S27) is drawn when `e12.blind-listening` is on.
    var isFilled: Bool { self == .beforeAfter }
}

enum MenuBarRemoteModel {
    /// Controls the panel carries. The same list in the menu bar and in the toolbar popover: one component.
    static func controls(for host: RemoteHost) -> [RemoteControl] {
        switch host {
        case .legacyMenuBar: return [.processing, .preset, .openApp]
        case .menuBar, .toolbarPopover: return RemoteControl.allCases
        }
    }

    /// The toolbar button is shown only when the flag is on and the menu bar item is off.
    static func showsToolbarButton(flagOn: Bool, trayInserted: Bool) -> Bool {
        RemoteHost.resolve(flagOn: flagOn, trayInserted: trayInserted) == .toolbarPopover
    }

    /// Output changes only while stopped until E12 S14 adds the live switch.
    static func outputPickerEnabled(idle: Bool) -> Bool { idle }

    static func balanceReadout(_ balance: Double) -> String {
        let percent = Int((abs(balance) * 100).rounded())
        if percent == 0 { return "Centre" }
        return balance < 0 ? "L \(percent)" : "R \(percent)"
    }
}
