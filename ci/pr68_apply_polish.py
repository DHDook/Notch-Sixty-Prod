#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)

# Dashboard VU redesign.
path = ROOT / "NotchSixty/UI/ProductionRootView.swift"
text = path.read_text(encoding="utf-8")
text = replace_once(
    text,
    '''    static func angle(forVU vu: Double) -> Double {\n        205 + normalizedPosition(forVU: vu) * 130\n    }\n''',
    '''    static let startAngleDegrees = 224.0\n    static let sweepDegrees = 92.0\n    static var endAngleDegrees: Double { startAngleDegrees + sweepDegrees }\n\n    static func angle(forVU vu: Double) -> Double {\n        startAngleDegrees + normalizedPosition(forVU: vu) * sweepDegrees\n    }\n''',
    "VU angle geometry",
)
text = replace_once(
    text,
    '''                        Text("\\(engine.masterVolumeConfiguration.level * 100, specifier: "%.0f")%")\n''',
    '''                        Text("\\(engine.masterVolumeConfiguration.level * 100, specifier: "%.1f")%")\n''',
    "master volume precision",
)
start = text.index("private struct StereoSignatureVUMeter: View {")
end = text.index("private struct ProductionActiveCrossoverView: View {")
new_meter = r'''private struct StereoSignatureVUMeter: View {
    let leftVU: Double
    let rightVU: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let leftCenter = CGPoint(x: width * 0.28, y: height * 1.14)
            let rightCenter = CGPoint(x: width * 0.72, y: height * 1.14)
            let radius = min(width * 0.19, height * 0.61)
            let windowWidth = width * 0.94
            let windowHeight = height * 0.74
            let windowCenter = CGPoint(x: width * 0.50, y: height * 0.43)

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.13, green: 0.12, blue: 0.10),
                                Color(red: 0.24, green: 0.21, blue: 0.16),
                                Color(red: 0.10, green: 0.095, blue: 0.085),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(.white.opacity(0.13), lineWidth: 0.8)
                    }
                    .shadow(color: .black.opacity(0.30), radius: 18, y: 8)

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.96, green: 0.91, blue: 0.76),
                                Color(red: 0.88, green: 0.80, blue: 0.62),
                                Color(red: 0.80, green: 0.71, blue: 0.53),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: windowWidth, height: windowHeight)
                    .position(windowCenter)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(.black.opacity(0.38), lineWidth: 1.1)
                            .frame(width: windowWidth, height: windowHeight)
                            .position(windowCenter)
                    }
                    .shadow(color: .black.opacity(0.24), radius: 8, y: 4)

                StereoSignatureVUScaleFace(
                    leftCenter: leftCenter,
                    rightCenter: rightCenter,
                    radius: radius
                )
                .equatable()

                Canvas { context, _ in
                    drawNeedle(context: &context, center: leftCenter, radius: radius, vu: leftVU)
                    drawNeedle(context: &context, center: rightCenter, radius: radius, vu: rightVU)
                }

                Text("LEFT")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2.1)
                    .foregroundStyle(.black.opacity(0.62))
                    .position(x: width * 0.28, y: height * 0.69)

                Text("RIGHT")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2.1)
                    .foregroundStyle(.black.opacity(0.62))
                    .position(x: width * 0.72, y: height * 0.69)

                // A deliberately restrained optical highlight underneath the real
                // Liquid Glass surface gives the window a thick, polished lens feel.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.30),
                                .white.opacity(0.09),
                                .clear,
                                .black.opacity(0.035),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: windowWidth, height: windowHeight)
                    .position(windowCenter)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(0.001))
                    .frame(width: windowWidth, height: windowHeight)
                    .position(windowCenter)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .opacity(0.24)
                    .allowsHitTesting(false)

                Capsule()
                    .fill(.white.opacity(0.23))
                    .frame(width: width * 0.36, height: 1.2)
                    .blur(radius: 0.35)
                    .position(x: width * 0.30, y: height * 0.105)
                    .allowsHitTesting(false)

                HStack(spacing: 10) {
                    Rectangle().fill(.white.opacity(0.16)).frame(width: 30, height: 1)
                    Text("NOTCH SIXTY")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .tracking(3.4)
                        .foregroundStyle(.white.opacity(0.68))
                    Rectangle().fill(.white.opacity(0.16)).frame(width: 30, height: 1)
                }
                .position(x: width * 0.50, y: height * 0.90)
            }
        }
        .aspectRatio(3.2, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stereo output VU meter")
        .accessibilityValue("Left \(leftVU, specifier: "%.1f") VU, right \(rightVU, specifier: "%.1f") VU")
    }

    private func drawNeedle(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        vu: Double
    ) {
        let angle = ProductionVUScale.angle(forVU: vu)
        var path = Path()
        // The mechanical pivot intentionally lives below the visible glass. Only
        // the upper needle segment is drawn, producing the shallow 1970s sweep.
        path.move(to: ProductionVUScale.point(center: center, radius: radius * 0.62, angle: angle))
        path.addLine(to: ProductionVUScale.point(center: center, radius: radius * 0.985, angle: angle))
        context.stroke(path, with: .color(.black.opacity(0.24)), lineWidth: 4.4)
        context.stroke(
            path,
            with: .color(Color(red: 0.76, green: 0.16, blue: 0.10).opacity(0.96)),
            lineWidth: 2.15
        )
    }
}

private struct StereoSignatureVUScaleFace: View, Equatable {
    let leftCenter: CGPoint
    let rightCenter: CGPoint
    let radius: CGFloat

    var body: some View {
        Canvas { context, _ in
            drawScale(context: &context, center: leftCenter)
            drawScale(context: &context, center: rightCenter)
        }
    }

    private func drawScale(context: inout GraphicsContext, center: CGPoint) {
        let ticks: [Double] = [-40, -35, -30, -25, -20, -15, -10, -7, -5, -4, -3, -2, -1, 0, 1, 2, 3]
        let labels: Set<Double> = [-40, -30, -20, -10, -7, -5, -3, 0, 3]
        let scaleRadius = radius * 0.985

        var arc = Path()
        arc.addArc(
            center: center,
            radius: scaleRadius,
            startAngle: .degrees(ProductionVUScale.startAngleDegrees),
            endAngle: .degrees(ProductionVUScale.endAngleDegrees),
            clockwise: false
        )
        context.stroke(arc, with: .color(.black.opacity(0.64)), lineWidth: 1.25)

        var hotArc = Path()
        hotArc.addArc(
            center: center,
            radius: scaleRadius,
            startAngle: .degrees(ProductionVUScale.angle(forVU: 0)),
            endAngle: .degrees(ProductionVUScale.endAngleDegrees),
            clockwise: false
        )
        context.stroke(
            hotArc,
            with: .color(Color(red: 0.63, green: 0.10, blue: 0.07).opacity(0.86)),
            lineWidth: 2.0
        )

        for value in ticks {
            let angle = ProductionVUScale.angle(forVU: value)
            let major = labels.contains(value)
            let inner = ProductionVUScale.point(
                center: center,
                radius: radius * (major ? 0.895 : 0.925),
                angle: angle
            )
            let outer = ProductionVUScale.point(center: center, radius: scaleRadius, angle: angle)
            var path = Path()
            path.move(to: inner)
            path.addLine(to: outer)
            context.stroke(
                path,
                with: .color(value > 0 ? Color.red.opacity(0.82) : .black.opacity(0.70)),
                lineWidth: major ? 1.7 : 0.8
            )

            if major {
                let point = ProductionVUScale.point(center: center, radius: radius * 0.815, angle: angle)
                let label = value > 0 ? "+\(Int(value))" : "\(Int(value))"
                context.draw(
                    Text(label)
                        .font(.system(size: 10, weight: value == 0 ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(value > 0 ? Color.red.opacity(0.86) : Color.black.opacity(0.70)),
                    at: point
                )
            }
        }

        context.draw(
            Text("VU")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(.black.opacity(0.58)),
            at: CGPoint(x: center.x, y: center.y - radius * 0.72)
        )
    }
}

'''
text = text[:start] + new_meter + text[end:]
path.write_text(text, encoding="utf-8")

# Software volume-key step resolution.
path = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
text = path.read_text(encoding="utf-8")
text = replace_once(
    text,
    '''    @Published private(set) var globalVolumeKeyMonitoringState: GlobalVolumeKeyMonitoringState = .stopped\n''',
    '''    @Published private(set) var globalVolumeKeyMonitoringState: GlobalVolumeKeyMonitoringState = .stopped\n    private(set) var softwareVolumeKeyStepDenominator: Int = 16\n''',
    "volume step property",
)
text = replace_once(
    text,
    '''        globalVolumeKeyMonitor.onVolumeIncrement = { [weak self] in self?.handleGlobalVolumeKey(delta: 1.0 / 16.0) }\n        globalVolumeKeyMonitor.onVolumeDecrement = { [weak self] in self?.handleGlobalVolumeKey(delta: -1.0 / 16.0) }\n''',
    '''        globalVolumeKeyMonitor.onVolumeIncrement = { [weak self] in self?.handleGlobalVolumeKey(direction: 1.0) }\n        globalVolumeKeyMonitor.onVolumeDecrement = { [weak self] in self?.handleGlobalVolumeKey(direction: -1.0) }\n''',
    "volume key callbacks",
)
text = replace_once(
    text,
    '''    func setMasterVolumeLevel(_ level: Double) throws {\n''',
    '''    func setSoftwareVolumeKeyStepDenominator(_ denominator: Int) {\n        guard denominator == 16 || denominator == 32 || denominator == 64 else { return }\n        softwareVolumeKeyStepDenominator = denominator\n    }\n\n    func setMasterVolumeLevel(_ level: Double) throws {\n''',
    "volume step setter",
)
text = replace_once(
    text,
    '''    private func handleGlobalVolumeKey(delta: Double) {\n        guard masterVolumeCapabilities.controlMode == .softwareDSP else { return }\n        let level = min(\n''',
    '''    private func handleGlobalVolumeKey(direction: Double) {\n        guard masterVolumeCapabilities.controlMode == .softwareDSP,\n              direction == 1.0 || direction == -1.0 else { return }\n        let delta = direction / Double(softwareVolumeKeyStepDenominator)\n        let level = min(\n''',
    "volume key handler",
)
path.write_text(text, encoding="utf-8")

# Persisted application preference + Settings UI.
path = ROOT / "NotchSixty/NotchSixtyApp.swift"
text = path.read_text(encoding="utf-8")
anchor = '''private enum ApplicationPresenceMode: String, CaseIterable, Identifiable {\n'''
idx = text.index(anchor)
# Insert the new enum after the full presence enum, immediately before @MainActor preferences.
prefs_marker = '''@MainActor\nprivate final class ApplicationPreferences: ObservableObject {\n'''
insert_at = text.index(prefs_marker)
volume_enum = r'''private enum ApplicationVolumeStepResolution: Int, CaseIterable, Identifiable {
    case standard = 16
    case fine = 32
    case precision = 64

    var id: Int { rawValue }
    var denominator: Int { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "1/16"
        case .fine: return "1/32"
        case .precision: return "1/64"
        }
    }

    var percentPerPress: Double { 100.0 / Double(rawValue) }
}

'''
text = text[:insert_at] + volume_enum + text[insert_at:]
text = replace_once(
    text,
    '''        static let appearance = "application.appearance"\n        static let presence = "application.presence"\n''',
    '''        static let appearance = "application.appearance"\n        static let presence = "application.presence"\n        static let volumeStepResolution = "application.volumeStepResolution"\n''',
    "preference key",
)
text = replace_once(
    text,
    '''    private let defaults: UserDefaults\n\n    @Published var appearance: ApplicationAppearanceMode {\n''',
    '''    private let defaults: UserDefaults\n    private weak var audioEngine: AudioIOEngine?\n\n    @Published var appearance: ApplicationAppearanceMode {\n''',
    "preferences engine reference",
)
text = replace_once(
    text,
    '''    @Published var presence: ApplicationPresenceMode {\n        didSet {\n            defaults.set(presence.rawValue, forKey: Key.presence)\n            applyActivationPolicy()\n        }\n    }\n\n    @Published private(set) var launchAtLoginEnabled: Bool\n''',
    '''    @Published var presence: ApplicationPresenceMode {\n        didSet {\n            defaults.set(presence.rawValue, forKey: Key.presence)\n            applyActivationPolicy()\n        }\n    }\n\n    @Published var volumeStepResolution: ApplicationVolumeStepResolution {\n        didSet {\n            defaults.set(volumeStepResolution.rawValue, forKey: Key.volumeStepResolution)\n            audioEngine?.setSoftwareVolumeKeyStepDenominator(volumeStepResolution.denominator)\n        }\n    }\n\n    @Published private(set) var launchAtLoginEnabled: Bool\n''',
    "volume preference property",
)
text = replace_once(
    text,
    '''        presence = ApplicationPresenceMode(\n            rawValue: defaults.string(forKey: Key.presence) ?? ""\n        ) ?? .both\n        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled\n''',
    '''        presence = ApplicationPresenceMode(\n            rawValue: defaults.string(forKey: Key.presence) ?? ""\n        ) ?? .both\n        volumeStepResolution = ApplicationVolumeStepResolution(\n            rawValue: defaults.integer(forKey: Key.volumeStepResolution)\n        ) ?? .standard\n        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled\n''',
    "volume preference load",
)
text = replace_once(
    text,
    '''    func apply() {\n        guard !didApplyInitialPreferences else { return }\n        didApplyInitialPreferences = true\n        applyAppearance()\n        applyActivationPolicy()\n    }\n''',
    '''    func apply(to audioEngine: AudioIOEngine) {\n        self.audioEngine = audioEngine\n        audioEngine.setSoftwareVolumeKeyStepDenominator(volumeStepResolution.denominator)\n        guard !didApplyInitialPreferences else { return }\n        didApplyInitialPreferences = true\n        applyAppearance()\n        applyActivationPolicy()\n    }\n''',
    "preferences apply",
)
settings_anchor = '''                    settingsCard(title: "App Presence", systemImage: "macwindow.on.rectangle") {\n'''
volume_card = r'''                    settingsCard(title: "Volume Keys", systemImage: "speaker.wave.2") {
                        HStack(spacing: 10) {
                            Text("Step size")
                            Spacer()
                            Picker("Volume key step size", selection: $preferences.volumeStepResolution) {
                                ForEach(ApplicationVolumeStepResolution.allCases) { resolution in
                                    Text(resolution.displayName).tag(resolution)
                                }
                            }
                            .labelsHidden()
                            .productionGlassPickerChrome()
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }

                        Text("Controls Notch Sixty's software master-volume change for each intercepted volume-key press. 1/16 = 6.25%, 1/32 = 3.125%, and 1/64 = 1.5625%. The physical output-device volume is not stepped by this setting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

'''
text = replace_once(text, settings_anchor, volume_card + settings_anchor, "settings volume card")
text = replace_once(
    text,
    '''        .task { preferences.refreshLaunchAtLoginStatus() }\n''',
    '''        .task {\n            preferences.apply(to: product.audioEngine)\n            preferences.refreshLaunchAtLoginStatus()\n        }\n''',
    "settings task",
)
text = replace_once(
    text,
    '''                    preferences.apply()\n''',
    '''                    preferences.apply(to: product.audioEngine)\n''',
    "main window preference apply",
)
text = replace_once(
    text,
    '''            ProductionMenuBarView(product: product)\n                .task { product.prepareForUse() }\n''',
    '''            ProductionMenuBarView(product: product)\n                .task {\n                    product.prepareForUse()\n                    preferences.apply(to: product.audioEngine)\n                }\n''',
    "menu bar preference apply",
)
path.write_text(text, encoding="utf-8")

print("PR68 polish patch applied")
