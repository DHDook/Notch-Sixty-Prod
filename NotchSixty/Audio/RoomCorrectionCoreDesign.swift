import Foundation

/// Swift face of the room-correction FIR design maths in `libn60core` (`n60/correct.h` section 7, E21 S6a and S6b).
///
/// Offline only: every call allocates and runs on a design task, never from an audio callback. The controllers reach it
/// through `RoomCorrectionFIRDesigner` and the target designers when `e21.core-designers` is on; off, the Swift maths in
/// `RoomCorrectionFIRDesigner.swift` and `RoomCorrectionTargetDesigner.swift` runs unchanged. Orchestration (names,
/// identifiers, dates, the deployment filter's value type) stays in Swift.
extension RoomCorrectionCore {
    /// Points of a built-in target (0 flat, 1 gentle downward tilt, 2 bass shelf and tilt).
    static func builtInTargetPoints(index: Int) -> [RoomCorrectionTargetPoint] {
        var frequencies = [Double](repeating: 0, count: Int(N60_CORRECT_BUILTIN_TARGET_MAX_POINTS))
        var gains = frequencies
        var count: UInt32 = 0
        let status = n60_correct_builtin_target(UInt32(index), &frequencies, &gains, UInt32(frequencies.count), &count)
        precondition(status == 0, "built-in target index out of range")
        return (0..<Int(count)).map { RoomCorrectionTargetPoint(frequencyHz: frequencies[$0], gainDB: gains[$0]) }
    }

    static func parseTarget(_ text: String) throws -> [RoomCorrectionTargetPoint] {
        let bytes = Array(text.utf8)
        // A data line holds at least one byte and a break, so this bounds the unique point count.
        let capacity = max(2, bytes.count / 2 + 1)
        var frequencies = [Double](repeating: 0, count: capacity)
        var gains = frequencies
        var count: UInt32 = 0
        var errorLine: UInt32 = 0
        let status = bytes.withUnsafeBufferPointer { text in
            n60_correct_target_parse(
                UnsafeRawPointer(text.baseAddress).map { $0.assumingMemoryBound(to: CChar.self) },
                UInt64(text.count), &frequencies, &gains, UInt32(capacity), &count, &errorLine)
        }
        switch status {
        case 0:
            return (0..<Int(count)).map { RoomCorrectionTargetPoint(frequencyHz: frequencies[$0], gainDB: gains[$0]) }
        case N60_CORRECT_ERR_PARSE_EMPTY:
            throw RoomCorrectionTargetDesignError.emptyTarget
        case N60_CORRECT_ERR_PARSE_LINE:
            throw RoomCorrectionTargetDesignError.malformedTargetLine(Int(errorLine))
        case N60_CORRECT_ERR_PARSE_FREQUENCY:
            throw RoomCorrectionTargetDesignError.invalidTargetFrequency(Int(errorLine))
        case N60_CORRECT_ERR_PARSE_GAIN:
            throw RoomCorrectionTargetDesignError.invalidTargetGain(Int(errorLine))
        default:
            throw RoomCorrectionTargetDesignError.insufficientTargetPoints
        }
    }

    /// The correction preview (target, smoothing, limits, null protection, edge taper) for both channels.
    static func correctionPreview(
        aggregate: RoomCorrectionAggregateResponse,
        target: RoomCorrectionTargetCurve,
        parameters: RoomCorrectionDesignParameters,
        usableLowHz: Double?,
        usableHighHz: Double?
    ) throws -> RoomCorrectionCorrectionPreview {
        let left = aggregate.leftResponse
        let right = aggregate.rightResponse
        // Phase is not part of the core call; keep the Swift validation of it.
        for response in [left, right] {
            if let phase = response.phaseRadians,
               phase.count != response.frequenciesHz.count || !phase.allSatisfy(\.isFinite) {
                throw RoomCorrectionTargetDesignError.invalidResponse
            }
        }
        let count = left.frequenciesHz.count
        guard right.frequenciesHz.count == count, left.magnitudeDB.count == count, right.magnitudeDB.count == count
        else { throw RoomCorrectionTargetDesignError.invalidResponse }
        let targetFrequencies = target.points.map(\.frequencyHz)
        let targetGains = target.points.map(\.gainDB)

        var params = n60_correct_preview_params()
        params.struct_size = UInt32(MemoryLayout<n60_correct_preview_params>.size)
        params.has_usable_low = usableLowHz == nil ? 0 : 1
        params.has_usable_high = usableHighHz == nil ? 0 : 1
        params.usable_low_hz = usableLowHz ?? 0
        params.usable_high_hz = usableHighHz ?? 0
        params.tap_count = UInt32(clamping: parameters.requestedTapCount)
        params.tap_limit = UInt32(N60_CONVOLUTION_MAX_TAPS)
        params.correction_low_hz = parameters.correctionLowHz
        params.correction_high_hz = parameters.correctionHighHz
        params.smoothing_octaves = parameters.smoothingOctaves
        params.maximum_boost_db = parameters.maximumBoostDB
        params.maximum_cut_db = parameters.maximumCutDB

        var target = [Double](repeating: 0, count: count)
        var smoothedLeft = target, smoothedRight = target, correctionLeft = target, correctionRight = target
        var out = n60_correct_preview_out()
        let status: Int32 = target.withUnsafeMutableBufferPointer { t in
            smoothedLeft.withUnsafeMutableBufferPointer { sl in
                smoothedRight.withUnsafeMutableBufferPointer { sr in
                    correctionLeft.withUnsafeMutableBufferPointer { cl in
                        correctionRight.withUnsafeMutableBufferPointer { cr in
                            out.target_db = t.baseAddress
                            out.smoothed_left_db = sl.baseAddress
                            out.smoothed_right_db = sr.baseAddress
                            out.left_correction_db = cl.baseAddress
                            out.right_correction_db = cr.baseAddress
                            return n60_correct_preview(
                                &params, left.frequenciesHz, UInt32(count), left.magnitudeDB, right.frequenciesHz,
                                right.magnitudeDB, targetFrequencies, targetGains, UInt32(targetFrequencies.count), &out)
                        }
                    }
                }
            }
        }
        switch status {
        case 0: break
        case N60_CORRECT_ERR_TARGET_POINTS: throw RoomCorrectionTargetDesignError.insufficientTargetPoints
        case N60_CORRECT_ERR_TARGET_CURVE: throw RoomCorrectionTargetDesignError.invalidTargetCurve
        case N60_CORRECT_ERR_GRID: throw RoomCorrectionTargetDesignError.mismatchedResponseGrid
        case N60_CORRECT_ERR_SMOOTHING: throw RoomCorrectionTargetDesignError.invalidSmoothing(parameters.smoothingOctaves)
        case N60_CORRECT_ERR_RANGE:
            throw RoomCorrectionTargetDesignError.invalidCorrectionRange(
                low: parameters.correctionLowHz, high: parameters.correctionHighHz)
        case N60_CORRECT_ERR_BOOST: throw RoomCorrectionTargetDesignError.invalidMaximumBoost(parameters.maximumBoostDB)
        case N60_CORRECT_ERR_CUT: throw RoomCorrectionTargetDesignError.invalidMaximumCut(parameters.maximumCutDB)
        case N60_CORRECT_ERR_TAP_COUNT: throw RoomCorrectionTargetDesignError.invalidTapCount(parameters.requestedTapCount)
        case N60_CORRECT_ERR_USABLE:
            throw RoomCorrectionTargetDesignError.invalidUsableRange(
                low: usableLowHz ?? left.frequenciesHz.first ?? 0, high: usableHighHz ?? left.frequenciesHz.last ?? 0)
        case N60_CORRECT_ERR_NO_RANGE: throw RoomCorrectionTargetDesignError.noUsableCorrectionRange
        default: throw RoomCorrectionTargetDesignError.invalidResponse
        }
        func response(_ db: [Double]) -> RoomCorrectionFrequencyResponse {
            RoomCorrectionFrequencyResponse(frequenciesHz: left.frequenciesHz, magnitudeDB: db, phaseRadians: nil)
        }
        return RoomCorrectionCorrectionPreview(
            targetResponse: response(target),
            smoothedLeftResponse: response(smoothedLeft),
            smoothedRightResponse: response(smoothedRight),
            leftCorrectionResponse: response(correctionLeft),
            rightCorrectionResponse: response(correctionRight),
            effectiveCorrectionLowHz: out.effective_low_hz,
            effectiveCorrectionHighHz: out.effective_high_hz,
            maximumPositiveCorrectionDB: out.maximum_positive_db,
            estimatedHeadroomDB: out.estimated_headroom_db)
    }

    static func firTransformSize(tapCount: Int) throws -> Int {
        var size: UInt32 = 0
        let status = n60_correct_fir_transform_size(
            UInt32(clamping: tapCount), UInt32(N60_CONVOLUTION_MAX_TAPS), &size)
        switch status {
        case 0: return Int(size)
        case N60_CORRECT_ERR_TAP_COUNT: throw RoomCorrectionTargetDesignError.invalidTapCount(tapCount)
        default: throw RoomCorrectionFIRDesignError.transformTooLarge(required: tapCount)
        }
    }

    /// Magnitude of a finished FIR at the response grid and its largest positive gain (dB, at least 0).
    static func firResponse(
        taps: [Float], sampleRate: Double, transformSize: Int, frequenciesHz: [Double]
    ) throws -> (magnitudeDB: [Double], maximumPositiveDB: Double) {
        var out = [Double](repeating: 0, count: frequenciesHz.count)
        var maximum = 0.0
        let status = n60_correct_fir_response(
            taps, UInt32(taps.count), sampleRate, UInt32(transformSize), frequenciesHz, UInt32(frequenciesHz.count), &out,
            &maximum)
        switch status {
        case 0: return (out, maximum)
        case N60_CORRECT_ERR_NONFINITE: throw RoomCorrectionFIRDesignError.nonFiniteResponse
        default: throw RoomCorrectionFIRDesignError.transformSetupFailed(transformSize)
        }
    }

    static func recommendedHeadroomDB(maximumPositiveDB: Double) -> Double {
        n60_correct_recommended_headroom_db(maximumPositiveDB)
    }

    static func scaledTaps(_ taps: [Float], headroomDB: Double) throws -> [Float] {
        var out = [Float](repeating: 0, count: taps.count)
        let status = n60_correct_scale_taps(taps, UInt32(taps.count), headroomDB, &out)
        switch status {
        case 0: return out
        case N60_CORRECT_ERR_NONFINITE: throw RoomCorrectionFIRDesignError.nonFiniteFilter
        default: throw RoomCorrectionFIRDesignError.invalidDeploymentHeadroom(headroomDB)
        }
    }
}
