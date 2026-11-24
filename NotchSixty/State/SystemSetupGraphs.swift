import Foundation

// E12 S30: the numbers behind the guided setup's graphs. Pure values: the flow model hands over what it already
// holds (seat measurements, the bass design, the correction's prediction, the verification report) and gets
// smoothed curves back. Smoothing is one sixth of an octave, so a curve reads the same at every device rate; the
// top of the range follows the rate (45 percent of the sample rate, at most 20 kHz).

/// Simple mode shows one smoothed curve per line of the story; expert mode adds one per seat.
enum SystemSetupGraphDetail: String, CaseIterable, Identifiable, Sendable {
    case simple, expert
    var id: String { rawValue }
    var title: String { self == .simple ? "Simple" : "Per seat" }
}

struct SystemSetupGraphCurve: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        /// What the microphone measured. `seat` is the seat's position in the list, for the colour.
        case measured(seat: Int)
        case target
        case predicted
        /// The level now (before the design) in the bass graph, one per seat in expert mode.
        case before
    }

    var id: String
    var label: String
    var role: Role
    var frequenciesHz: [Double]
    var levelsDB: [Double]
}

struct SystemSetupGraph: Equatable, Sendable {
    enum Kind: String, Sendable { case measure, bass, correction, verify }

    var kind: Kind
    var title: String
    var caption: String
    var curves: [SystemSetupGraphCurve]
    var lowHz: Double
    var highHz: Double
    /// True when expert mode would add curves (so the panel offers the switch).
    var hasSeatDetail: Bool

    /// The vertical range the picture needs: the curves' span padded to whole 5 dB steps, at least 20 dB tall.
    var levelRangeDB: ClosedRange<Double> {
        let all = curves.flatMap(\.levelsDB).filter(\.isFinite)
        guard let low = all.min(), let high = all.max() else { return -10...10 }
        var lower = (low / 5).rounded(.down) * 5
        var upper = (high / 5).rounded(.up) * 5
        if upper - lower < 20 {
            let mid = (upper + lower) / 2
            lower = mid - 10
            upper = mid + 10
        }
        return lower...upper
    }
}

enum SystemSetupGraphBuilder {
    static let bandsPerOctave = 6.0
    static let displayLowHz = 20.0
    static let displayHighHz = 20_000.0
    /// Where the level of a response is read from, so curves with arbitrary microphone gain sit on one baseline.
    static let referenceBandHz = 200.0...2_000.0
    static let bassHighHz = 250.0

    // MARK: Smoothing

    /// Band centres from `lowHz` to the lower of `highHz` and 45 percent of the sample rate, `perOctave` per octave.
    static func centres(sampleRate: Double, lowHz: Double = displayLowHz, highHz: Double = displayHighHz,
                        perOctave: Double = bandsPerOctave) -> [Double] {
        let top = min(highHz, sampleRate * 0.45)
        guard lowHz > 0, top > lowHz, perOctave > 0 else { return [] }
        var result: [Double] = []
        var index = 0.0
        while true {
            let value = lowHz * pow(2, index / perOctave)
            if value > top * 1.0001 { break }
            result.append(value)
            index += 1
        }
        return result
    }

    /// The response averaged (in power) over one band either side of each centre. A band with no point inside takes
    /// the log-frequency interpolation between its neighbours; a band outside the data is `nan` (left off the curve).
    static func bands(frequenciesHz: [Double], magnitudeDB: [Double], centres: [Double], perOctave: Double = bandsPerOctave) -> [Double] {
        let count = min(frequenciesHz.count, magnitudeDB.count)
        var points: [(f: Double, db: Double)] = []
        points.reserveCapacity(count)
        for index in 0..<count where frequenciesHz[index] > 0 && frequenciesHz[index].isFinite && magnitudeDB[index].isFinite {
            points.append((frequenciesHz[index], magnitudeDB[index]))
        }
        points.sort { $0.f < $1.f }
        guard !points.isEmpty else { return centres.map { _ in .nan } }
        let half = pow(2, 0.5 / perOctave)
        var lowerIndex = 0
        return centres.map { centre in
            let lower = centre / half, upper = centre * half
            while lowerIndex < points.count, points[lowerIndex].f < lower { lowerIndex += 1 }
            var sum = 0.0, number = 0
            var cursor = lowerIndex
            while cursor < points.count, points[cursor].f <= upper {
                sum += pow(10, points[cursor].db / 10)
                number += 1
                cursor += 1
            }
            if number > 0 { return 10 * log10(sum / Double(number)) }
            guard let after = points.firstIndex(where: { $0.f > upper }), after > 0 else { return .nan }
            let a = points[after - 1], b = points[after]
            let t = log(centre / a.f) / log(b.f / a.f)
            return a.db + (b.db - a.db) * t
        }
    }

    /// The mean of the finite values whose centre lies in `range`; nil when there are none.
    static func mean(_ values: [Double], centres: [Double], in range: ClosedRange<Double>) -> Double? {
        var sum = 0.0, number = 0
        for (index, centre) in centres.enumerated() where range.contains(centre) && values[index].isFinite {
            sum += values[index]
            number += 1
        }
        return number > 0 ? sum / Double(number) : nil
    }

    /// Mean in dB of several band arrays, skipping missing bands; nan where none has a value.
    static func average(_ arrays: [[Double]]) -> [Double] {
        guard let count = arrays.map(\.count).min(), count > 0 else { return [] }
        return (0..<count).map { index in
            let finite = arrays.map { $0[index] }.filter(\.isFinite)
            return finite.isEmpty ? .nan : finite.reduce(0, +) / Double(finite.count)
        }
    }

    private static func curve(
        id: String, label: String, role: SystemSetupGraphCurve.Role, centres: [Double], levels: [Double], offset: Double = 0
    ) -> SystemSetupGraphCurve? {
        var f: [Double] = [], l: [Double] = []
        for (index, centre) in centres.enumerated() where index < levels.count && levels[index].isFinite {
            f.append(centre)
            l.append(levels[index] - offset)
        }
        guard f.count >= 2 else { return nil }
        return SystemSetupGraphCurve(id: id, label: label, role: role, frequenciesHz: f, levelsDB: l)
    }

    // MARK: Seat responses

    struct SeatResponse: Equatable, Sendable {
        var name: String
        var bandsDB: [Double]
    }

    /// Each included seat's response: its speakers' transfer functions smoothed and averaged in dB. Seats with no
    /// usable transfer function are left out.
    static func seatResponses(
        seats: [MultichannelCalibrationSeat], measurements: [MultichannelCalibrationMeasurement], centres: [Double]
    ) -> [SeatResponse] {
        seats.filter { $0.included && $0.weight > 0 }.compactMap { seat in
            var perSource: [MultichannelCalibrationSource: [Double]] = [:]
            for measurement in measurements where measurement.seatID == seat.id {
                guard case .speaker = measurement.source, let tf = measurement.channel.transferFunction else { continue }
                perSource[measurement.source] = bands(frequenciesHz: tf.frequenciesHz, magnitudeDB: tf.magnitudeDB, centres: centres)
            }
            let combined = average(Array(perSource.values))
            guard combined.contains(where: \.isFinite) else { return nil }
            return SeatResponse(name: seat.name, bandsDB: combined)
        }
    }

    // MARK: Measure

    static func measure(
        seats: [MultichannelCalibrationSeat], measurements: [MultichannelCalibrationMeasurement],
        sampleRate: Double, detail: SystemSetupGraphDetail
    ) -> SystemSetupGraph? {
        let centres = centres(sampleRate: sampleRate)
        let responses = seatResponses(seats: seats, measurements: measurements, centres: centres)
        guard let main = responses.first else { return nil }
        let offset = mean(main.bandsDB, centres: centres, in: referenceBandHz) ?? 0
        let shown = detail == .expert ? responses : [main]
        let curves = shown.enumerated().compactMap { index, seat in
            curve(id: "seat-\(index)", label: detail == .expert ? seat.name : "\(seat.name) (main seat)",
                  role: .measured(seat: index), centres: centres, levels: seat.bandsDB, offset: offset)
        }
        guard !curves.isEmpty else { return nil }
        return SystemSetupGraph(
            kind: .measure, title: "What the microphone heard",
            caption: "The smoothed response of your speakers at the seat, level set to 0 dB at the middle of the range. Peaks are too loud, dips too quiet.",
            curves: curves, lowHz: displayLowHz, highHz: centres.last ?? displayHighHz, hasSeatDetail: responses.count > 1)
    }

    // MARK: Bass

    static func bass(
        design: SystemSetupBassDesign, gridFrequenciesHz: [Double], sampleRate: Double, detail: SystemSetupGraphDetail
    ) -> SystemSetupGraph? {
        guard design.mode == .jointOptimised, let optimisation = design.optimisation, !design.seatNames.isEmpty else { return nil }
        let seatCount = design.seatNames.count
        let grid = gridFrequenciesHz.count
        guard grid > 1, optimisation.beforeDB.count == seatCount * grid, optimisation.afterDB.count == seatCount * grid else { return nil }
        let centres = centres(sampleRate: sampleRate, lowHz: SystemSetupBassDesign.fitLowHz, highHz: bassHighHz, perOctave: 12)
        func seatBands(_ values: [Double], _ seat: Int) -> [Double] {
            bands(frequenciesHz: gridFrequenciesHz, magnitudeDB: Array(values[(seat * grid)..<((seat + 1) * grid)]),
                  centres: centres, perOctave: 12)
        }
        let before = (0..<seatCount).map { seatBands(optimisation.beforeDB, $0) }
        let after = (0..<seatCount).map { seatBands(optimisation.afterDB, $0) }
        var curves: [SystemSetupGraphCurve] = []
        if detail == .expert {
            for seat in 0..<seatCount {
                curves.append(contentsOf: [
                    curve(id: "before-\(seat)", label: "\(design.seatNames[seat]) now", role: .before, centres: centres, levels: before[seat]),
                    curve(id: "after-\(seat)", label: "\(design.seatNames[seat]) predicted", role: .predicted, centres: centres, levels: after[seat])
                ].compactMap { $0 })
            }
        } else {
            curves = [
                curve(id: "before", label: "Now (average of your seats)", role: .before, centres: centres, levels: average(before)),
                curve(id: "after", label: "Predicted (average of your seats)", role: .predicted, centres: centres, levels: average(after))
            ].compactMap { $0 }
        }
        guard !curves.isEmpty else { return nil }
        return SystemSetupGraph(
            kind: .bass, title: "Bass now and predicted",
            caption: "Predicted bass at each seat, 20 to 250 Hz. The closer the seats' lines sit together, the more even the bass is around the room.",
            curves: curves, lowHz: SystemSetupBassDesign.fitLowHz, highHz: bassHighHz, hasSeatDetail: seatCount > 1)
    }

    // MARK: Correction

    /// What the Correction step predicts, in the form the path that applied it produced.
    enum CorrectionPrediction: Equatable, Sendable {
        /// The lane design's correction grids (dB over `frequenciesHz`, one array per front lane); predicted = measured + mean correction.
        case grids(frequenciesHz: [Double], correctionDB: [[Double]])
        /// The stereo filter's own predicted and measured aggregate responses.
        case responses(predicted: RoomCorrectionFrequencyResponse, measured: RoomCorrectionFrequencyResponse)
    }

    static func correction(
        seats: [MultichannelCalibrationSeat], measurements: [MultichannelCalibrationMeasurement],
        target: RoomCorrectionTargetCurve?, prediction: CorrectionPrediction?, sampleRate: Double, detail: SystemSetupGraphDetail
    ) -> SystemSetupGraph? {
        let centres = centres(sampleRate: sampleRate)
        let responses = seatResponses(seats: seats, measurements: measurements, centres: centres)
        var measured: [Double]
        var predicted: [Double]?
        switch prediction {
        case .responses(let predictedResponse, let measuredResponse)?:
            measured = bands(frequenciesHz: measuredResponse.frequenciesHz, magnitudeDB: measuredResponse.magnitudeDB, centres: centres)
            predicted = bands(frequenciesHz: predictedResponse.frequenciesHz, magnitudeDB: predictedResponse.magnitudeDB, centres: centres)
        case .grids(let frequencies, let corrections)?:
            measured = average(responses.map(\.bandsDB))
            let applied = average(corrections.map { bands(frequenciesHz: frequencies, magnitudeDB: $0, centres: centres) })
            predicted = applied.count == measured.count ? zip(measured, applied).map { $0 + ($1.isFinite ? $1 : 0) } : nil
        case nil:
            measured = average(responses.map(\.bandsDB))
        }
        guard measured.contains(where: \.isFinite) else { return nil }
        let offset = mean(measured, centres: centres, in: referenceBandHz) ?? 0
        var curves: [SystemSetupGraphCurve] = []
        if detail == .expert {
            for (index, seat) in responses.enumerated() {
                if let c = curve(id: "seat-\(index)", label: seat.name, role: .measured(seat: index), centres: centres, levels: seat.bandsDB, offset: offset) {
                    curves.append(c)
                }
            }
        } else if let c = curve(id: "measured", label: "Measured", role: .measured(seat: 0), centres: centres, levels: measured, offset: offset) {
            curves.append(c)
        }
        if let target {
            let shape = bands(frequenciesHz: target.points.map(\.frequencyHz), magnitudeDB: target.points.map(\.gainDB), centres: centres)
            let shapeOffset = mean(shape, centres: centres, in: referenceBandHz) ?? 0
            if let c = curve(id: "target", label: "Target", role: .target, centres: centres, levels: shape, offset: shapeOffset) { curves.append(c) }
        }
        if let predicted, let c = curve(id: "predicted", label: "Predicted", role: .predicted, centres: centres, levels: predicted, offset: offset) {
            curves.append(c)
        }
        return SystemSetupGraph(
            kind: .correction, title: "Measured, target and predicted",
            caption: "Where your room is now, the sound you chose, and where the correction should bring it. The predicted line should sit close to the target.",
            curves: curves, lowHz: displayLowHz, highHz: centres.last ?? displayHighHz, hasSeatDetail: responses.count > 1)
    }

    // MARK: Verify

    static func verify(report: SystemSetupVerificationReport) -> SystemSetupGraph? {
        guard let centres = report.centresHz, let predicted = report.predictedDB, let measured = report.measuredDB,
              centres.count == predicted.count, centres.count == measured.count else { return nil }
        let curves = [
            curve(id: "predicted", label: "Predicted", role: .predicted, centres: centres, levels: predicted),
            curve(id: "measured", label: "Measured with the correction on", role: .measured(seat: 0), centres: centres, levels: measured)
        ].compactMap { $0 }
        guard curves.count == 2 else { return nil }
        return SystemSetupGraph(
            kind: .verify, title: "Predicted against measured",
            caption: "The check measures your main seat once with the correction on. The two lines should follow each other.",
            curves: curves, lowHz: centres.first ?? displayLowHz, highHz: centres.last ?? displayHighHz, hasSeatDetail: false)
    }
}
