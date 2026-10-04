import Foundation

struct MultichannelCalibrationSeat: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var included = true
    var weight = 1.0
}

enum MultichannelCalibrationSource: Codable, Equatable, Hashable, Sendable {
    case speaker(OutputProgramRole)
    case subwoofer(UInt32)

    var displayName: String {
        switch self {
        case .speaker(let role): return role.displayName
        case .subwoofer(let index): return "Sub \(index + 1)"
        }
    }
}

struct MultichannelCalibrationMeasurement: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var seatID: UUID
    var source: MultichannelCalibrationSource
    var sampleRate: Double
    var channel: RoomCorrectionChannelMeasurement
}

struct MultichannelSpeakerDesign: Equatable, Sendable {
    var role: OutputProgramRole
    var calibration: SemanticSpeakerCalibration
    var errorBeforeDB: Double
    var errorAfterDB: Double
    var seatVarianceDBSquared: Double
}

struct MultichannelSubwooferDesign: Equatable, Sendable {
    var index: UInt32
    var calibration: PhysicalSubwooferCalibration
}

struct MultichannelCalibrationDesign: Equatable, Sendable {
    var sampleRate: Double
    var speakers: [MultichannelSpeakerDesign]
    var subwoofers: [MultichannelSubwooferDesign]
    var summary: MultichannelCalibrationDeploymentSummary

    func applying(to profile: OutputDeviceProfileConfiguration) throws -> OutputDeviceProfileConfiguration {
        var updated = profile
        for speaker in speakers {
            guard let index = updated.speakerAssignments.firstIndex(where: { $0.role == speaker.role }) else {
                throw OutputDeviceCalibrationError.speakerAssignmentUnavailable(speaker.role)
            }
            updated.speakerAssignments[index].calibration = speaker.calibration
        }
        for subwoofer in subwoofers {
            guard let index = updated.subwooferAssignments.firstIndex(where: { $0.index == subwoofer.index }) else {
                throw OutputDeviceCalibrationError.subwooferAssignmentUnavailable(subwoofer.index)
            }
            updated.subwooferAssignments[index].calibration = subwoofer.calibration
        }
        updated.calibrationSummary = summary
        return updated
    }
}

struct MultichannelCalibrationDesigner: Sendable {
    static let frequencyBinCount = Int(N60_CALIBRATION_MAX_FREQUENCY_BINS)
    static let minimumFrequencyHz = 20.0
    static let nominalMaximumFrequencyHz = 20_000.0
    static let subwooferMaximumFrequencyHz = 300.0

    func design(
        profile: OutputDeviceProfileConfiguration,
        bassManagementEnabled: Bool,
        seats: [MultichannelCalibrationSeat],
        measurements: [MultichannelCalibrationMeasurement],
        sampleRate: Double,
        target: RoomCorrectionTargetCurve? = nil,
        measuredAt: Date = Date(),
        deployedAt: Date = Date()
    ) throws -> MultichannelCalibrationDesign {
        guard profile.enabled else { throw OutputDeviceCalibrationError.profileRequired }
        try profile.validateStructure(bassManagementEnabled: bassManagementEnabled)
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw OutputDeviceCalibrationError.designFailed("invalid sample rate")
        }

        let includedSeats = seats.filter { $0.included && $0.weight > 0 }
        guard !includedSeats.isEmpty, includedSeats.count <= Int(N60_CALIBRATION_MAX_SEATS) else {
            throw OutputDeviceCalibrationError.designFailed("select between 1 and \(Int(N60_CALIBRATION_MAX_SEATS)) weighted seats")
        }
        guard includedSeats.allSatisfy({ $0.weight.isFinite && $0.weight > 0 }) else {
            throw OutputDeviceCalibrationError.designFailed("seat weights must be finite and positive")
        }

        let frequencies = Self.logFrequencyGrid(
            minimumHz: Self.minimumFrequencyHz,
            maximumHz: min(Self.nominalMaximumFrequencyHz, sampleRate * 0.48),
            count: Self.frequencyBinCount
        )
        var matrix = frequencies.withUnsafeBufferPointer { buffer in
            N60MultichannelCalibrationMatrixMake(
                sampleRate,
                profile.programLayout.realtimeLayout,
                UInt32(profile.subwooferAssignments.count),
                UInt32(includedSeats.count),
                buffer.baseAddress,
                UInt32(buffer.count)
            )
        }
        guard matrix.sourceCount > 0 else {
            throw OutputDeviceCalibrationError.designFailed("calibration matrix could not be created")
        }

        for (seatIndex, seat) in includedSeats.enumerated() {
            guard N60MultichannelCalibrationSetSeat(
                &matrix,
                UInt32(seatIndex),
                true,
                Float(seat.weight)
            ) else {
                throw OutputDeviceCalibrationError.designFailed("seat weighting could not be compiled")
            }
        }

        for (seatIndex, seat) in includedSeats.enumerated() {
            for role in profile.programLayout.roles where role != .lowFrequencyEffects {
                let measurement = try measurement(
                    seatID: seat.id,
                    source: .speaker(role),
                    measurements: measurements,
                    expectedSampleRate: sampleRate
                )
                let sourceIndex = N60MultichannelCalibrationSourceIndexForRole(
                    &matrix,
                    role.realtimeCType
                )
                guard sourceIndex >= 0 else {
                    throw OutputDeviceCalibrationError.designFailed("missing matrix source for \(role.displayName)")
                }
                try install(
                    measurement: measurement,
                    frequencies: frequencies,
                    sourceIndex: UInt32(sourceIndex),
                    seatIndex: UInt32(seatIndex),
                    into: &matrix
                )
            }
            for sub in profile.subwooferAssignments.sorted(by: { $0.index < $1.index }) {
                let measurement = try measurement(
                    seatID: seat.id,
                    source: .subwoofer(sub.index),
                    measurements: measurements,
                    expectedSampleRate: sampleRate
                )
                let sourceIndex = N60MultichannelCalibrationSourceIndexForSubwoofer(&matrix, sub.index)
                guard sourceIndex >= 0 else {
                    throw OutputDeviceCalibrationError.designFailed("missing matrix source for Sub \(sub.index + 1)")
                }
                try install(
                    measurement: measurement,
                    frequencies: frequencies,
                    sourceIndex: UInt32(sourceIndex),
                    seatIndex: UInt32(seatIndex),
                    into: &matrix
                )
            }
        }

        guard N60MultichannelCalibrationMatrixIsValid(
            &matrix,
            UInt32(profile.subwooferAssignments.count)
        ) else {
            throw OutputDeviceCalibrationError.designFailed("measurement matrix is incomplete")
        }

        var alignment = N60SpeakerAlignmentPlan()
        guard N60MultichannelCalibrationMakeSpeakerAlignmentPlan(&matrix, &alignment) else {
            throw OutputDeviceCalibrationError.designFailed("speaker time/level alignment failed")
        }

        let targetMagnitude = frequencies.map {
            Float(alignment.commonLevelDB) + Float(Self.targetGainDB(target, at: Double($0)))
        }
        var correctionSettings = N60SpeakerCorrectionSettingsMakeDefault()
        correctionSettings.maximumBoostDB = 0
        correctionSettings.maximumCutDB = 10
        correctionSettings.maximumBandCount = min(
            UInt32(SemanticSpeakerCalibration.maximumEQBandCount),
            UInt32(N60_SPEAKER_CORRECTION_MAX_BANDS)
        )

        var speakerPlan = N60SpeakerCorrectionPlan()
        let speakerDesigned = targetMagnitude.withUnsafeBufferPointer { targetBuffer in
            N60SpeakerCorrectionDesignPlan(
                &matrix,
                targetBuffer.baseAddress,
                correctionSettings,
                &speakerPlan
            )
        }
        guard speakerDesigned else {
            throw OutputDeviceCalibrationError.designFailed("bounded speaker PEQ design failed")
        }

        var subResult: N60MultiSubOptimizationResult?
        if bassManagementEnabled, !profile.subwooferAssignments.isEmpty {
            var settings = N60MultiSubOptimizationSettingsMakeDefault()
            settings.maximumGainDB = 0
            settings.minimumGainDB = -12
            settings.maximumEQDB = 0
            settings.minimumEQDB = -8
            var result = N60MultiSubOptimizationResult()
            let optimized = targetMagnitude.withUnsafeBufferPointer { targetBuffer in
                N60MultiSubOptimize(
                    &matrix,
                    UInt32(profile.subwooferAssignments.count),
                    targetBuffer.baseAddress,
                    settings,
                    &result
                )
            }
            guard optimized else {
                throw OutputDeviceCalibrationError.designFailed("multi-sub optimization failed")
            }
            subResult = result
        }

        let timing = try makeTimingOffsets(
            matrix: &matrix,
            alignment: alignment,
            subResult: subResult,
            subwooferCount: profile.subwooferAssignments.count,
            sampleRate: sampleRate
        )
        let speakers = try materializeSpeakerDesigns(
            plan: &speakerPlan,
            sampleRate: sampleRate,
            commonDelayMilliseconds: timing.speakerCommonDelayMilliseconds
        )
        let subwoofers = try materializeSubwooferDesigns(
            result: subResult,
            matrix: &matrix,
            frequencies: frequencies,
            count: profile.subwooferAssignments.count,
            commonDelayMilliseconds: timing.subwooferCommonDelayMilliseconds,
            sampleRate: sampleRate
        )

        let maximumBefore = speakers.map(\.errorBeforeDB).max()
        let maximumAfter = speakers.map(\.errorAfterDB).max()
        let summary = MultichannelCalibrationDeploymentSummary(
            measuredAt: measuredAt,
            deployedAt: deployedAt,
            seatCount: includedSeats.count,
            speakerCount: speakers.count,
            subwooferCount: subwoofers.count,
            targetName: target?.name ?? "Neutral",
            sampleRate: sampleRate,
            maximumSpeakerErrorBeforeDB: maximumBefore,
            maximumSpeakerErrorAfterDB: maximumAfter,
            multiSubObjective: subResult.map { Double($0.objective) }
        )
        try summary.validate()
        return MultichannelCalibrationDesign(
            sampleRate: sampleRate,
            speakers: speakers,
            subwoofers: subwoofers,
            summary: summary
        )
    }

    private func measurement(
        seatID: UUID,
        source: MultichannelCalibrationSource,
        measurements: [MultichannelCalibrationMeasurement],
        expectedSampleRate: Double
    ) throws -> MultichannelCalibrationMeasurement {
        guard let result = measurements.last(where: { $0.seatID == seatID && $0.source == source }) else {
            throw OutputDeviceCalibrationError.designFailed("missing \(source.displayName) measurement")
        }
        guard result.sampleRate.isFinite,
              abs(result.sampleRate - expectedSampleRate) < 0.5 else {
            throw OutputDeviceCalibrationError.sampleRateMismatch(
                expected: expectedSampleRate,
                actual: result.sampleRate
            )
        }
        return result
    }

    private func install(
        measurement: MultichannelCalibrationMeasurement,
        frequencies: [Float],
        sourceIndex: UInt32,
        seatIndex: UInt32,
        into matrix: inout N60MultichannelCalibrationMatrix
    ) throws {
        guard let response = measurement.channel.transferFunction,
              let arrivalSeconds = measurement.channel.quality.directArrivalSeconds,
              arrivalSeconds.isFinite,
              arrivalSeconds >= 0 else {
            throw OutputDeviceCalibrationError.designFailed("\(measurement.source.displayName) lacks analyzed transfer data")
        }
        let directArrivalFrameDouble = arrivalSeconds * measurement.sampleRate
        guard directArrivalFrameDouble.isFinite,
              directArrivalFrameDouble >= 0,
              directArrivalFrameDouble <= Double(UInt32.max) else {
            throw OutputDeviceCalibrationError.designFailed("direct-arrival timing is invalid")
        }
        let directArrivalFrame = UInt32(directArrivalFrameDouble.rounded())
        let directPolarity = Self.directPolarity(
            impulse: measurement.channel.impulseResponse,
            arrivalFrame: Int(directArrivalFrame)
        )
        let magnitude = try frequencies.map { frequency in
            Float(try Self.interpolate(response.magnitudeDB, response: response, at: Double(frequency)))
        }
        let phase = try frequencies.map { frequency in
            guard let phases = response.phaseRadians else {
                throw OutputDeviceCalibrationError.designFailed("phase data is required for multichannel calibration")
            }
            return Float(try Self.interpolate(phases, response: response, at: Double(frequency)))
        }
        let broadband = Self.broadbandLevelDB(
            frequencies: frequencies,
            magnitudes: magnitude,
            source: measurement.source
        )
        let installed = magnitude.withUnsafeBufferPointer { magnitudeBuffer in
            phase.withUnsafeBufferPointer { phaseBuffer in
                N60MultichannelCalibrationSetResponse(
                    &matrix,
                    sourceIndex,
                    seatIndex,
                    directArrivalFrame,
                    directPolarity,
                    broadband,
                    magnitudeBuffer.baseAddress!,
                    phaseBuffer.baseAddress!
                )
            }
        }
        guard installed else {
            throw OutputDeviceCalibrationError.designFailed("measurement response could not be added to the calibration matrix")
        }
    }

    private func materializeSpeakerDesigns(
        plan: inout N60SpeakerCorrectionPlan,
        sampleRate: Double,
        commonDelayMilliseconds: Double
    ) throws -> [MultichannelSpeakerDesign] {
        var result: [MultichannelSpeakerDesign] = []
        result.reserveCapacity(Int(plan.sourceCount))
        try withUnsafePointer(to: &plan.sources) { tuple in
            try tuple.withMemoryRebound(
                to: N60SpeakerCorrectionSourceDesign.self,
                capacity: Int(N60_MAX_PROGRAM_CHANNELS)
            ) { sources in
                for index in 0..<Int(plan.sourceCount) {
                    let source = sources[index]
                    guard source.valid,
                          let role = OutputProgramRole(realtimeRole: source.role) else {
                        throw OutputDeviceCalibrationError.designFailed("speaker design contains an unknown semantic role")
                    }
                    var bands: [OutputCalibrationEQBand] = []
                    try withUnsafePointer(to: source.bands) { bandTuple in
                        try bandTuple.withMemoryRebound(
                            to: N60BiquadBandSnapshot.self,
                            capacity: Int(N60_SPEAKER_CORRECTION_MAX_BANDS)
                        ) { cBands in
                            for bandIndex in 0..<Int(source.bandCount) {
                                let band = cBands[bandIndex]
                                guard band.enabled else { continue }
                                let output = OutputCalibrationEQBand(
                                    frequencyHz: band.frequencyHz,
                                    gainDB: min(0, Double(band.gainDB)),
                                    q: band.q
                                )
                                try output.validate(sampleRate: sampleRate)
                                bands.append(output)
                            }
                        }
                    }
                    let delayMilliseconds = Double(source.delayFrames) / sampleRate * 1_000.0
                        + commonDelayMilliseconds
                    let calibration = SemanticSpeakerCalibration(
                        trimDB: min(0, Double(source.trimDB)),
                        delayMilliseconds: delayMilliseconds,
                        polarityInverted: source.polarityInverted,
                        eqBands: bands
                    )
                    try calibration.validate(sampleRate: sampleRate)
                    result.append(MultichannelSpeakerDesign(
                        role: role,
                        calibration: calibration,
                        errorBeforeDB: Double(source.preCorrectionRMSErrorDB),
                        errorAfterDB: Double(source.postCorrectionRMSErrorDB),
                        seatVarianceDBSquared: Double(source.seatVarianceDBSquared)
                    ))
                }
            }
        }
        return result
    }

    private func materializeSubwooferDesigns(
        result: N60MultiSubOptimizationResult?,
        matrix: inout N60MultichannelCalibrationMatrix,
        frequencies: [Float],
        count: Int,
        commonDelayMilliseconds: Double,
        sampleRate: Double
    ) throws -> [MultichannelSubwooferDesign] {
        guard count > 0 else { return [] }
        guard var result else {
            return (0..<count).map {
                MultichannelSubwooferDesign(index: UInt32($0), calibration: PhysicalSubwooferCalibration())
            }
        }

        var gains = [Float](repeating: 0, count: count)
        var delays = [Float](repeating: 0, count: count)
        var polarities = [Bool](repeating: false, count: count)
        withUnsafePointer(to: &result.gainDB) { tuple in
            tuple.withMemoryRebound(to: Float.self, capacity: Int(N60_MAX_SUBWOOFER_OUTPUTS)) {
                for index in 0..<count { gains[index] = $0[index] }
            }
        }
        withUnsafePointer(to: &result.additionalDelayMs) { tuple in
            tuple.withMemoryRebound(to: Float.self, capacity: Int(N60_MAX_SUBWOOFER_OUTPUTS)) {
                for index in 0..<count { delays[index] = $0[index] }
            }
        }
        withUnsafePointer(to: &result.polarityInverted) { tuple in
            tuple.withMemoryRebound(to: Bool.self, capacity: Int(N60_MAX_SUBWOOFER_OUTPUTS)) {
                for index in 0..<count { polarities[index] = $0[index] }
            }
        }

        // Preserve optimizer-relative gains but never deploy positive digital gain.
        let loudest = gains.max() ?? 0
        if loudest < 0 {
            for index in gains.indices { gains[index] -= loudest }
        }

        var designs: [MultichannelSubwooferDesign] = []
        for sub in 0..<count {
            let eqTarget = Self.subwooferEQTarget(result: &result, subwooferIndex: sub)
            let eqBands = Self.fitAttenuationOnlySubwooferEQ(
                frequencies: frequencies,
                targetDB: eqTarget
            )
            let calibration = PhysicalSubwooferCalibration(
                gainDB: min(0, Double(gains[sub])),
                delayMilliseconds: max(0, Double(delays[sub]) + commonDelayMilliseconds),
                polarityInverted: polarities[sub],
                eqBands: eqBands
            )
            try calibration.validate(sampleRate: sampleRate)
            designs.append(MultichannelSubwooferDesign(index: UInt32(sub), calibration: calibration))
        }
        return designs
    }

    private func makeTimingOffsets(
        matrix: inout N60MultichannelCalibrationMatrix,
        alignment: N60SpeakerAlignmentPlan,
        subResult: N60MultiSubOptimizationResult?,
        subwooferCount: Int,
        sampleRate: Double
    ) throws -> (speakerCommonDelayMilliseconds: Double, subwooferCommonDelayMilliseconds: Double) {
        guard subwooferCount > 0, var subResult else { return (0, 0) }
        var additionalDelays = [Float](repeating: 0, count: subwooferCount)
        withUnsafePointer(to: &subResult.additionalDelayMs) { tuple in
            tuple.withMemoryRebound(to: Float.self, capacity: Int(N60_MAX_SUBWOOFER_OUTPUTS)) {
                for index in 0..<subwooferCount { additionalDelays[index] = $0[index] }
            }
        }
        let totalWeight = Double(N60CalibrationIncludedWeight(&matrix))
        guard totalWeight > 0 else {
            throw OutputDeviceCalibrationError.designFailed("subwoofer timing weights are invalid")
        }
        var latestSubArrival = 0.0
        for sub in 0..<subwooferCount {
            let sourceIndex = N60MultichannelCalibrationSourceIndexForSubwoofer(&matrix, UInt32(sub))
            guard sourceIndex >= 0 else {
                throw OutputDeviceCalibrationError.designFailed("subwoofer timing source is missing")
            }
            var weightedArrival = 0.0
            for seat in 0..<Int(matrix.seatCount) {
                let seatWeight = Self.seatWeight(matrix: &matrix, index: seat)
                guard seatWeight >= 0 else { continue }
                let response = Self.measuredResponse(
                    matrix: &matrix,
                    sourceIndex: Int(sourceIndex),
                    seatIndex: seat
                )
                weightedArrival += Double(response.directArrivalFrame) * seatWeight / totalWeight
            }
            weightedArrival += Double(additionalDelays[sub]) * sampleRate / 1_000.0
            latestSubArrival = max(latestSubArrival, weightedArrival)
        }
        let speakerReference = Double(alignment.referenceArrivalFrame)
        if latestSubArrival > speakerReference {
            return ((latestSubArrival - speakerReference) / sampleRate * 1_000.0, 0)
        }
        return (0, (speakerReference - latestSubArrival) / sampleRate * 1_000.0)
    }

    private static func subwooferEQTarget(
        result: inout N60MultiSubOptimizationResult,
        subwooferIndex: Int
    ) -> [Float] {
        var values = [Float](repeating: 0, count: Int(result.frequencyCount))
        withUnsafePointer(to: &result.perSubEQTargetDB) { outerTuple in
            outerTuple.withMemoryRebound(
                to: Float.self,
                capacity: Int(N60_MAX_SUBWOOFER_OUTPUTS * N60_CALIBRATION_MAX_FREQUENCY_BINS)
            ) { flat in
                let stride = Int(N60_CALIBRATION_MAX_FREQUENCY_BINS)
                for frequency in values.indices {
                    values[frequency] = flat[subwooferIndex * stride + frequency]
                }
            }
        }
        return values
    }

    private static func fitAttenuationOnlySubwooferEQ(
        frequencies: [Float],
        targetDB: [Float]
    ) -> [OutputCalibrationEQBand] {
        let upper = min(frequencies.count, targetDB.count)
        guard upper > 0 else { return [] }
        let candidates = (0..<upper)
            .filter {
                frequencies[$0] >= Float(Self.minimumFrequencyHz)
                    && frequencies[$0] <= Float(Self.subwooferMaximumFrequencyHz)
                    && targetDB[$0].isFinite
                    && targetDB[$0] <= -0.75
            }
            .sorted { targetDB[$0] < targetDB[$1] }
        var selected: [OutputCalibrationEQBand] = []
        for index in candidates {
            let frequency = Double(frequencies[index])
            guard selected.allSatisfy({ abs(log2(frequency / $0.frequencyHz)) >= 0.33 }) else { continue }
            let gain = max(-8.0, min(0.0, Double(targetDB[index]) * 0.72))
            selected.append(OutputCalibrationEQBand(frequencyHz: frequency, gainDB: gain, q: 1.15))
            if selected.count >= PhysicalSubwooferCalibration.maximumEQBandCount { break }
        }
        return selected.sorted { $0.frequencyHz < $1.frequencyHz }
    }

    private static func measuredResponse(
        matrix: inout N60MultichannelCalibrationMatrix,
        sourceIndex: Int,
        seatIndex: Int
    ) -> N60CalibrationMeasuredResponse {
        withUnsafePointer(to: &matrix.responses) { tuple in
            tuple.withMemoryRebound(
                to: N60CalibrationMeasuredResponse.self,
                capacity: Int(N60_CALIBRATION_MAX_SOURCES * N60_CALIBRATION_MAX_SEATS)
            ) { flat in
                flat[sourceIndex * Int(N60_CALIBRATION_MAX_SEATS) + seatIndex]
            }
        }
    }

    private static func seatWeight(
        matrix: inout N60MultichannelCalibrationMatrix,
        index: Int
    ) -> Double {
        withUnsafePointer(to: &matrix.seats) { tuple in
            tuple.withMemoryRebound(to: N60CalibrationSeat.self, capacity: Int(N60_CALIBRATION_MAX_SEATS)) {
                let seat = $0[index]
                return seat.included && seat.weight > 0 ? Double(seat.weight) : -1
            }
        }
    }

    private static func directPolarity(impulse: [Float], arrivalFrame: Int) -> Int8 {
        guard !impulse.isEmpty else { return 1 }
        let start = max(0, min(arrivalFrame, impulse.count - 1))
        let end = min(impulse.count, start + 16)
        var peak = impulse[start]
        for index in start..<end where abs(impulse[index]) > abs(peak) { peak = impulse[index] }
        return peak < 0 ? -1 : 1
    }

    private static func broadbandLevelDB(
        frequencies: [Float],
        magnitudes: [Float],
        source: MultichannelCalibrationSource
    ) -> Float {
        let range: ClosedRange<Float>
        switch source {
        case .speaker: range = 100...10_000
        case .subwoofer: range = 25...200
        }
        var total: Float = 0
        var count: Float = 0
        for index in 0..<min(frequencies.count, magnitudes.count) where range.contains(frequencies[index]) {
            total += magnitudes[index]
            count += 1
        }
        if count > 0 { return total / count }
        return magnitudes.isEmpty ? 0 : magnitudes.reduce(0, +) / Float(magnitudes.count)
    }

    private static func logFrequencyGrid(minimumHz: Double, maximumHz: Double, count: Int) -> [Float] {
        guard count > 1, maximumHz > minimumHz else { return [] }
        let ratio = maximumHz / minimumHz
        return (0..<count).map {
            Float(minimumHz * pow(ratio, Double($0) / Double(count - 1)))
        }
    }

    private static func targetGainDB(_ target: RoomCorrectionTargetCurve?, at frequency: Double) -> Double {
        guard let target, target.points.count >= 2 else { return 0 }
        let points = target.points
        if frequency <= points[0].frequencyHz { return points[0].gainDB }
        if frequency >= points[points.count - 1].frequencyHz { return points[points.count - 1].gainDB }
        for index in 1..<points.count where frequency <= points[index].frequencyHz {
            let lower = points[index - 1]
            let upper = points[index]
            let denominator = log(upper.frequencyHz / lower.frequencyHz)
            guard denominator > 0 else { return lower.gainDB }
            let fraction = log(frequency / lower.frequencyHz) / denominator
            return lower.gainDB + (upper.gainDB - lower.gainDB) * fraction
        }
        return 0
    }

    private static func interpolate(
        _ values: [Double],
        response: RoomCorrectionFrequencyResponse,
        at frequency: Double
    ) throws -> Double {
        let frequencies = response.frequenciesHz
        guard frequencies.count == values.count,
              frequencies.count >= 2,
              frequency.isFinite,
              frequency > 0 else {
            throw OutputDeviceCalibrationError.designFailed("frequency response arrays are invalid")
        }
        if frequency <= frequencies[0] { return values[0] }
        if frequency >= frequencies[frequencies.count - 1] { return values[values.count - 1] }
        var low = 0
        var high = frequencies.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if frequencies[middle] <= frequency { low = middle } else { high = middle }
        }
        let lowerFrequency = frequencies[low]
        let upperFrequency = frequencies[high]
        let denominator = log(upperFrequency / lowerFrequency)
        guard denominator > 0 else { return values[low] }
        let fraction = log(frequency / lowerFrequency) / denominator
        return values[low] + (values[high] - values[low]) * fraction
    }
}

extension OutputProgramRole {
    init?(realtimeRole: N60ProgramChannelRole) {
        switch realtimeRole {
        case N60ProgramChannelRoleFrontLeft: self = .frontLeft
        case N60ProgramChannelRoleFrontRight: self = .frontRight
        case N60ProgramChannelRoleFrontCenter: self = .frontCenter
        case N60ProgramChannelRoleLowFrequencyEffects: self = .lowFrequencyEffects
        case N60ProgramChannelRoleSideLeft: self = .sideLeft
        case N60ProgramChannelRoleSideRight: self = .sideRight
        case N60ProgramChannelRoleRearLeft: self = .rearLeft
        case N60ProgramChannelRoleRearRight: self = .rearRight
        case N60ProgramChannelRoleWideLeft: self = .wideLeft
        case N60ProgramChannelRoleWideRight: self = .wideRight
        case N60ProgramChannelRoleTopFrontLeft: self = .topFrontLeft
        case N60ProgramChannelRoleTopFrontRight: self = .topFrontRight
        case N60ProgramChannelRoleTopMiddleLeft: self = .topMiddleLeft
        case N60ProgramChannelRoleTopMiddleRight: self = .topMiddleRight
        case N60ProgramChannelRoleTopRearLeft: self = .topRearLeft
        case N60ProgramChannelRoleTopRearRight: self = .topRearRight
        default: return nil
        }
    }
}
