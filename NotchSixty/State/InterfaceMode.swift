import Foundation
import SwiftUI

extension FeatureFlag {
    /// E12 S8: simple and expert modes. Simple shows the Dashboard, guided setup (System) and Headphones; expert
    /// shows every page and the expert controls. Swift only; the engine never reads it. Off: every page and control
    /// shows, as today (the mode is always expert). Not graduated yet (see the E12 ledger).
    static let simpleExpertModes = FeatureFlag(
        id: "e12.simple-expert-modes",
        title: "Simple and expert modes",
        epic: "E12"
    )
}

/// E12 S8: how much of the app shows. Stored as a preference; the flag decides whether the choice has any effect.
enum InterfaceMode: String, CaseIterable, Identifiable, Sendable {
    case simple, expert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple: return "Simple"
        case .expert: return "Expert"
        }
    }

    var detail: String {
        switch self {
        case .simple: return "The Dashboard, guided setup and headphones. Everything else is hidden."
        case .expert: return "Every page and every control, including the equalizer, dynamics, meters and the measurement tools."
        }
    }

    /// The mode in force. With the flag off it is always expert, so today's app is unchanged. A stored value that is
    /// missing or unknown means simple once the flag is on.
    nonisolated static func effective(stored: String?, flagEnabled: Bool) -> InterfaceMode {
        guard flagEnabled else { return .expert }
        return stored.flatMap(InterfaceMode.init(rawValue:)) ?? .simple
    }

    var isExpert: Bool { self == .expert }

    /// Pages the sidebar lists in simple mode (the Dashboard is its own row). Expert mode lists them all.
    static let simpleSections: Set<ProductionSection> = [.dashboard, .system, .headphones]

    func shows(_ section: ProductionSection) -> Bool {
        self == .expert || Self.simpleSections.contains(section)
    }

    /// Where to go when the current page is hidden by a switch to simple mode.
    func landing(for section: ProductionSection?) -> ProductionSection? {
        guard let section else { return nil }
        return shows(section) ? section : .dashboard
    }

    /// Sidebar groups with the pages this mode hides removed; groups left empty are dropped.
    func filtered(_ groups: [ProductionSidebarGroup]) -> [ProductionSidebarGroup] {
        groups.compactMap { group in
            let kept = group.sections.filter(shows)
            return kept.isEmpty ? nil : ProductionSidebarGroup(title: group.title, sections: kept)
        }
    }

    /// The setup graphs' detail follows the mode: one curve per line of the story in simple, per seat in expert (G88).
    var graphDetail: SystemSetupGraphDetail { self == .expert ? .expert : .simple }
}

private struct InterfaceModeKey: EnvironmentKey {
    static let defaultValue = InterfaceMode.expert
}

extension EnvironmentValues {
    /// Set once at the root view. Defaults to expert so a view outside the root shows everything, as before.
    var interfaceMode: InterfaceMode {
        get { self[InterfaceModeKey.self] }
        set { self[InterfaceModeKey.self] = newValue }
    }
}
