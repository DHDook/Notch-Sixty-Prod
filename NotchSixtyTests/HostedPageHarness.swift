import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E33 S11b part 2 (G106): a test harness that hosts a real SwiftUI page and reads and drives it.
///
/// Why not the accessibility tree: SwiftUI builds its accessibility nodes only for an attached assistive client, so in a
/// test process `Text` rows are unreachable. What *is* real are the AppKit controls SwiftUI hosts for pickers, menus,
/// toggles, sliders and text fields (`NSPopUpButton`, `NSSegmentedControl`, `NSSwitch`, `NSSlider`, `NSTextField`,
/// `NSButton`). They carry the page's real accessibility labels and values, so the harness walks the `NSView` tree and
/// returns one `PageControl` per control. Tests read titles, labels, values, menu items and segments, and drive a control
/// the way a click or an edit does. No third-party code, no private API.
///
/// Limit (recorded as G107): a bare `Text` row (a readout, a note, a badge) is drawn straight into the layer and is not
/// reachable here. A page that needs such a row checked exposes it as the label or value of a control, or the row is
/// covered by the model test named in its gap.
@MainActor
struct PageControl {
    enum Kind: String { case popup, segmented, toggle, slider, textField, button, other }

    let kind: Kind
    /// Accessibility label, or the title for a button.
    let label: String
    /// The visible title (button and pop-up) or the string value (text field).
    let title: String
    /// Accessibility value as text: slider value, toggle state, selected segment.
    let value: String
    let identifier: String
    /// Menu item titles for a pop-up; segment labels for a segmented control.
    let items: [String]
    let isEnabled: Bool
    let view: NSView

    /// Everything a test might search for, in one string.
    var searchText: String { ([label, title, value, identifier] + items).joined(separator: " | ") }
}

@MainActor
final class HostedPage {
    let hosting: NSHostingView<AnyView>
    let window: NSWindow

    /// Hosts `view` in an off-screen window of `size`, lays it out and lets SwiftUI settle.
    init<V: View>(_ view: V, size: CGSize = CGSize(width: 1_180, height: 2_400)) {
        hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        settle()
    }

    deinit { MainActor.assumeIsolated { window.contentView = nil } }

    /// Lays the page out and runs the main run loop long enough for state changes to reach the AppKit controls.
    func settle(_ seconds: TimeInterval = 0.35) {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        hosting.layoutSubtreeIfNeeded()
    }

    /// Every control the page currently shows, in view-tree order.
    var controls: [PageControl] {
        var found: [PageControl] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ v: NSView) {
            if seen.insert(ObjectIdentifier(v)).inserted, let c = Self.describe(v) { found.append(c) }
            for s in v.subviews { walk(s) }
        }
        walk(hosting)
        return found
    }

    func controls(of kind: PageControl.Kind) -> [PageControl] { controls.filter { $0.kind == kind } }

    /// The first control whose label, title, value, identifier or items contain `text` (case-insensitive).
    /// The text field named `name` (its placeholder).
    func field(_ name: String) -> PageControl? { controls(of: .textField).first { $0.label == name } }

    /// The check boxes and switches that follow the text field `name` in view order; a toggle's label is not exposed to
    /// AppKit, so a toggle is found by what sits before it.
    func toggles(after name: String) -> [PageControl] {
        let all = controls
        guard let i = all.firstIndex(where: { $0.kind == .textField && $0.label == name }) else { return [] }
        return all[(i + 1)...].filter { $0.kind == .toggle }
    }

    /// The nearest toggle before the text field `name`.
    func toggle(before name: String) -> PageControl? {
        let all = controls
        guard let i = all.firstIndex(where: { $0.kind == .textField && $0.label == name }) else { return nil }
        return all[..<i].last { $0.kind == .toggle }
    }

    func control(containing text: String, kind: PageControl.Kind? = nil) -> PageControl? {
        controls.first { (kind == nil || $0.kind == kind) && $0.searchText.localizedCaseInsensitiveContains(text) }
    }

    func has(_ text: String, kind: PageControl.Kind? = nil) -> Bool { control(containing: text, kind: kind) != nil }

    // MARK: Driving

    /// Chooses a menu item by title in the pop-up whose label or title contains `popup`.
    @discardableResult
    func choose(_ item: String, inPopup popup: String) -> Bool {
        guard let c = control(containing: popup, kind: .popup), let button = c.view as? NSPopUpButton,
              let index = button.itemArray.firstIndex(where: { $0.title == item && $0.isEnabled }) else { return false }
        button.selectItem(at: index)
        _ = button.sendAction(button.action, to: button.target)
        settle()
        return true
    }

    /// Clicks a segment by label in the first segmented control that has it, or in the one whose segments are `items`.
    @discardableResult
    func selectSegment(_ label: String, in items: [String]? = nil) -> Bool {
        for c in controls(of: .segmented) where items == nil || c.items == items {
            guard let seg = c.view as? NSSegmentedControl,
                  let index = (0..<seg.segmentCount).first(where: { seg.label(forSegment: $0) == label }) else { continue }
            seg.selectedSegment = index
            _ = seg.sendAction(seg.action, to: seg.target)
            settle()
            return true
        }
        return false
    }

    /// Replaces the text of the field named `name` (its placeholder, which SwiftUI sets from the field's title) and commits it.
    @discardableResult
    func setText(_ new: String, inField name: String) -> Bool {
        guard let c = controls(of: .textField).first(where: { $0.label == name }), let field = c.view as? NSTextField else { return false }
        // Edit the way a user does: focus the field, type into its field editor, press Return, then leave it.
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() else { return false }
        editor.string = new
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: editor)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        window.makeFirstResponder(nil)
        settle()
        return true
    }

    /// Presses a button by title or label.
    @discardableResult
    func press(_ text: String) -> Bool {
        guard let c = controls(of: .button).first(where: { $0.title == text || $0.label == text }), let b = c.view as? NSButton else { return false }
        b.performClick(nil)
        settle()
        return true
    }

    /// Flips a toggle (check box or switch).
    @discardableResult
    func flip(_ toggle: PageControl?) -> Bool {
        guard let b = toggle?.view as? NSControl else { return false }
        if let sw = b as? NSSwitch { sw.state = sw.state == .on ? .off : .on }
        if let button = b as? NSButton { button.performClick(nil) } else { _ = b.sendAction(b.action, to: b.target) }
        settle()
        return true
    }

    // MARK: Reading

    private static func describe(_ v: NSView) -> PageControl? {
        let label = v.accessibilityLabel() ?? ""
        let identifier = v.accessibilityIdentifier()
        let enabled = (v as? NSControl)?.isEnabled ?? true
        func make(_ kind: PageControl.Kind, title: String = "", value: String = "", items: [String] = [], placeholder: String = "") -> PageControl {
            PageControl(kind: kind, label: !placeholder.isEmpty ? placeholder : (label.isEmpty ? title : label), title: title, value: value, identifier: identifier,
                        items: items, isEnabled: enabled, view: v)
        }
        switch v {
        case let p as NSPopUpButton:
            p.menu?.update()
            return make(.popup, title: p.titleOfSelectedItem ?? p.title, items: p.itemArray.map(\.title).filter { !$0.isEmpty })
        case let s as NSSegmentedControl:
            let labels = (0..<s.segmentCount).map { s.label(forSegment: $0) ?? "" }
            let selected = s.selectedSegment >= 0 && s.selectedSegment < labels.count ? labels[s.selectedSegment] : ""
            return make(.segmented, value: selected, items: labels)
        case let sw as NSSwitch:
            return make(.toggle, value: sw.state == .on ? "on" : "off")
        case let sl as NSSlider:
            return make(.slider, value: String(sl.doubleValue))
        case let b as NSButton:
            let kind: PageControl.Kind = (b.accessibilityRole() == .checkBox || b.accessibilityRole() == .radioButton) ? .toggle : .button
            return make(kind, title: b.title, value: b.state == .on ? "on" : "off")
        case let t as NSTextField where t.isEditable:
            return make(.textField, title: t.stringValue, placeholder: t.placeholderString ?? "")
        default:
            if !label.isEmpty || !identifier.isEmpty { return make(.other, value: "\(v.accessibilityValue() ?? "")") }
            return nil
        }
    }

    /// One line per control, for a failure message or a debugging print.
    var outline: String {
        controls.map { "\($0.kind.rawValue) label=\($0.label) title=\($0.title) value=\($0.value) id=\($0.identifier) items=\($0.items) enabled=\($0.isEnabled)" }.joined(separator: "\n")
    }
}
