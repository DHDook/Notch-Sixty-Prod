import AppKit
import SwiftUI

/// E27 S1: pieces of the Equalizer graph that need AppKit or their own invalidation scope.

// MARK: Read-out text

enum EQGraphReadout {
    /// "1.20 kHz  +3.4 dB" under the crosshair.
    static func cursorText(frequencyHz: Double, responseDB: Double) -> String {
        let frequency = frequencyHz >= 1_000
            ? String(format: "%.2f kHz", frequencyHz / 1_000)
            : String(format: "%.1f Hz", frequencyHz)
        return "\(frequency)   \(EQBandPanelModel.gainText(responseDB))"
    }

    /// "Band 3  Peak  300 Hz  -0.7 dB  Q 1.00" over a handle; gain and Q are omitted when the
    /// filter type has none.
    static func bandText(number: Int, band: EQBand, hasGain: Bool, hasQ: Bool) -> String {
        var parts = ["Band \(number)", band.type.displayName, EQBandPanelModel.frequencyText(band.frequencyHz)]
        if hasGain { parts.append(EQBandPanelModel.gainText(band.gainDB)) }
        if hasQ { parts.append(String(format: "Q %.2f", band.q)) }
        return parts.joined(separator: "   ")
    }
}

// MARK: Hover

/// The pointer position over the graph. It is a separate observable object so a mouse move
/// redraws only the crosshair overlay, never the response curve.
final class EQGraphHoverModel: ObservableObject {
    @Published var location: CGPoint?
}

struct EQGraphHoverHandle {
    let handle: EQGraphGeometry.Handle
    let number: Int
    let band: EQBand
    let hasGain: Bool
    let hasQ: Bool
}

struct EQGraphHoverOverlay: View {
    @ObservedObject var model: EQGraphHoverModel
    let geometry: EQGraphGeometry
    let size: CGSize
    let handles: [EQGraphHoverHandle]
    let responseDB: (Double) -> Double

    var body: some View {
        if let location = model.location, location.x >= 0, location.y >= 0,
           location.x <= size.width, location.y <= size.height {
            let hovered = EQGraphGeometry.hitHandle(at: location, handles: handles.map(\.handle))
                .flatMap { id in handles.first { $0.handle.id == id } }
            let frequency = geometry.frequency(x: location.x, width: size.width)
            let db = responseDB(frequency)
            let curveY = geometry.y(db: db, height: size.height)
            let text = hovered.map {
                EQGraphReadout.bandText(number: $0.number, band: $0.band, hasGain: $0.hasGain, hasQ: $0.hasQ)
            } ?? EQGraphReadout.cursorText(frequencyHz: frequency, responseDB: db)

            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    var vertical = Path()
                    vertical.move(to: CGPoint(x: location.x, y: 0))
                    vertical.addLine(to: CGPoint(x: location.x, y: canvasSize.height))
                    var horizontal = Path()
                    horizontal.move(to: CGPoint(x: 0, y: curveY))
                    horizontal.addLine(to: CGPoint(x: canvasSize.width, y: curveY))
                    let style = StrokeStyle(lineWidth: 1, dash: [3, 3])
                    context.stroke(vertical, with: .color(.primary.opacity(0.35)), style: style)
                    context.stroke(horizontal, with: .color(.primary.opacity(0.2)), style: style)
                    let dot = CGRect(x: location.x - 3.5, y: curveY - 3.5, width: 7, height: 7)
                    context.fill(Path(ellipseIn: dot), with: .color(.accentColor))
                }
                Text(text)
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: .capsule)
                    .fixedSize()
                    .position(labelPosition(near: location))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Keeps the label inside the graph, flipping to the other side of the pointer near an edge.
    private func labelPosition(near location: CGPoint) -> CGPoint {
        let halfWidth: CGFloat = 105
        let x = min(max(location.x, halfWidth + 6), max(size.width - halfWidth - 6, halfWidth + 6))
        let y = location.y < 40 ? location.y + 28 : location.y - 22
        return CGPoint(x: x, y: y)
    }
}

// MARK: Scroll and pinch

/// SwiftUI has no scroll-wheel or trackpad-pinch event on macOS, so this transparent view
/// watches both through a local event monitor. It never takes hits (clicks and drags reach the
/// graph), and returns `true` from a callback to consume the event; an unhandled scroll goes on
/// to the page.
struct EQGraphEventCatcher: NSViewRepresentable {
    /// (point in the view, scrolling delta Y, precise trackpad deltas) -> consumed
    var onScroll: (CGPoint, Double, Bool) -> Bool
    /// (point in the view, magnification delta) -> consumed
    var onMagnify: (CGPoint, Double) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.removeMonitor()
    }

    final class CatcherView: NSView {
        var onScroll: ((CGPoint, Double, Bool) -> Bool)?
        var onMagnify: ((CGPoint, Double) -> Bool)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return event }
            let consumed: Bool
            switch event.type {
            case .scrollWheel:
                consumed = onScroll?(point, Double(event.scrollingDeltaY), event.hasPreciseScrollingDeltas) ?? false
            case .magnify:
                consumed = onMagnify?(point, Double(event.magnification)) ?? false
            default:
                consumed = false
            }
            return consumed ? nil : event
        }
    }
}
