import Foundation

// E12 S16b (G16, G118): the older Crossover Design and Sub Phase Alignment cards are retired from the Speakers page.
// Whatever those cards stored is carried to where the page now edits it, with the same sound:
//   - a physical crossover (mains + sub, bi-amp, tri-amp) lives in the routing matrix (`SpeakerRoutingMigration`, which
//     carries frequency, family, slope, sub polarity, sub gain and the sub phase all-pass);
//   - the logical stereo crossover lives in the speaker arrangement: the arrangement's bass handling, with the
//     frequency and slope the arrangement editor already edits (`SystemSetupTopologyPreset`). Linkwitz-Riley 24 and 48
//     are exactly what the stereo kernel runs today, so no mono-bass filter override is stored and the sound cannot move;
//   - anything else keeps playing as stored and is shown read-only, with its reason.
// Pure decisions here; the one write (`carry`) stores a derived arrangement and nothing else. Legacy fields stay as stored.

enum SpeakersBassMigration {
    enum Outcome: Equatable, Sendable {
        /// No older bass setting is in use.
        case nothingToCarry
        /// The physical crossover is carried to the routing matrix.
        case matrix
        /// The logical stereo crossover is carried to the arrangement's bass settings.
        case arrangement
        /// It cannot be carried; it keeps playing as stored, for this reason.
        case keepsPlaying(String)
    }

    /// Where the older cards' settings in `state` go, and whether they can go there.
    static func outcome(for state: PlaybackSystemState, detectedChannelCount: Int = 0) -> Outcome {
        let bass = state.bassManagement
        if bass.physicalOutputMode != nil {
            if state.speakerRouting?.enabled == true, bass.enabled { return .matrix }
            let result = SpeakerRoutingMigration.migrate(
                routing: state.outputRouting, bassManagement: bass, driverProcessing: state.speakerDriverProcessing)
            if result.routing != nil { return .matrix }
            if case .unsupported(let reason)? = result.refusal { return .keepsPlaying(reason) }
            if bass.enabled, bass.subPhaseAlignmentEnabled {
                return .keepsPlaying("the sub phase all-pass needs physical routing, which is off.")
            }
            return .nothingToCarry
        }
        guard bass.enabled else { return .nothingToCarry }
        guard SystemArrangementMigration.derive(from: state, detectedChannelCount: detectedChannelCount) != nil else {
            return .keepsPlaying("no speaker arrangement describes this crossover.")
        }
        return .arrangement
    }

    /// The arrangement's mono-bass filter a legacy topology stands for (Linkwitz-Riley 24 or 48).
    static func monoBassFilter(for topology: CrossoverTopology) -> MonoBassFilter {
        MonoBassFilter(family: .linkwitzRiley, slopeDBPerOctave: topology == .linkwitzRiley48 ? 48 : 24)
    }

    /// One line for the read-only summary of settings that keep playing as stored.
    static func summary(of bass: BassManagementConfiguration, reason: String) -> String {
        var parts = ["\(Int(bass.frequencyHz.rounded())) Hz", bass.topology.displayName]
        if bass.subGainDB != 0 { parts.append(String(format: "sub gain %.1f dB", bass.subGainDB)) }
        if bass.subPolarityInverted { parts.append("sub polarity inverted") }
        if bass.subPhaseAlignmentEnabled {
            parts.append(String(
                format: "sub phase %d Hz, Q %.2f", Int(bass.subPhaseAlignmentFrequencyHz.rounded()), bass.subPhaseAlignmentQ))
        }
        return "Older bass settings keep playing as stored (\(parts.joined(separator: ", "))). "
            + "They are shown for reference and are not edited here: \(reason)"
    }

    /// Stores the arrangement that carries the logical crossover when none is stored yet. Idempotent. Returns the outcome.
    @MainActor
    @discardableResult
    static func carry(profiles: ProductProfileController, detectedChannelCount: Int) throws -> Outcome {
        guard let state = profiles.selectedSystemProfile?.state else { return .nothingToCarry }
        let outcome = outcome(for: state, detectedChannelCount: detectedChannelCount)
        if outcome == .arrangement, state.systemArrangement == nil,
           let derived = SystemArrangementMigration.derive(from: state, detectedChannelCount: detectedChannelCount) {
            try profiles.replaceSelectedSystemArrangement(derived)
        }
        return outcome
    }
}
