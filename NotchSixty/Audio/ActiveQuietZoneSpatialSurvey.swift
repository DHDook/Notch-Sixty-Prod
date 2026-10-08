import Foundation

struct ActiveQuietZoneSpatialPhaseCapture: Equatable, Sendable {
    var positionID: UUID
    var epoch: UUID
    var firstSampleIndex: UInt64
    var sampleRate: Double
    var frequencyHz: Double
    var detectedFrequencyHz: Double
    var stationaryScore: Double
    var phasorInSharedMicClock: ActiveQuietZoneComplex
}

/// This is a ONE-microphone sequential survey. Complex phase measurements
/// are valid across positions only while microphone frames share one input
/// sample clock, the external tone remains sufficiently stationary and the
/// final anchor revisit closes the phase loop.
struct ActiveQuietZoneSpatialSurveyBuilder: Sendable {
    private let planner = ActiveQuietZonePlanner()

    func capture(
        positionID: UUID,
        epoch: UUID,
        firstSampleIndex: UInt64,
        samples: [Float],
        sampleRate: Double,
        frequencyHz: Double,
        detectedFrequencyHz: Double,
        tonalProminenceDB: Double,
        stationaryScore: Double
    ) throws -> ActiveQuietZoneSpatialPhaseCapture {
        guard sampleRate.isFinite, sampleRate > 8_000,
              (20...150).contains(frequencyHz),
              detectedFrequencyHz.isFinite,
              abs(detectedFrequencyHz - frequencyHz) <= 0.10,
              tonalProminenceDB.isFinite,
              tonalProminenceDB >= 12,
              stationaryScore.isFinite,
              stationaryScore >= 0.85,
              samples.count >= 8_192,
              samples.allSatisfy({ $0.isFinite })
        else { throw ActiveQuietZoneSpatialError.inadequatePhaseReference }

        let local = try planner.tonePhasor(
            samples: samples, frequencyHz: frequencyHz,
            sampleRate: sampleRate
        )
        guard local.magnitude >= 1.0e-7 else {
            throw ActiveQuietZoneSpatialError.inadequatePhaseReference
        }
        let phaseOffset = (
            -2 * Double.pi * frequencyHz
                * (Double(firstSampleIndex) / sampleRate)
        ).truncatingRemainder(dividingBy: 2 * Double.pi)
        let correction = ActiveQuietZoneComplex(
            real: cos(phaseOffset),
            imaginary: sin(phaseOffset)
        )
        return ActiveQuietZoneSpatialPhaseCapture(
            positionID: positionID, epoch: epoch,
            firstSampleIndex: firstSampleIndex,
            sampleRate: sampleRate,
            frequencyHz: frequencyHz,
            detectedFrequencyHz: detectedFrequencyHz,
            stationaryScore: stationaryScore,
            phasorInSharedMicClock: local * correction
        )
    }

    /// Caller provides two distinct, non-overlapping windows per position in
    /// [anchor, other seats..., anchor] order, with a return to the physical
    /// anchor. Neither averaging nor a checkbox can override failure of
    /// repeated-window phase/coherence and anchor-closure tests.
    func finish(
        calibration: ActiveQuietZoneSpatialCalibration,
        captures: [ActiveQuietZoneSpatialPhaseCapture],
        now: Date = Date()
    ) throws -> ActiveQuietZoneSpatialToneSurvey {
        let other = calibration.positions.map(\.id).filter {
            $0 != calibration.anchorPositionID
        }
        let required = [calibration.anchorPositionID] + other
            + [calibration.anchorPositionID]
        guard captures.count == required.count * 2,
              captures.count >= 6,
              captures.count <= 12
        else { throw ActiveQuietZoneSpatialError.insufficientPositions }
        for (index, positionID) in required.enumerated() {
            guard captures[2 * index].positionID == positionID,
                  captures[2 * index + 1].positionID == positionID
            else { throw ActiveQuietZoneSpatialError.mismatchedAnchor }
        }
        guard let first = captures.first,
              let last = captures.last,
              first.epoch == last.epoch,
              captures.allSatisfy({
                $0.epoch == first.epoch
                    && abs($0.sampleRate - calibration.sampleRate) < 0.5
                    && abs($0.frequencyHz - first.frequencyHz) < 0.001
              }),
              captures.map(\.firstSampleIndex)
                .elementsEqual(captures.map(\.firstSampleIndex).sorted()),
              last.firstSampleIndex > first.firstSampleIndex,
              Double(last.firstSampleIndex - first.firstSampleIndex)
                  / first.sampleRate < 180
        else { throw ActiveQuietZoneSpatialError.inadequatePhaseReference }

        var averages: [UUID: ActiveQuietZoneComplex] = [:]
        var pairCoherence: [UUID: Double] = [:]
        var pairPhaseError: [UUID: Double] = [:]
        var maximumDrift: [UUID: Double] = [:]
        for (index, id) in required.enumerated() {
            let a = captures[index * 2]
            let b = captures[index * 2 + 1]
            let minimumWindowAdvance = UInt64(
                min(8_192, Int(first.sampleRate * 0.15))
            )
            guard b.firstSampleIndex > a.firstSampleIndex,
                  b.firstSampleIndex - a.firstSampleIndex
                    >= minimumWindowAdvance,
                  let aPhase = a.phasorInSharedMicClock.unitPhase,
                  let bPhase = b.phasorInSharedMicClock.unitPhase
            else { throw ActiveQuietZoneSpatialError.inadequatePhaseReference }

            let angle = abs(
                (bPhase * aPhase.conjugate).phaseRadians
            )
            let variation = abs(20 * log10(
                a.phasorInSharedMicClock.magnitude
                    / b.phasorInSharedMicClock.magnitude
            ))
            let coherence = max(0, 1 - angle / 2)
            guard angle <= calibration.settings.maximumPhaseClosureRadians,
                  variation <= 1.0,
                  coherence >= calibration.settings.minimumCoherence
            else { throw ActiveQuietZoneSpatialError.inadequatePhaseReference }

            let average = (
                a.phasorInSharedMicClock
                + b.phasorInSharedMicClock
            ) / 2
            averages[id] = average
            pairCoherence[id] = min(pairCoherence[id] ?? 1, coherence)
            pairPhaseError[id] = max(pairPhaseError[id] ?? 0, angle)
            maximumDrift[id] = max(maximumDrift[id] ?? 0,
                abs(a.detectedFrequencyHz - first.frequencyHz),
                abs(b.detectedFrequencyHz - first.frequencyHz))
        }

        // Validate that returning to the original physical microphone
        // location yields the same coherent source phasor.
        let returnCapture0 = captures[captures.count - 2]
        let returnCapture1 = captures[captures.count - 1]
        let returnAnchor = (
            returnCapture0.phasorInSharedMicClock
                + returnCapture1.phasorInSharedMicClock
        ) / 2
        guard let startingAnchor = (
            captures[0].phasorInSharedMicClock
                + captures[1].phasorInSharedMicClock
        ).unitPhase,
              let endingAnchor = returnAnchor.unitPhase
        else { throw ActiveQuietZoneSpatialError.inadequatePhaseReference }
        let closure = abs(
            (endingAnchor * startingAnchor.conjugate)
                .phaseRadians
        )
        let amplitudeDriftDB = abs(20 * log10(
            returnAnchor.magnitude / max(
                (captures[0].phasorInSharedMicClock
                    + captures[1].phasorInSharedMicClock).magnitude / 2,
                1.0e-12)
        ))
        guard closure <= calibration.settings.maximumPhaseClosureRadians,
              amplitudeDriftDB <= 1.0,
              let anchor = averages[calibration.anchorPositionID],
              anchor.magnitude > 1.0e-9
        else { throw ActiveQuietZoneSpatialError.inadequatePhaseReference }

        let evidence = try calibration.positions.map { position -> ActiveQuietZoneSpatialDisturbance in
            guard let phasor = averages[position.id] else {
                throw ActiveQuietZoneSpatialError.invalidSurvey
            }
            let ratio = position.id == calibration.anchorPositionID
                ? ActiveQuietZoneComplex(real: 1, imaginary: 0)
                : phasor / anchor
            return ActiveQuietZoneSpatialDisturbance(
                positionID: position.id,
                ratioToAnchor: ratio,
                coherence: min(pairCoherence[position.id] ?? 0,
                               1 - closure / 2),
                phaseClosureRadians: max(pairPhaseError[position.id] ?? 0,
                                          closure),
                frequencyDriftHz: maximumDrift[position.id] ?? 0
            )
        }
        let survey = ActiveQuietZoneSpatialToneSurvey(
            frequencyHz: first.frequencyHz,
            capturedAt: now,
            commonPhaseReferenceValidated: true,
            disturbances: evidence
        )
        var check = calibration
        check.surveys = [survey]
        _ = try check.validatedSurvey(for: first.frequencyHz)
        return survey
    }
}
