import SwiftUI

/// E34 S1: the shared components. Each takes its values from `DesignStyle`, so the flag switches them all at once.
/// A card is content, so it uses a plain background and no glass (`docs/DESIGN_LANGUAGE.md`, rule 1).

struct DesignCard<Content: View>: View {
    var style: DesignStyle = .active
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(DesignSpacing.m.value(style))
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(DesignSurfaceModifier(radius: .medium, style: style))
    }
}

/// Page header: title, optional status, and the one main action in a fixed place (trailing).
struct DesignPageHeader<Action: View>: View {
    var title: String
    var subtitle: String?
    var status: StatusLevel?
    var statusText: String?
    var style: DesignStyle = .active
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.m.value(style)) {
            VStack(alignment: .leading, spacing: DesignSpacing.xs.value(style)) {
                Text(title)
                    .font(DesignType.pageTitle.font(style))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(DesignType.body.font(style))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: DesignSpacing.m.value(style))
            if let status {
                DesignStatusBadge(level: status, text: statusText, style: style)
            }
            action()
        }
    }
}

extension DesignPageHeader where Action == EmptyView {
    init(title: String, subtitle: String? = nil, status: StatusLevel? = nil, statusText: String? = nil,
         style: DesignStyle = .active) {
        self.init(title: title, subtitle: subtitle, status: status, statusText: statusText, style: style) {
            EmptyView()
        }
    }
}

/// Status badge: icon, colour and a word. Not glass (it is content).
struct DesignStatusBadge: View {
    var level: StatusLevel
    var text: String?
    var style: DesignStyle = .active

    var body: some View {
        Label(text ?? level.label, systemImage: level.iconName)
            .font(DesignType.label.font(style))
            .foregroundStyle(level.color)
            .padding(.horizontal, DesignSpacing.s.value(style))
            .padding(.vertical, DesignSpacing.xs.value(style))
            .modifier(DesignTintModifier(color: level.color, opacity: 0.14, radius: .small, style: style))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text ?? level.label)
            .accessibilityValue(level.label)
    }
}

/// Button roles. Glass for all, prominent glass for the one main action on a page (owner decision 4).
enum DesignButtonRole: CaseIterable, Sendable {
    case primary
    case secondary
    case destructive
}

struct DesignButton: View {
    var title: String
    var systemImage: String?
    var role: DesignButtonRole = .secondary
    var action: () -> Void

    var body: some View {
        switch role {
        case .primary:
            base.buttonStyle(.glassProminent)
        case .secondary:
            base.buttonStyle(.glass)
        case .destructive:
            base.buttonStyle(.glass).tint(.red)
        }
    }

    private var base: some View {
        Button(role: role == .destructive ? .destructive : nil, action: action) {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
    }
}

/// One way to be empty, busy, stopped or wrong (S4 adopts it on every page).
enum DesignStateKind: CaseIterable, Sendable {
    case empty, busy, stopped, failed

    var level: StatusLevel {
        switch self {
        case .empty, .busy: return .off
        case .stopped: return .attention
        case .failed: return .problem
        }
    }

    var iconName: String {
        switch self {
        case .empty: return "tray"
        case .busy: return "hourglass"
        case .stopped: return "pause.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

struct DesignStateView: View {
    var kind: DesignStateKind
    var title: String
    var detail: String?
    var style: DesignStyle = .active
    /// Replaces the kind's icon (for example a magnifier for "no results").
    var systemImage: String?
    /// One optional action ("Add Band", "Start"), shown as the primary button.
    var actionTitle: String?
    var actionIdentifier: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: DesignSpacing.s.value(style)) {
            if kind == .busy {
                ProgressView()
            } else {
                Image(systemName: systemImage ?? kind.iconName)
                    .font(.system(size: 28))
                    .foregroundStyle(kind.level.color)
                    .accessibilityHidden(true)
            }
            Text(title).font(DesignType.sectionTitle.font(style))
            if let detail {
                Text(detail)
                    .font(DesignType.body.font(style))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(actionIdentifier ?? "state.action")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSpacing.xl.value(style))
        .accessibilityElement(children: .combine)
    }
}
