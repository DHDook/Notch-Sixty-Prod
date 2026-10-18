import Foundation

/// A feature still in development. An unfinished epic merges to `main` behind
/// a flag that is off by default, so a shipped build never shows it by accident.
///
/// Flags gate app-shell behaviour only. The engine never reads them: Swift
/// decides, then publishes the resulting configuration through the normal
/// graph/snapshot path, which keeps the realtime core flag-free and portable.
struct FeatureFlag: Hashable, Identifiable, Sendable {
    /// Stable identifier; stored as `feature.<id>` and used on the command line.
    let id: String
    let title: String
    /// The program-plan epic that owns the flag, for example "E6".
    let epic: String
    var defaultEnabled = false
}

extension FeatureFlag {
    /// Every flag the app knows. Add one when an epic starts merging dark;
    /// delete it, and the checks that read it, once the epic ships.
    static let all: [FeatureFlag] = [.uiScope]

    /// E5: bench and research tools leave the sidebar for a Developer menu.
    static let uiScope = FeatureFlag(
        id: "e5.ui-scope",
        title: "Simplified workspace layout",
        epic: "E5"
    )
}

/// Resolves feature flags.
///
/// - Debug builds honour overrides stored from the Developer section of Settings.
/// - Release builds ignore stored overrides; testers can still enable flags with
///   the launch argument `-NotchSixtyFeatures id1,id2`.
/// - Flags that are not in `known` are always off, so a stale stored override or
///   a mistyped launch argument can never switch anything on.
@MainActor
final class FeatureFlags: ObservableObject {
    enum OverridePolicy: Sendable {
        case storedOverrides
        case launchArgumentOnly
    }

    nonisolated static let launchArgument = "-NotchSixtyFeatures"

    nonisolated static var buildPolicy: OverridePolicy {
        #if DEBUG
        .storedOverrides
        #else
        .launchArgumentOnly
        #endif
    }

    let known: [FeatureFlag]
    let policy: OverridePolicy
    private let defaults: UserDefaults
    private let launchEnabledIDs: Set<String>

    init(
        known: [FeatureFlag] = FeatureFlag.all,
        defaults: UserDefaults = .standard,
        policy: OverridePolicy = FeatureFlags.buildPolicy,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.known = known
        self.defaults = defaults
        self.policy = policy
        self.launchEnabledIDs = Self.launchEnabledIDs(in: arguments)
    }

    var canEditOverrides: Bool { policy == .storedOverrides }

    func isEnabled(_ flag: FeatureFlag) -> Bool {
        guard known.contains(flag) else { return false }
        if launchEnabledIDs.contains(flag.id) { return true }
        if canEditOverrides, let stored = defaults.object(forKey: Self.key(for: flag)) as? Bool {
            return stored
        }
        return flag.defaultEnabled
    }

    /// True when the launch argument, not a stored override, decides the flag.
    func isForcedByLaunchArgument(_ flag: FeatureFlag) -> Bool {
        known.contains(flag) && launchEnabledIDs.contains(flag.id)
    }

    func setEnabled(_ enabled: Bool, for flag: FeatureFlag) {
        guard canEditOverrides, known.contains(flag) else { return }
        objectWillChange.send()
        defaults.set(enabled, forKey: Self.key(for: flag))
    }

    func resetOverrides() {
        guard canEditOverrides else { return }
        objectWillChange.send()
        for flag in known {
            defaults.removeObject(forKey: Self.key(for: flag))
        }
    }

    static func key(for flag: FeatureFlag) -> String {
        PreferenceKeys.featureFlagPrefix + flag.id
    }

    private static func launchEnabledIDs(in arguments: [String]) -> Set<String> {
        guard let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1) else {
            return []
        }
        return Set(
            arguments[index + 1]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }
}
