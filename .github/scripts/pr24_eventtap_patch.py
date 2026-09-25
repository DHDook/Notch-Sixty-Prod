from pathlib import Path


def replace(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"pattern not found in {path}: {old[:160]!r}")
    p.write_text(text.replace(old, new, 1))


monitor = Path("NotchSixty/Audio/CoreAudio/MasterVolumeDeviceController.swift")
text = monitor.read_text()
text = text.replace(
    "import CoreAudio\nimport Foundation\nimport IOKit.hid\n",
    "import AppKit\nimport CoreAudio\nimport CoreGraphics\nimport Foundation\n",
    1,
)
text = text.replace(
    "enum GlobalVolumeKeyMonitorError: Error, LocalizedError, Equatable {\n    case permissionRequired\n    case openFailed(IOReturn)\n\n    var errorDescription: String? {\n        switch self {\n        case .permissionRequired:\n            return \"Keyboard volume control requires Input Monitoring permission in System Settings > Privacy & Security > Input Monitoring.\"\n        case .openFailed(let status):\n            return \"Unable to open the keyboard volume-key monitor (IOKit status \\(status)).\"\n        }\n    }\n}",
    "enum GlobalVolumeKeyMonitorError: Error, LocalizedError, Equatable {\n    case permissionRequired\n    case eventTapUnavailable\n\n    var errorDescription: String? {\n        switch self {\n        case .permissionRequired:\n            return \"Keyboard volume control requires Input Monitoring permission in System Settings > Privacy & Security > Input Monitoring.\"\n        case .eventTapUnavailable:\n            return \"Unable to create the listen-only system volume-key event tap.\"\n        }\n    }\n}",
    1,
)
start = text.index("/// Passive public HID listener for fixed-volume outputs.")
text = text[:start] + r'''enum GlobalVolumeKeyAction: Equatable, Sendable {
    case increment
    case decrement
}

/// Listen-only public Core Graphics event tap for fixed-volume outputs. macOS
/// handles hardware volume keys below ordinary AppKit key delivery; the event
/// tap observes their system-defined auxiliary-control events without seizing,
/// suppressing, synthesizing, or reposting input.
final class CoreGraphicsGlobalVolumeKeyMonitor: GlobalVolumeKeyMonitoring {
    var onVolumeIncrement: (() -> Void)?
    var onVolumeDecrement: (() -> Void)?
    private(set) var state: GlobalVolumeKeyMonitoringState = .stopped

    private static let auxiliaryControlButtonSubtype: Int16 = 8
    private static let soundUpKeyCode = 0
    private static let soundDownKeyCode = 1
    private static let keyDownState = 0xA

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    static func action(subtype: Int16, data1: Int) -> GlobalVolumeKeyAction? {
        guard subtype == auxiliaryControlButtonSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyState = (data1 & 0x0000FF00) >> 8
        guard keyState == keyDownState else { return nil }

        switch keyCode {
        case soundUpKeyCode:
            return .increment
        case soundDownKeyCode:
            return .decrement
        default:
            return nil
        }
    }

    func start() throws {
        guard eventTap == nil else { return }

        guard CGPreflightListenEventAccess() else {
            _ = CGRequestListenEventAccess()
            state = .permissionRequired
            throw GlobalVolumeKeyMonitorError.permissionRequired
        }

        guard let systemDefinedType = CGEventType(
            rawValue: UInt32(NSEvent.EventType.systemDefined.rawValue)
        ) else {
            state = .stopped
            throw GlobalVolumeKeyMonitorError.eventTapUnavailable
        }
        let eventMask = CGEventMask(1) << systemDefinedType.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<CoreGraphicsGlobalVolumeKeyMonitor>
                    .fromOpaque(context)
                    .takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue),
                      let nsEvent = NSEvent(cgEvent: event),
                      let action = CoreGraphicsGlobalVolumeKeyMonitor.action(
                        subtype: nsEvent.subtype.rawValue,
                        data1: nsEvent.data1
                      ) else {
                    return Unmanaged.passUnretained(event)
                }

                switch action {
                case .increment:
                    monitor.onVolumeIncrement?()
                case .decrement:
                    monitor.onVolumeDecrement?()
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            state = .stopped
            throw GlobalVolumeKeyMonitorError.eventTapUnavailable
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            state = .stopped
            throw GlobalVolumeKeyMonitorError.eventTapUnavailable
        }

        self.eventTap = tap
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        state = .active
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        state = .stopped
    }

    deinit {
        stop()
    }
}
'''
monitor.write_text(text)

replace(
    "NotchSixty/Audio/AudioIOEngine.swift",
    "globalVolumeKeyMonitor: any GlobalVolumeKeyMonitoring = CoreHIDGlobalVolumeKeyMonitor()",
    "globalVolumeKeyMonitor: any GlobalVolumeKeyMonitoring = CoreGraphicsGlobalVolumeKeyMonitor()",
)

# Add deterministic parsing tests for the system-defined media-key payload.
tests = "NotchSixtyTests/StereoPlaybackControlTests.swift"
replace(
    tests,
    "    func testFixedVolumeDeviceUsesSoftwareMasterGainForKeyboardFallback() {",
    """    func testSystemDefinedVolumeKeyDecodingUsesKeyDownOnly() {
        let volumeUpDownEvent = (0 << 16) | (0xA << 8)
        let volumeDownDownEvent = (1 << 16) | (0xA << 8)
        let volumeUpReleaseEvent = (0 << 16) | (0xB << 8)
        let muteDownEvent = (7 << 16) | (0xA << 8)

        XCTAssertEqual(
            CoreGraphicsGlobalVolumeKeyMonitor.action(subtype: 8, data1: volumeUpDownEvent),
            .increment
        )
        XCTAssertEqual(
            CoreGraphicsGlobalVolumeKeyMonitor.action(subtype: 8, data1: volumeDownDownEvent),
            .decrement
        )
        XCTAssertNil(CoreGraphicsGlobalVolumeKeyMonitor.action(subtype: 8, data1: volumeUpReleaseEvent))
        XCTAssertNil(CoreGraphicsGlobalVolumeKeyMonitor.action(subtype: 8, data1: muteDownEvent))
        XCTAssertNil(CoreGraphicsGlobalVolumeKeyMonitor.action(subtype: 7, data1: volumeUpDownEvent))
    }

    func testFixedVolumeDeviceUsesSoftwareMasterGainForKeyboardFallback() {""",
)

# Surface permission/tap state in the temporary engineering UI for hardware acceptance.
view = "NotchSixty/ContentView.swift"
replace(
    view,
    "    private var globalBypassBinding: Binding<Bool> {",
    """    private var globalVolumeKeyStatus: String {
        switch engine.globalVolumeKeyMonitoringState {
        case .stopped: return "Keys: Stopped"
        case .permissionRequired: return "Keys: Permission Required"
        case .active: return "Keys: Active"
        }
    }

    private var globalBypassBinding: Binding<Bool> {""",
)
replace(
    view,
    "                Text(engine.masterVolumeCapabilities.controlMode == .device ? \"Device\" : \"Software DSP\")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)",
    "                Text(engine.masterVolumeCapabilities.controlMode == .device ? \"Device\" : \"Software DSP\")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)\n                Text(globalVolumeKeyStatus)\n                    .font(.caption)\n                    .foregroundStyle(.secondary)",
)

# Replace the failed raw-HID design documentation with the public CGEventTap path.
doc = Path("docs/MASTER_VOLUME_CONTROL.md")
doc_text = doc.read_text()
doc_text = doc_text.replace(
    "A passive public IOKit HID listener observes Consumer Control volume usages and maps them to 1/16-scale master-volume steps. The listener is active only in software-DSP volume mode, never seizes or suppresses keyboard events, and requires the user's macOS Input Monitoring permission.",
    "A listen-only public Core Graphics `CGEventTap` observes system-defined auxiliary-control Volume Up/Down events and maps key-down events to 1/16-scale master-volume steps. The tap is active only in software-DSP volume mode, never seizes, suppresses, synthesizes, or reposts keyboard events, and uses the user's macOS Input Monitoring permission via `CGPreflightListenEventAccess` / `CGRequestListenEventAccess`.",
)
doc_text += "\nHardware note: the earlier raw `IOHIDManager` Consumer Control listener prompted successfully for Input Monitoring on the fixed-output Modi 5 test chain but did not receive Volume Up/Down events on macOS 26. It was removed rather than retained as a second input path.\n"
doc.write_text(doc_text)

prov = Path("docs/PROVENANCE.md")
prov_text = prov.read_text()
prov_text = prov_text.replace(
    "a passive public IOKit HID listener observes Consumer Control Volume Increment/Decrement usages. The HID path does not seize, suppress, synthesize, or repost keyboard events",
    "a listen-only public Core Graphics `CGEventTap` observes system-defined auxiliary-control Volume Up/Down events. The event-tap path does not seize, suppress, synthesize, or repost keyboard events",
)
prov.write_text(prov_text)
