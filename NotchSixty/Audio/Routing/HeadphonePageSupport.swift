import Foundation

// E13 S9 (`e13.headphones-page`): the pure parts of the cleaned-up Headphones page. Nothing here runs on an audio
// thread; the page's Swift state calls these on the main actor or a background task.

/// A bass shelf and a treble tilt applied on top of the chosen target, so a flat target can be shaped without a
/// target file. The shaped curve is what the fit uses and what the graph draws.
struct HeadphoneTargetShaping: Equatable, Sendable {
    static let shelfRangeDB = -6.0 ... 6.0
    static let tiltRangeDB = -6.0 ... 6.0
    /// The shelf corner and the tilt's pivot and end (the tilt is linear in log frequency between them).
    static let shelfCornerHz = 105.0
    static let tiltPivotHz = 1_000.0
    static let tiltEndHz = 10_000.0

    /// Boost (positive) or cut of the bass below about 105 Hz, in dB at 20 Hz.
    var bassShelfDB = 0.0
    /// Gain at 10 kHz and above, relative to 1 kHz and below (negative is darker).
    var trebleTiltDB = 0.0

    var isNeutral: Bool { bassShelfDB == 0 && trebleTiltDB == 0 }

    /// The shaping added to a target at one frequency, in dB. A first-order-style shelf: half its gain at the corner.
    func offsetDB(atHz hz: Double) -> Double {
        let f = max(hz, 1)
        let ratio = f / Self.shelfCornerHz
        let shelf = bassShelfDB / (1 + ratio * ratio)
        let span = log2(Self.tiltEndHz / Self.tiltPivotHz)
        let position = min(1, max(0, log2(f / Self.tiltPivotHz) / span))
        return shelf + trebleTiltDB * position
    }

    static let gridPointsPerOctave = 12.0

    /// The base target (nil is flat) plus the shaping on a log grid from 20 Hz to 20 kHz. Returns the base unchanged
    /// when the shaping is neutral, and nil only when both the base is nil and the shaping is neutral.
    static func shaped(base: RoomCorrectionTargetCurve?, shaping: HeadphoneTargetShaping) -> RoomCorrectionTargetCurve? {
        if shaping.isNeutral { return base }
        var points: [RoomCorrectionTargetPoint] = []
        var i = 0.0
        while true {
            let f = 20.0 * pow(2, i / gridPointsPerOctave)
            if f > 20_000 * (1 + 1e-9) { break }
            var base0 = 0.0
            if let base, base.points.count >= 2 {
                base0 = FrequencyResponseImporter.interpolate(base.points.map(\.frequencyHz), base.points.map(\.gainDB), at: f)
            }
            points.append(RoomCorrectionTargetPoint(frequencyHz: f, gainDB: base0 + shaping.offsetDB(atHz: f)))
            i += 1
        }
        let name = (base?.name ?? "Flat") + " (shaped)"
        return RoomCorrectionTargetCurve(id: base?.id ?? UUID(), name: name, points: points)
    }
}

/// What a file chosen in Fit and apply turned into.
enum HeadphoneImportOutcome: Sendable {
    /// A measured response (and the target that came with it, when it carried one).
    case response(HeadphoneResponseRecord, target: RoomCorrectionTargetCurve?)
    /// A ready-made set of EQ bands (the correction-proposal JSON); it is staged for review rather than fitted.
    case proposal(HeadphoneCorrectionProposal)
}

enum HeadphoneImportRouter {
    /// One entry point for every format: text (AutoEq CSV, REW, squig.link, FRD) and both JSON formats.
    static func importData(_ data: Data, name: String, sampleRate: Double) throws -> HeadphoneImportOutcome {
        let first = data.first(where: { !" \t\r\n".utf8.contains($0) })
        guard first == UInt8(ascii: "{") else {
            let curve = try FrequencyResponseImporter.parse(data, sourceName: name)
            return .response(try HeadphoneResponseRecord.make(from: [curve]), target: nil)
        }
        guard data.count <= 128_000 else { throw OptionalAcousticResearchError.excessiveFileSize }
        let decoder = JSONDecoder()
        if let model = try? decoder.decode(HeadphoneModelMeasurement.self, from: data) {
            try model.validate(sampleRate: sampleRate)
            return response(from: model)
        }
        let proposal = try decoder.decode(HeadphoneCorrectionProposal.self, from: data)
        try proposal.validate(sampleRate: sampleRate)
        return .proposal(proposal)
    }

    static func response(from model: HeadphoneModelMeasurement) -> HeadphoneImportOutcome {
        let (record, target) = HeadphoneResponseRecord.make(from: model)
        return .response(record, target: target)
    }
}

extension HeadphoneResponseRecord {
    /// A stored local-model measurement read as a response, with its explicit target points when any are not zero.
    static func make(from model: HeadphoneModelMeasurement) -> (HeadphoneResponseRecord, RoomCorrectionTargetCurve?) {
        let f = model.points.map(\.frequencyHz)
        let record = HeadphoneResponseRecord(
            id: model.id, name: model.headphoneModel,
            left: HeadphoneResponseCurve(frequenciesHz: f, db: model.points.map(\.leftMagnitudeDB)),
            right: HeadphoneResponseCurve(frequenciesHz: f, db: model.points.map(\.rightMagnitudeDB)),
            sourceName: model.sourceName, attribution: model.sourceAttribution, licence: model.sourceLicense)
        let hasTarget = model.points.contains { $0.targetMagnitudeDB != 0 }
        let target = hasTarget
            ? RoomCorrectionTargetCurve(
                name: model.headphoneModel + " target",
                points: model.points.map { RoomCorrectionTargetPoint(frequencyHz: $0.frequencyHz, gainDB: $0.targetMagnitudeDB) })
            : nil
        return (record, target)
    }
}

/// Automatic headroom: the conservative positive-gain allowance of the bands, rounded up to 0.5 dB like the fit's
/// recommendation, and clamped to the slider.
enum HeadphoneAutoHeadroom {
    static func headroomDB(for draft: HeadphoneDeviceProfileConfiguration) -> Double {
        min(30, HeadphoneAutoFitter.roundedUpHeadroom(draft.conservativeRequiredHeadroomDB))
    }
}

/// The three curves the page draws after a fit, on the fitting grid, in the level-referenced domain the fit used.
struct HeadphoneFitPreview: Sendable {
    var frequenciesHz: [Double]
    var responseLeftDB: [Double]
    var responseRightDB: [Double]
    var targetDB: [Double]
    var predictedLeftDB: [Double]
    var predictedRightDB: [Double]

    /// The imported response, the (shaped) target and the response after the draft's EQ bands.
    static func make(record: HeadphoneResponseRecord, target: RoomCorrectionTargetCurve?,
                     draft: HeadphoneDeviceProfileConfiguration, sampleRate: Double) throws -> HeadphoneFitPreview {
        let measurement = try record.measurement(target: target, sampleRate: sampleRate)
        let points = measurement.points
        func eq(_ bands: [HeadphoneCorrectionEQBand], _ hz: Double) -> Double {
            bands.filter(\.enabled).reduce(0.0) {
                $0 + (HeadphoneAutoFitter.bandMagnitudeDB($1, frequencyHz: hz, sampleRate: sampleRate) ?? 0)
            }
        }
        return HeadphoneFitPreview(
            frequenciesHz: points.map(\.frequencyHz),
            responseLeftDB: points.map(\.leftMagnitudeDB),
            responseRightDB: points.map(\.rightMagnitudeDB),
            targetDB: points.map(\.targetMagnitudeDB),
            predictedLeftDB: points.map { $0.leftMagnitudeDB + eq(draft.left.eqBands, $0.frequencyHz) },
            predictedRightDB: points.map { $0.rightMagnitudeDB + eq(draft.right.eqBands, $0.frequencyHz) })
    }
}

extension HeadphoneCrossfeedPreset {
    /// One line saying what the preset does (page wording).
    var summary: String {
        switch self {
        case .off: return "No blending between the ears."
        case .gentle: return "A little of each channel reaches the other ear; the closest to the original stereo image."
        case .standard: return "Speaker-like blending for a 30 degree speaker pair; the usual starting point."
        case .wide: return "Blends as if the speakers were 45 degrees apart, for a wider, more open image."
        case .custom: return "You choose how much, the speaker angle, the head size and the head-shadow frequency."
        }
    }
}
