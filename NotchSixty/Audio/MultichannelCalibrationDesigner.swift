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
                targetBuffer.baseAddress!,
                correctionSettings,
                &speakerPlan
            )
        }
        guard speakerDesigned else {
            throw OutputDeviceCalibrationError.designFailed("bounded speaker PEQ design failed")
        }

        var subResult: N60MultiSubOptimizationResult?
        var subOptimizationFrequencies = frequencies
        if bassManagementEnabled, !profile.subwooferAssignments.isEmpty {
            let subFrequencies = Self.logFrequencyGrid(
                minimumHz: Self.minimumFrequencyHz,
                maximumHz: min(
                    Self.subwooferMaximumFrequencyHz,
                    sampleRate * 0.48
                ),
                count: Self.frequencyBinCount
            )
            var subMatrix = subFrequencies.withUnsafeBufferPointer { buffer in
                N60MultichannelCalibrationMatrixMake(
                    sampleRate,
                    profile.programLayout.realtimeLayout,
                    UInt32(profile.subwooferAssignments.count),
                    UInt32(includedSeats.count),
                    buffer.baseAddress,
                    UInt32(buffer.count)
                )
            }
            guard subMatrix.sourceCount > 0 else {
                throw OutputDeviceCalibrationError.designFailed("low-frequency calibration matrix could not be created")
            }
            for (seatIndex, seat) in includedSeats.enumerated() {
                guard N60MultichannelCalibrationSetSeat(
                    &subMatrix,
                    UInt32(seatIndex),
                    true,
                    Float(seat.weight)
                ) else {
                    throw OutputDeviceCalibrationError.designFailed("low-frequency seat weighting failed")
                }
                for role in profile.programLayout.roles where role != .lowFrequencyEffects {
                    let item = try measurement(
                        seatID: seat.id,
                        source: .speaker(role),
                        measurements: measurements,
                        expectedSampleRate: sampleRate
                    )
                    let sourceIndex = N60MultichannelCalibrationSourceIndexForRole(
                        &subMatrix,
                        role.realtimeCType
                    )
                    guard sourceIndex >= 0 else {
                        throw OutputDeviceCalibrationError.designFailed("low-frequency speaker source is missing")
                    }
                    try install(
                        measurement: item,
                        frequencies: subFrequencies,
                        sourceIndex: UInt32(sourceIndex),
                        seatIndex: UInt32(seatIndex),
                        into: &subMatrix
                    )
                }
                for sub in profile.subwooferAssignments.sorted(by: { $0.index < $1.index }) {
                    let item = try measurement(
                        seatID: seat.id,
                        source: .subwoofer(sub.index),
                        measurements: measurements,
                        expectedSampleRate: sampleRate
                    )
                    let sourceIndex = N60MultichannelCalibrationSourceIndexForSubwoofer(
                        &subMatrix,
                        sub.index
                    )
                    guard sourceIndex >= 0 else {
                        throw OutputDeviceCalibrationError.designFailed("low-frequency subwoofer source is missing")
                    }
                    try install(
                        measurement: item,
                        frequencies: subFrequencies,
                        sourceIndex: UInt32(sourceIndex),
                        seatIndex: UInt32(seatIndex),
                        into: &subMatrix
                    )
                }
            }
            guard N60MultichannelCalibrationMatrixIsValid(
                &subMatrix,
                UInt32(profile.subwooferAssignments.count)
            ) else {
                throw OutputDeviceCalibrationError.designFailed("low-frequency measurement matrix is incomplete")
            }
            let subTargetMagnitude = subFrequencies.map {
                Float(alignment.commonLevelDB) + Float(Self.targetGainDB(target, at: Double($0)))
            }
            var settings = N60MultiSubOptimizationSettingsMakeDefault()
            settings.maximumGainDB = 0
            settings.minimumGainDB = -12
            settings.maximumEQDB = 0
            settings.minimumEQDB = -8
            var result = N60MultiSubOptimizationResult()
            let optimized = subTargetMagnitude.withUnsafeBufferPointer { targetBuffer in
                N60MultiSubOptimize(
                    &subMatrix,
                    UInt32(profile.subwooferAssignments.count),
                    targetBuffer.baseAddress!,
                    settings,
                    &result
                )
            }
            guard optimized else {
                throw OutputDeviceCalibrationError.designFailed("multi-sub optimization failed")
            }
            subOptimizationFrequencies = subFrequencies
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
            frequencies: subOptimizationFrequencies,
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


// MARK: - PR86 independent calibration prediction / verification

enum CalibrationPredictionStatus: String, Equatable, Sendable {
    case accepted
    case rejected
}

struct CalibrationPredictionSourceReport: Equatable, Sendable {
    var source: MultichannelCalibrationSource
    var weightedRMSErrorBeforeDB: Double
    var weightedRMSErrorAfterDB: Double
    var improvementDB: Double
    var worstSeatRegressionDB: Double
    var maximumAbsoluteErrorAfterDB: Double
    var confidence: Double
}

struct CalibrationPredictionSeatReport: Equatable, Sendable {
    var seatID: UUID
    var seatName: String
    var speakerRMSErrorBeforeDB: Double
    var speakerRMSErrorAfterDB: Double
    var speakerImprovementDB: Double
    var speakerLevelSpreadBeforeDB: Double
    var speakerLevelSpreadAfterDB: Double
    var speakerTimingSpreadBeforeMs: Double
    var speakerTimingSpreadAfterMs: Double
    var subCombinedRMSErrorBeforeDB: Double?
    var subCombinedRMSErrorAfterDB: Double?
    var confidence: Double
}

struct CalibrationPredictionReport: Equatable, Sendable {
    var sampleRate: Double
    var confidence: Double
    var speakerRMSErrorBeforeDB: Double
    var speakerRMSErrorAfterDB: Double
    var speakerImprovementDB: Double
    var maximumAbsoluteErrorAfterDB: Double
    var worstSourceRegressionDB: Double
    var worstSeatRegressionDB: Double
    var maximumSpeakerLevelSpreadBeforeDB: Double
    var maximumSpeakerLevelSpreadAfterDB: Double
    var maximumSpeakerTimingSpreadBeforeMs: Double
    var maximumSpeakerTimingSpreadAfterMs: Double
    var subCombinedRMSErrorBeforeDB: Double?
    var subCombinedRMSErrorAfterDB: Double?
    var sourceReports: [CalibrationPredictionSourceReport]
    var seatReports: [CalibrationPredictionSeatReport]
    var blockingReasons: [String]
    var warnings: [String]

    var status: CalibrationPredictionStatus {
        blockingReasons.isEmpty ? .accepted : .rejected
    }

    var accepted: Bool { status == .accepted }
}

enum CalibrationPredictionError: Error, Equatable, LocalizedError {
    case invalidSampleRate(Double)
    case noIncludedSeats
    case missingMeasurement(seatID: UUID, source: MultichannelCalibrationSource)
    case invalidResponse(seatID: UUID, source: MultichannelCalibrationSource)
    case missingCalibration(MultichannelCalibrationSource)

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let rate):
            return "Calibration prediction sample rate \(rate) Hz is invalid."
        case .noIncludedSeats:
            return "Calibration prediction requires at least one included listening seat."
        case .missingMeasurement(let seatID, let source):
            return "Calibration prediction is missing \(source.displayName) measurement for seat \(seatID.uuidString)."
        case .invalidResponse(let seatID, let source):
            return "Calibration prediction found invalid transfer data for \(source.displayName) at seat \(seatID.uuidString)."
        case .missingCalibration(let source):
            return "Calibration prediction cannot find the deployable calibration for \(source.displayName)."
        }
    }
}

/// Independent offline verifier for the deployable multichannel calibration.
///
/// This deliberately does not reuse the C designer's internal error metrics.
/// It starts from persisted seat/source transfer functions, applies the
/// materialized calibration that will actually be deployed, and predicts the
/// resulting complex response. This gives deployment a second implementation
/// path that can catch designer/materialization drift.
struct MultichannelCalibrationPredictionVerifier: Sendable {
    static let gridPointCount = 128
    static let minimumConfidence = 0.70
    static let minimumMeaningfulImprovementDB = 0.25
    static let excellentResidualDB = 0.75
    static let maximumSourceRegressionDB = 0.25
    static let maximumSeatRegressionDB = 0.75
    static let maximumAbsoluteResidualDB = 12.0
    static let maximumLevelSpreadRegressionDB = 0.50
    static let maximumTimingSpreadRegressionMs = 0.25
    static let minimumMeasurementSNRDB = 30.0

    func verify(
        design: MultichannelCalibrationDesign,
        seats: [MultichannelCalibrationSeat],
        measurements: [MultichannelCalibrationMeasurement],
        target: RoomCorrectionTargetCurve? = nil
    ) throws -> CalibrationPredictionReport {
        let sampleRate = design.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw CalibrationPredictionError.invalidSampleRate(sampleRate)
        }

        let includedSeats = seats.filter {
            $0.included && $0.weight.isFinite && $0.weight > 0
        }
        guard !includedSeats.isEmpty else {
            throw CalibrationPredictionError.noIncludedSeats
        }

        let speakerSources = design.speakers.map {
            MultichannelCalibrationSource.speaker($0.role)
        }
        let subSources = design.subwoofers.map {
            MultichannelCalibrationSource.subwoofer($0.index)
        }
        let allSources = speakerSources + subSources

        var measurementBySeatSource: [
            PR86SeatSourceKey: MultichannelCalibrationMeasurement
        ] = [:]
        for seat in includedSeats {
            for source in allSources {
                guard let measurement = measurements.last(where: {
                    $0.seatID == seat.id && $0.source == source
                }) else {
                    throw CalibrationPredictionError.missingMeasurement(
                        seatID: seat.id,
                        source: source
                    )
                }
                try validate(
                    measurement: measurement,
                    seatID: seat.id,
                    source: source,
                    expectedSampleRate: sampleRate
                )
                measurementBySeatSource[
                    PR86SeatSourceKey(seatID: seat.id, source: source)
                ] = measurement
            }
        }

        let speakerGrid = Self.logGrid(
            low: MultichannelCalibrationDesigner.minimumFrequencyHz,
            high: min(
                MultichannelCalibrationDesigner.nominalMaximumFrequencyHz,
                sampleRate * 0.48
            ),
            count: Self.gridPointCount
        )
        let subGrid = Self.logGrid(
            low: MultichannelCalibrationDesigner.minimumFrequencyHz,
            high: min(
                MultichannelCalibrationDesigner.subwooferMaximumFrequencyHz,
                sampleRate * 0.48
            ),
            count: 96
        )

        var sourceReports: [CalibrationPredictionSourceReport] = []
        var seatAccumulator: [UUID: PR86SeatAccumulator] = [:]
        for seat in includedSeats {
            seatAccumulator[seat.id] = PR86SeatAccumulator(
                seatID: seat.id,
                seatName: seat.name,
                seatWeight: seat.weight
            )
        }

        var blocking: [String] = []
        var warnings: [String] = []
        var confidenceWeighted = 0.0
        var confidenceWeight = 0.0
        var overallBeforeSquares = 0.0
        var overallAfterSquares = 0.0
        var overallErrorWeight = 0.0
        var maximumAbsoluteAfter = 0.0
        var worstSourceRegression = 0.0

        for speakerDesign in design.speakers {
            let source = MultichannelCalibrationSource.speaker(
                speakerDesign.role
            )
            var beforeSquares = 0.0
            var afterSquares = 0.0
            var sourceWeight = 0.0
            var sourceMaxAfter = 0.0
            var sourceWorstSeatRegression = 0.0
            var sourceConfidenceWeighted = 0.0
            var sourceConfidenceWeight = 0.0

            for seat in includedSeats {
                let measurement = try requiredMeasurement(
                    seatID: seat.id,
                    source: source,
                    from: measurementBySeatSource
                )
                let evaluation = try evaluateSpeaker(
                    measurement: measurement,
                    calibration: speakerDesign.calibration,
                    target: target,
                    grid: speakerGrid,
                    sampleRate: sampleRate
                )
                let weight = seat.weight
                beforeSquares += evaluation.rmsBeforeDB
                    * evaluation.rmsBeforeDB * weight
                afterSquares += evaluation.rmsAfterDB
                    * evaluation.rmsAfterDB * weight
                sourceWeight += weight
                sourceMaxAfter = max(
                    sourceMaxAfter,
                    evaluation.maximumAbsoluteAfterDB
                )
                sourceWorstSeatRegression = max(
                    sourceWorstSeatRegression,
                    evaluation.rmsAfterDB - evaluation.rmsBeforeDB
                )
                sourceConfidenceWeighted += evaluation.confidence * weight
                sourceConfidenceWeight += weight
                confidenceWeighted += evaluation.confidence * weight
                confidenceWeight += weight

                seatAccumulator[seat.id]?.speakerEvaluations.append(
                    evaluation
                )
            }

            let before = sqrt(beforeSquares / max(sourceWeight, 1.0e-12))
            let after = sqrt(afterSquares / max(sourceWeight, 1.0e-12))
            let improvement = before - after
            let confidence = sourceConfidenceWeighted
                / max(sourceConfidenceWeight, 1.0e-12)
            worstSourceRegression = max(worstSourceRegression, -improvement)
            maximumAbsoluteAfter = max(maximumAbsoluteAfter, sourceMaxAfter)
            sourceReports.append(
                CalibrationPredictionSourceReport(
                    source: source,
                    weightedRMSErrorBeforeDB: before,
                    weightedRMSErrorAfterDB: after,
                    improvementDB: improvement,
                    worstSeatRegressionDB: sourceWorstSeatRegression,
                    maximumAbsoluteErrorAfterDB: sourceMaxAfter,
                    confidence: confidence
                )
            )
            overallBeforeSquares += before * before * sourceWeight
            overallAfterSquares += after * after * sourceWeight
            overallErrorWeight += sourceWeight

            if improvement < -Self.maximumSourceRegressionDB {
                blocking.append(
                    "\(source.displayName) is predicted to regress by \(Self.formatDB(-improvement)) RMS."
                )
            }
            if sourceMaxAfter > Self.maximumAbsoluteResidualDB {
                blocking.append(
                    "\(source.displayName) retains \(Self.formatDB(sourceMaxAfter)) maximum target error."
                )
            }

            // Cross-check only trend, not absolute RMS, because the designer's
            // internal objective and this verifier intentionally use different
            // independent metrics.
            let designerImprovement =
                speakerDesign.errorBeforeDB - speakerDesign.errorAfterDB
            if designerImprovement > 0.25 && improvement < -0.10 {
                blocking.append(
                    "\(source.displayName) designer/verifier trends disagree."
                )
            } else if abs(designerImprovement - improvement) > 2.0 {
                warnings.append(
                    "\(source.displayName) independent prediction differs materially from the designer's internal RMS estimate."
                )
            }
        }

        // Predict the coherent summed subwoofer field at each seat. This catches
        // cancellation/regression that per-sub magnitude inspection cannot.
        var subBeforeSquares = 0.0
        var subAfterSquares = 0.0
        var subWeight = 0.0
        if !design.subwoofers.isEmpty {
            for seat in includedSeats {
                let evaluation = try evaluateSummedSubwoofers(
                    seat: seat,
                    designs: design.subwoofers,
                    measurements: measurementBySeatSource,
                    target: target,
                    grid: subGrid,
                    sampleRate: sampleRate
                )
                seatAccumulator[seat.id]?.subEvaluation = evaluation
                let weight = seat.weight
                subBeforeSquares += evaluation.rmsBeforeDB
                    * evaluation.rmsBeforeDB * weight
                subAfterSquares += evaluation.rmsAfterDB
                    * evaluation.rmsAfterDB * weight
                subWeight += weight
                confidenceWeighted += evaluation.confidence * weight
                confidenceWeight += weight
                if evaluation.rmsAfterDB
                    > evaluation.rmsBeforeDB + Self.maximumSeatRegressionDB {
                    blocking.append(
                        "\(seat.name) summed subwoofer response is predicted to regress by \(Self.formatDB(evaluation.rmsAfterDB - evaluation.rmsBeforeDB)) RMS."
                    )
                }
            }
        }

        var seatReports: [CalibrationPredictionSeatReport] = []
        var worstSeatRegression = 0.0
        var maxLevelBefore = 0.0
        var maxLevelAfter = 0.0
        var maxTimingBefore = 0.0
        var maxTimingAfter = 0.0

        for seat in includedSeats {
            guard let accumulator = seatAccumulator[seat.id] else {
                continue
            }
            let evaluations = accumulator.speakerEvaluations
            let seatBefore = Self.rms(evaluations.map(\.rmsBeforeDB))
            let seatAfter = Self.rms(evaluations.map(\.rmsAfterDB))
            let seatImprovement = seatBefore - seatAfter
            worstSeatRegression = max(
                worstSeatRegression,
                seatAfter - seatBefore
            )

            let levelBefore = Self.spread(
                evaluations.map(\.broadbandLevelBeforeDB)
            )
            let levelAfter = Self.spread(
                evaluations.map(\.broadbandLevelAfterDB)
            )
            let timingBefore = Self.spread(
                evaluations.map(\.arrivalBeforeMs)
            )
            let timingAfter = Self.spread(
                evaluations.map(\.arrivalAfterMs)
            )
            maxLevelBefore = max(maxLevelBefore, levelBefore)
            maxLevelAfter = max(maxLevelAfter, levelAfter)
            maxTimingBefore = max(maxTimingBefore, timingBefore)
            maxTimingAfter = max(maxTimingAfter, timingAfter)

            if seatAfter > seatBefore + Self.maximumSeatRegressionDB {
                blocking.append(
                    "\(seat.name) is predicted to regress by \(Self.formatDB(seatAfter - seatBefore)) RMS."
                )
            }
            let confidence = evaluations.isEmpty
                ? 0
                : evaluations.map(\.confidence).reduce(0, +)
                    / Double(evaluations.count)
            seatReports.append(
                CalibrationPredictionSeatReport(
                    seatID: seat.id,
                    seatName: seat.name,
                    speakerRMSErrorBeforeDB: seatBefore,
                    speakerRMSErrorAfterDB: seatAfter,
                    speakerImprovementDB: seatImprovement,
                    speakerLevelSpreadBeforeDB: levelBefore,
                    speakerLevelSpreadAfterDB: levelAfter,
                    speakerTimingSpreadBeforeMs: timingBefore,
                    speakerTimingSpreadAfterMs: timingAfter,
                    subCombinedRMSErrorBeforeDB:
                        accumulator.subEvaluation?.rmsBeforeDB,
                    subCombinedRMSErrorAfterDB:
                        accumulator.subEvaluation?.rmsAfterDB,
                    confidence: confidence
                )
            )
        }

        let before = sqrt(
            overallBeforeSquares / max(overallErrorWeight, 1.0e-12)
        )
        let after = sqrt(
            overallAfterSquares / max(overallErrorWeight, 1.0e-12)
        )
        let improvement = before - after

        var confidence = confidenceWeighted
            / max(confidenceWeight, 1.0e-12)
        let seatCoverage = min(
            1.0,
            0.85 + 0.075 * Double(max(0, includedSeats.count - 1))
        )
        confidence *= seatCoverage
        confidence = min(max(confidence, 0), 1)

        if confidence < Self.minimumConfidence {
            blocking.append(
                "Prediction confidence \(Int((confidence * 100).rounded()))% is below the \(Int(Self.minimumConfidence * 100))% deployment threshold."
            )
        }

        let alreadyExcellent = after <= Self.excellentResidualDB
            && after <= before + 0.10
        if improvement < Self.minimumMeaningfulImprovementDB
            && !alreadyExcellent {
            blocking.append(
                "Predicted speaker RMS improves by only \(Self.formatDB(improvement)); at least \(Self.formatDB(Self.minimumMeaningfulImprovementDB)) is required unless residual error is already excellent."
            )
        }
        if maximumAbsoluteAfter > Self.maximumAbsoluteResidualDB {
            blocking.append(
                "Predicted maximum target error is \(Self.formatDB(maximumAbsoluteAfter)), above the \(Self.formatDB(Self.maximumAbsoluteResidualDB)) limit."
            )
        }
        if maxLevelAfter
            > maxLevelBefore + Self.maximumLevelSpreadRegressionDB {
            blocking.append(
                "Speaker level alignment is predicted to worsen from \(Self.formatDB(maxLevelBefore)) to \(Self.formatDB(maxLevelAfter)) spread."
            )
        }
        if maxTimingAfter
            > maxTimingBefore + Self.maximumTimingSpreadRegressionMs {
            blocking.append(
                "Speaker timing alignment is predicted to worsen from \(Self.formatMS(maxTimingBefore)) to \(Self.formatMS(maxTimingAfter)) spread."
            )
        }

        let subBefore = subWeight > 0
            ? sqrt(subBeforeSquares / subWeight)
            : nil
        let subAfter = subWeight > 0
            ? sqrt(subAfterSquares / subWeight)
            : nil
        if let subBefore, let subAfter,
           subAfter > subBefore + 0.50 {
            blocking.append(
                "Coherent summed-sub prediction regresses by \(Self.formatDB(subAfter - subBefore)) RMS."
            )
        }

        // De-duplicate deterministic human-readable reasons.
        blocking = Array(NSOrderedSet(array: blocking)) as? [String]
            ?? blocking
        warnings = Array(NSOrderedSet(array: warnings)) as? [String]
            ?? warnings

        return CalibrationPredictionReport(
            sampleRate: sampleRate,
            confidence: confidence,
            speakerRMSErrorBeforeDB: before,
            speakerRMSErrorAfterDB: after,
            speakerImprovementDB: improvement,
            maximumAbsoluteErrorAfterDB: maximumAbsoluteAfter,
            worstSourceRegressionDB: worstSourceRegression,
            worstSeatRegressionDB: worstSeatRegression,
            maximumSpeakerLevelSpreadBeforeDB: maxLevelBefore,
            maximumSpeakerLevelSpreadAfterDB: maxLevelAfter,
            maximumSpeakerTimingSpreadBeforeMs: maxTimingBefore,
            maximumSpeakerTimingSpreadAfterMs: maxTimingAfter,
            subCombinedRMSErrorBeforeDB: subBefore,
            subCombinedRMSErrorAfterDB: subAfter,
            sourceReports: sourceReports,
            seatReports: seatReports,
            blockingReasons: blocking,
            warnings: warnings
        )
    }

    private func validate(
        measurement: MultichannelCalibrationMeasurement,
        seatID: UUID,
        source: MultichannelCalibrationSource,
        expectedSampleRate: Double
    ) throws {
        guard measurement.sampleRate.isFinite,
              abs(measurement.sampleRate - expectedSampleRate) < 0.5,
              let response = measurement.channel.transferFunction,
              response.frequenciesHz.count >= 2,
              response.frequenciesHz.count == response.magnitudeDB.count,
              response.frequenciesHz.allSatisfy({ $0.isFinite && $0 > 0 }),
              response.magnitudeDB.allSatisfy(\.isFinite),
              zip(
                response.frequenciesHz,
                response.frequenciesHz.dropFirst()
              ).allSatisfy({ $0 < $1 }),
              measurement.channel.quality.sweepComplete else {
            throw CalibrationPredictionError.invalidResponse(
                seatID: seatID,
                source: source
            )
        }
    }

    private func requiredMeasurement(
        seatID: UUID,
        source: MultichannelCalibrationSource,
        from lookup: [PR86SeatSourceKey: MultichannelCalibrationMeasurement]
    ) throws -> MultichannelCalibrationMeasurement {
        guard let measurement = lookup[
            PR86SeatSourceKey(seatID: seatID, source: source)
        ] else {
            throw CalibrationPredictionError.missingMeasurement(
                seatID: seatID,
                source: source
            )
        }
        return measurement
    }

    private func evaluateSpeaker(
        measurement: MultichannelCalibrationMeasurement,
        calibration: SemanticSpeakerCalibration,
        target: RoomCorrectionTargetCurve?,
        grid: [Double],
        sampleRate: Double
    ) throws -> PR86ResponseEvaluation {
        try calibration.validate(sampleRate: sampleRate)
        let source = measurement.source
        let usable = usableGrid(
            grid,
            quality: measurement.channel.quality
        )
        guard usable.count >= 8,
              let response = measurement.channel.transferFunction else {
            throw CalibrationPredictionError.invalidResponse(
                seatID: measurement.seatID,
                source: source
            )
        }

        var before: [Double] = []
        var after: [Double] = []
        var targetValues: [Double] = []
        before.reserveCapacity(usable.count)
        after.reserveCapacity(usable.count)
        targetValues.reserveCapacity(usable.count)

        for frequency in usable {
            let measuredDB = try Self.interpolate(
                response.magnitudeDB,
                response: response,
                at: frequency
            )
            let correction = Self.eqMagnitudeDB(
                bands: calibration.eqBands,
                frequency: frequency,
                sampleRate: sampleRate
            ) + calibration.trimDB
            before.append(measuredDB)
            after.append(measuredDB + correction)
            targetValues.append(Self.targetGainDB(target, at: frequency))
        }

        let beforeErrors = Self.normalizedErrors(
            responseDB: before,
            targetDB: targetValues
        )
        let afterErrors = Self.normalizedErrors(
            responseDB: after,
            targetDB: targetValues
        )
        let beforeRMS = Self.rms(beforeErrors)
        let afterRMS = Self.rms(afterErrors)
        let maxAfter = afterErrors.map(abs).max() ?? 0
        let confidence = Self.measurementConfidence(
            measurement.channel.quality,
            evaluatedLow: usable.first ?? grid.first ?? 20,
            evaluatedHigh: usable.last ?? grid.last ?? 20,
            phaseAvailable:
                response.phaseRadians?.count == response.frequenciesHz.count
        )
        let arrivalBefore = (measurement.channel.quality.directArrivalSeconds
            ?? 0) * 1_000
        let arrivalAfter = arrivalBefore + calibration.delayMilliseconds

        return PR86ResponseEvaluation(
            rmsBeforeDB: beforeRMS,
            rmsAfterDB: afterRMS,
            maximumAbsoluteAfterDB: maxAfter,
            broadbandLevelBeforeDB: Self.mean(before),
            broadbandLevelAfterDB: Self.mean(after),
            arrivalBeforeMs: arrivalBefore,
            arrivalAfterMs: arrivalAfter,
            confidence: confidence
        )
    }

    private func evaluateSummedSubwoofers(
        seat: MultichannelCalibrationSeat,
        designs: [MultichannelSubwooferDesign],
        measurements: [PR86SeatSourceKey: MultichannelCalibrationMeasurement],
        target: RoomCorrectionTargetCurve?,
        grid: [Double],
        sampleRate: Double
    ) throws -> PR86SubEvaluation {
        var beforeDB: [Double] = []
        var afterDB: [Double] = []
        var targetDB: [Double] = []
        var confidences: [Double] = []

        for frequency in grid {
            var beforeSum = PR86Complex.zero
            var afterSum = PR86Complex.zero
            var valid = true

            for design in designs {
                let source = MultichannelCalibrationSource.subwoofer(
                    design.index
                )
                let measurement = try requiredMeasurement(
                    seatID: seat.id,
                    source: source,
                    from: measurements
                )
                guard let response = measurement.channel.transferFunction,
                      let phases = response.phaseRadians,
                      phases.count == response.frequenciesHz.count,
                      let usableLow = measurement.channel.quality.usableLowHz,
                      let usableHigh = measurement.channel.quality.usableHighHz,
                      frequency >= usableLow,
                      frequency <= usableHigh else {
                    valid = false
                    continue
                }
                let magnitudeDB = try Self.interpolate(
                    response.magnitudeDB,
                    response: response,
                    at: frequency
                )
                let phase = try Self.interpolate(
                    phases,
                    response: response,
                    at: frequency
                )
                let measured = PR86Complex.polar(
                    magnitude: pow(10, magnitudeDB / 20),
                    phase: phase
                )
                beforeSum = beforeSum + measured

                try design.calibration.validate(sampleRate: sampleRate)
                var correction = PR86Complex.polar(
                    magnitude: pow(
                        10,
                        design.calibration.gainDB / 20
                    ),
                    phase: design.calibration.polarityInverted ? .pi : 0
                )
                for band in design.calibration.eqBands {
                    correction = correction * Self.peakingResponse(
                        band: band,
                        frequency: frequency,
                        sampleRate: sampleRate
                    )
                }
                let delayPhase = -2 * Double.pi * frequency
                    * design.calibration.delayMilliseconds / 1_000
                correction = correction * PR86Complex.polar(
                    magnitude: 1,
                    phase: delayPhase
                )
                afterSum = afterSum + measured * correction

                confidences.append(
                    Self.measurementConfidence(
                        measurement.channel.quality,
                        evaluatedLow: grid.first ?? 20,
                        evaluatedHigh: grid.last ?? 300,
                        phaseAvailable: true
                    )
                )
            }

            if valid && beforeSum.magnitude > 1.0e-12
                && afterSum.magnitude > 1.0e-12 {
                beforeDB.append(
                    20 * log10(beforeSum.magnitude)
                )
                afterDB.append(
                    20 * log10(afterSum.magnitude)
                )
                targetDB.append(
                    Self.targetGainDB(target, at: frequency)
                )
            }
        }

        guard beforeDB.count >= 8,
              beforeDB.count == afterDB.count else {
            throw CalibrationPredictionError.invalidResponse(
                seatID: seat.id,
                source: .subwoofer(designs.first?.index ?? 0)
            )
        }
        let beforeErrors = Self.normalizedErrors(
            responseDB: beforeDB,
            targetDB: targetDB
        )
        let afterErrors = Self.normalizedErrors(
            responseDB: afterDB,
            targetDB: targetDB
        )
        return PR86SubEvaluation(
            rmsBeforeDB: Self.rms(beforeErrors),
            rmsAfterDB: Self.rms(afterErrors),
            confidence: confidences.isEmpty
                ? 0
                : confidences.reduce(0, +) / Double(confidences.count)
        )
    }

    private func usableGrid(
        _ grid: [Double],
        quality: RoomCorrectionMeasurementQuality
    ) -> [Double] {
        let low = quality.usableLowHz ?? grid.first ?? 20
        let high = quality.usableHighHz ?? grid.last ?? 20
        return grid.filter { $0 >= low && $0 <= high }
    }

    private static func measurementConfidence(
        _ quality: RoomCorrectionMeasurementQuality,
        evaluatedLow: Double,
        evaluatedHigh: Double,
        phaseAvailable: Bool
    ) -> Double {
        guard !quality.clipped, quality.sweepComplete else { return 0 }
        let snr: Double
        if let value = quality.estimatedSNRDB, value.isFinite {
            snr = min(max((value - 20) / 30, 0), 1)
        } else {
            snr = 0.55
        }
        let usableLow = quality.usableLowHz ?? evaluatedLow
        let usableHigh = quality.usableHighHz ?? evaluatedHigh
        let requestedOctaves = max(
            log2(max(evaluatedHigh / max(evaluatedLow, 1), 1)),
            1.0e-9
        )
        let overlapLow = max(evaluatedLow, usableLow)
        let overlapHigh = min(evaluatedHigh, usableHigh)
        let overlapOctaves = overlapHigh > overlapLow
            ? log2(overlapHigh / overlapLow)
            : 0
        let coverage = min(max(overlapOctaves / requestedOctaves, 0), 1)
        let phase = phaseAvailable ? 1.0 : 0.65
        let arrival = quality.directArrivalSeconds == nil ? 0.75 : 1.0
        return min(max(
            0.45 * snr + 0.30 * coverage + 0.15 * phase + 0.10 * arrival,
            0
        ), 1)
    }

    private static func eqMagnitudeDB(
        bands: [OutputCalibrationEQBand],
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        bands.reduce(0) { partial, band in
            let response = peakingResponse(
                band: band,
                frequency: frequency,
                sampleRate: sampleRate
            )
            return partial + 20 * log10(max(response.magnitude, 1.0e-12))
        }
    }

    private static func peakingResponse(
        band: OutputCalibrationEQBand,
        frequency: Double,
        sampleRate: Double
    ) -> PR86Complex {
        let a = pow(10.0, band.gainDB / 40.0)
        let w0 = 2.0 * Double.pi * band.frequencyHz / sampleRate
        let alpha = sin(w0) / (2.0 * band.q)
        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cos(w0)
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cos(w0)
        let a2 = 1.0 - alpha / a

        let w = 2.0 * Double.pi * frequency / sampleRate
        let z1 = PR86Complex.polar(magnitude: 1, phase: -w)
        let z2 = PR86Complex.polar(magnitude: 1, phase: -2 * w)
        let numerator = PR86Complex(real: b0, imaginary: 0)
            + z1 * b1 + z2 * b2
        let denominator = PR86Complex(real: a0, imaginary: 0)
            + z1 * a1 + z2 * a2
        return numerator / denominator
    }

    private static func normalizedErrors(
        responseDB: [Double],
        targetDB: [Double]
    ) -> [Double] {
        guard responseDB.count == targetDB.count,
              !responseDB.isEmpty else {
            return []
        }
        let raw = zip(responseDB, targetDB).map(-)
        let offset = mean(raw)
        return raw.map { $0 - offset }
    }

    private static func targetGainDB(
        _ target: RoomCorrectionTargetCurve?,
        at frequency: Double
    ) -> Double {
        guard let target, target.points.count >= 2 else { return 0 }
        let points = target.points
        if frequency <= points[0].frequencyHz {
            return points[0].gainDB
        }
        if frequency >= points[points.count - 1].frequencyHz {
            return points[points.count - 1].gainDB
        }
        for index in 1..<points.count
            where frequency <= points[index].frequencyHz {
            let lower = points[index - 1]
            let upper = points[index]
            let denominator = log(
                upper.frequencyHz / lower.frequencyHz
            )
            guard denominator > 0 else { return lower.gainDB }
            let fraction = log(frequency / lower.frequencyHz)
                / denominator
            return lower.gainDB
                + (upper.gainDB - lower.gainDB) * fraction
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
            throw OutputDeviceCalibrationError.designFailed(
                "prediction frequency response arrays are invalid"
            )
        }
        if frequency <= frequencies[0] { return values[0] }
        if frequency >= frequencies[frequencies.count - 1] {
            return values[values.count - 1]
        }
        var low = 0
        var high = frequencies.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if frequencies[middle] <= frequency {
                low = middle
            } else {
                high = middle
            }
        }
        let lowerFrequency = frequencies[low]
        let upperFrequency = frequencies[high]
        let denominator = log(upperFrequency / lowerFrequency)
        guard denominator > 0 else { return values[low] }
        let fraction = log(frequency / lowerFrequency) / denominator
        return values[low] + (values[high] - values[low]) * fraction
    }

    private static func logGrid(
        low: Double,
        high: Double,
        count: Int
    ) -> [Double] {
        guard low.isFinite, high.isFinite, high > low, count > 1 else {
            return []
        }
        let ratio = high / low
        return (0..<count).map {
            low * pow(ratio, Double($0) / Double(count - 1))
        }
    }

    private static func rms(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let square = values.reduce(0) { $0 + $1 * $1 }
        return sqrt(square / Double(values.count))
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func spread(_ values: [Double]) -> Double {
        guard let minimum = values.min(),
              let maximum = values.max() else {
            return 0
        }
        return maximum - minimum
    }

    private static func formatDB(_ value: Double) -> String {
        String(format: "%.2f dB", value)
    }

    private static func formatMS(_ value: Double) -> String {
        String(format: "%.2f ms", value)
    }
}

private struct PR86SeatSourceKey: Hashable {
    var seatID: UUID
    var source: MultichannelCalibrationSource
}

private struct PR86ResponseEvaluation {
    var rmsBeforeDB: Double
    var rmsAfterDB: Double
    var maximumAbsoluteAfterDB: Double
    var broadbandLevelBeforeDB: Double
    var broadbandLevelAfterDB: Double
    var arrivalBeforeMs: Double
    var arrivalAfterMs: Double
    var confidence: Double
}

private struct PR86SubEvaluation {
    var rmsBeforeDB: Double
    var rmsAfterDB: Double
    var confidence: Double
}

private struct PR86SeatAccumulator {
    var seatID: UUID
    var seatName: String
    var seatWeight: Double
    var speakerEvaluations: [PR86ResponseEvaluation] = []
    var subEvaluation: PR86SubEvaluation?
}

private struct PR86Complex {
    var real: Double
    var imaginary: Double

    static let zero = PR86Complex(real: 0, imaginary: 0)

    var magnitude: Double { hypot(real, imaginary) }

    static func polar(magnitude: Double, phase: Double) -> Self {
        Self(
            real: magnitude * cos(phase),
            imaginary: magnitude * sin(phase)
        )
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            real: lhs.real + rhs.real,
            imaginary: lhs.imaginary + rhs.imaginary
        )
    }

    static func * (lhs: Self, rhs: Self) -> Self {
        Self(
            real: lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
            imaginary:
                lhs.real * rhs.imaginary + lhs.imaginary * rhs.real
        )
    }

    static func * (lhs: Self, rhs: Double) -> Self {
        Self(real: lhs.real * rhs, imaginary: lhs.imaginary * rhs)
    }

    static func / (lhs: Self, rhs: Self) -> Self {
        let denominator = rhs.real * rhs.real
            + rhs.imaginary * rhs.imaginary
        guard denominator > 1.0e-24 else { return .zero }
        return Self(
            real: (
                lhs.real * rhs.real + lhs.imaginary * rhs.imaginary
            ) / denominator,
            imaginary: (
                lhs.imaginary * rhs.real - lhs.real * rhs.imaginary
            ) / denominator
        )
    }
}
