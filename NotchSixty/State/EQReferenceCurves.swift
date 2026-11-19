import Foundation

/// E33 S19 (G37): read-only curves drawn behind the Equalizer bands: the saved measurement at the main seat
/// (before and after correction) and the correction target. They are pictures only. Nothing here reaches the EQ
/// bands, the headroom badge or auto preamp.
enum EQReferenceCurveKind: String, CaseIterable, Identifiable, Sendable {
    case measurement
    case corrected
    case target

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .measurement: return "Measurement (before)"
        case .corrected: return "Measurement (after correction)"
        case .target: return "Correction target"
        }
    }
}

struct EQReferenceCurve: Equatable, Sendable, Identifiable {
    let kind: EQReferenceCurveKind
    let frequenciesHz: [Double]
    /// Relative gain in dB. Measured curves are shown relative to their own 500 Hz to 2 kHz level, so they sit on the
    /// graph's 0 dB axis; the target is already relative and is shown as stored.
    let gainDB: [Double]
    /// When the curve was made; nil when the store holds no date for it.
    let date: Date?
    /// The curve is older than the reference age limit, or the measurement it was predicted from has been replaced.
    let isOutOfDate: Bool

    var id: EQReferenceCurveKind { kind }

    var label: String {
        guard let date else { return kind.displayName }
        let text = date.formatted(date: .abbreviated, time: .omitted)
        return "\(kind.displayName), \(text)\(isOutOfDate ? ", out of date" : "")"
    }
}

/// The one seam between the page and wherever the curves are stored. E29 swaps its shared store in here.
protocol EQReferenceCurveSource {
    func referenceCurves(now: Date) -> [EQReferenceCurve]
}

/// Reads the saved Room Correction project: the first included measurement position is the main seat.
struct RoomCorrectionReferenceCurveSource: EQReferenceCurveSource {
    var project: RoomCorrectionProject?
    /// A measurement older than this reads as out of date.
    static let maximumAge: TimeInterval = 30 * 24 * 3_600

    func referenceCurves(now: Date = Date()) -> [EQReferenceCurve] {
        guard let project else { return [] }
        var curves: [EQReferenceCurve] = []
        let seat = project.measurements.first { $0.included }
        var seatDate: Date?
        if let seat, let response = seat.left.transferFunction, Self.isUsable(response) {
            seatDate = seat.left.capturedAt
            curves.append(EQReferenceCurve(
                kind: .measurement,
                frequenciesHz: response.frequenciesHz,
                gainDB: Self.relative(response),
                date: seat.left.capturedAt,
                isOutOfDate: now.timeIntervalSince(seat.left.capturedAt) > Self.maximumAge))
        }
        if let design = project.designs.first(where: { $0.id == project.selectedDesignID }),
           let predicted = design.predictedLeftResponse, Self.isUsable(predicted) {
            // A design made before the seat was measured again describes a room that has changed.
            let replaced = seatDate.map { design.createdAt < $0 } ?? false
            curves.append(EQReferenceCurve(
                kind: .corrected,
                frequenciesHz: predicted.frequenciesHz,
                gainDB: Self.relative(predicted),
                date: design.createdAt,
                isOutOfDate: replaced || now.timeIntervalSince(design.createdAt) > Self.maximumAge))
        }
        if let target = project.target, target.points.count > 1 {
            let points = target.points.sorted { $0.frequencyHz < $1.frequencyHz }
            let date = project.designs.first(where: { $0.target == target })?.createdAt
            curves.append(EQReferenceCurve(
                kind: .target,
                frequenciesHz: points.map(\.frequencyHz),
                gainDB: points.map(\.gainDB),
                date: date,
                isOutOfDate: false))
        }
        return curves
    }

    private static func isUsable(_ response: RoomCorrectionFrequencyResponse) -> Bool {
        response.frequenciesHz.count > 1
            && response.frequenciesHz.count == response.magnitudeDB.count
            && response.frequenciesHz.allSatisfy { $0.isFinite && $0 > 0 }
            && response.magnitudeDB.allSatisfy(\.isFinite)
    }

    /// The stored response minus its mean level from 500 Hz to 2 kHz (the whole response when it has no point there).
    static func relative(_ response: RoomCorrectionFrequencyResponse) -> [Double] {
        let inBand = zip(response.frequenciesHz, response.magnitudeDB).filter { $0.0 >= 500 && $0.0 <= 2_000 }
        let pool = inBand.isEmpty ? Array(response.magnitudeDB) : inBand.map(\.1)
        let mean = pool.reduce(0, +) / Double(pool.count)
        return response.magnitudeDB.map { $0 - mean }
    }
}

/// Which reference curves the user chose to show. Stored as a comma list of raw kinds.
enum EQReferenceSelection {
    static let preferenceKey = "equalizer.referenceCurves"

    static func kinds(from raw: String) -> Set<EQReferenceCurveKind> {
        Set(raw.split(separator: ",").compactMap { EQReferenceCurveKind(rawValue: String($0)) })
    }

    static func raw(from kinds: Set<EQReferenceCurveKind>) -> String {
        EQReferenceCurveKind.allCases.filter { kinds.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    /// The curves to draw: chosen and available, in a fixed order.
    static func visible(_ curves: [EQReferenceCurve], chosen: Set<EQReferenceCurveKind>) -> [EQReferenceCurve] {
        curves.filter { chosen.contains($0.kind) }
    }
}
