import CoreGraphics
import Foundation

/// E27 S1: the Equalizer response graph's coordinate maps, hit tests and drag rules as plain
/// value types, kept out of the view so they can be tested at every sample rate without a
/// window. Frequency is logarithmic from 20 Hz to 0.49 fs (or the 20 kHz Audible zoom, E27 S2),
/// gain is linear over the visible range (+/-24 dB unless a y preset narrows or widens it),
/// y grows downward.
struct EQGraphGeometry: Equatable, Sendable {
    static let minimumFrequency = 20.0
    static let minimumDB = -24.0
    static let maximumDB = 24.0
    /// Pointer travel before Shift decides the locked axis.
    static let axisLockThreshold = 4.0
    /// Option-drag moves the handle at this fraction of the pointer travel.
    static let fineFactor = 0.1
    /// Hit radius of a handle in points (an 11 pt handle radius plus the 10 pt inset).
    static let handleHitRadius = 21.0

    /// The right-hand edge of the visible frequency axis.
    let maximumFrequency: Double
    /// The visible gain range; the fields and the band limits stay at `minimumDB`...`maximumDB`.
    let displayMinimumDB: Double
    let displayMaximumDB: Double

    init(sampleRate: Double, zoom: EQGraphXZoom = .full, visibleDB: ClosedRange<Double> = EQGraphGeometry.minimumDB...EQGraphGeometry.maximumDB) {
        maximumFrequency = zoom.maximumFrequency(sampleRate: sampleRate)
        displayMinimumDB = visibleDB.lowerBound
        displayMaximumDB = max(visibleDB.upperBound, visibleDB.lowerBound + 0.001)
    }

    // MARK: Maps

    func x(frequency: Double, width: CGFloat) -> CGFloat {
        let clamped = min(max(frequency, Self.minimumFrequency), maximumFrequency)
        let t = (log(clamped) - log(Self.minimumFrequency)) / (log(maximumFrequency) - log(Self.minimumFrequency))
        return CGFloat(t) * width
    }

    func frequency(x: CGFloat, width: CGFloat) -> Double {
        let t = min(max(Double(x / max(width, 1)), 0), 1)
        return exp(log(Self.minimumFrequency) + t * (log(maximumFrequency) - log(Self.minimumFrequency)))
    }

    func y(db: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(db, displayMinimumDB), displayMaximumDB)
        return CGFloat((displayMaximumDB - clamped) / (displayMaximumDB - displayMinimumDB)) * height
    }

    func gain(y: CGFloat, height: CGFloat) -> Double {
        let t = min(max(Double(y / max(height, 1)), 0), 1)
        return displayMaximumDB - t * (displayMaximumDB - displayMinimumDB)
    }

    func point(frequency: Double, gainDB: Double, size: CGSize) -> CGPoint {
        CGPoint(x: x(frequency: frequency, width: size.width), y: y(db: gainDB, height: size.height))
    }

    /// Frequency and gain under a point (a double-click on empty graph).
    func position(at point: CGPoint, size: CGSize) -> (frequencyHz: Double, gainDB: Double) {
        (frequency(x: point.x, width: size.width), gain(y: point.y, height: size.height))
    }

    // MARK: Hit tests

    struct Handle: Equatable, Sendable {
        let id: UUID
        let center: CGPoint
    }

    /// The handle nearest `point` within `radius`, preferring the later (topmost) handle on a tie.
    static func hitHandle(at point: CGPoint, handles: [Handle], radius: Double = handleHitRadius) -> UUID? {
        var best: (id: UUID, distance: Double)?
        for handle in handles {
            let distance = hypot(Double(handle.center.x - point.x), Double(handle.center.y - point.y))
            guard distance <= radius else { continue }
            if best == nil || distance <= best!.distance { best = (handle.id, distance) }
        }
        return best?.id
    }

    // MARK: Drag

    enum Axis: Equatable, Sendable {
        case horizontal
        case vertical
    }

    /// One handle drag. The handle moves by the pointer's travel, so a click off-centre does
    /// not make it jump. Shift locks the dominant axis once the pointer has travelled 4 pt;
    /// Option scales the travel by 0.1. Modifier keys are read on every update, so they can
    /// be pressed or released mid-drag without a jump (the travel is accumulated scaled).
    struct DragSession: Equatable, Sendable {
        let origin: CGPoint
        let start: CGPoint
        private(set) var lockedAxis: Axis?
        private var last: CGPoint
        private var offset = CGSize.zero

        /// `origin` is the handle's centre at mouse-down, `start` the pointer's position.
        init(origin: CGPoint, start: CGPoint) {
            self.origin = origin
            self.start = start
            last = start
        }

        /// `bounds` is the graph size; the handle stops at its edge and the stored travel is
        /// clamped with it, so pulling back moves the handle at once.
        mutating func update(location: CGPoint, shift: Bool, option: Bool, bounds: CGSize) -> CGPoint {
            let factor = option ? EQGraphGeometry.fineFactor : 1
            offset.width += (location.x - last.x) * factor
            offset.height += (location.y - last.y) * factor
            last = location
            offset.width = min(max(origin.x + offset.width, 0), max(bounds.width, 0)) - origin.x
            offset.height = min(max(origin.y + offset.height, 0), max(bounds.height, 0)) - origin.y

            if shift {
                if lockedAxis == nil {
                    let dx = location.x - start.x
                    let dy = location.y - start.y
                    if hypot(Double(dx), Double(dy)) >= EQGraphGeometry.axisLockThreshold {
                        lockedAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical
                    }
                }
            } else {
                lockedAxis = nil
            }

            var result = CGPoint(x: origin.x + offset.width, y: origin.y + offset.height)
            switch lockedAxis {
            case .horizontal: result.y = origin.y
            case .vertical: result.x = origin.x
            case nil: break
            }
            return result
        }
    }
}
