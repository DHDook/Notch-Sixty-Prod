from pathlib import Path

path = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
text = path.read_text()

validation_anchor = '''        guard bassManagementConfiguration.subGainDB.isFinite,
              BassManagementConfiguration.subGainRange.contains(bassManagementConfiguration.subGainDB) else {
            throw BassManagementConfigurationError.invalidSubGain(bassManagementConfiguration.subGainDB)
        }
'''
validation_block = validation_anchor + '''        guard bassManagementConfiguration.subPhaseAlignmentFrequencyHz.isFinite,
              BassManagementConfiguration.frequencyRange.contains(bassManagementConfiguration.subPhaseAlignmentFrequencyHz) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentFrequency(
                bassManagementConfiguration.subPhaseAlignmentFrequencyHz
            )
        }
        guard bassManagementConfiguration.subPhaseAlignmentQ.isFinite,
              BassManagementConfiguration.subPhaseAlignmentQRange.contains(bassManagementConfiguration.subPhaseAlignmentQ) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentQ(
                bassManagementConfiguration.subPhaseAlignmentQ
            )
        }
'''
if "bassManagementConfiguration.subPhaseAlignmentFrequencyHz.isFinite" not in text:
    if validation_anchor not in text:
        raise SystemExit("Expected stereo bass-management validation anchor was not found")
    text = text.replace(validation_anchor, validation_block, 1)

crossover_anchor = '''        guard N60DSPGraphSnapshotSetCrossover(
            &graph,
            bassManagementConfiguration.frequencyHz,
            bassManagementConfiguration.topology.cType,
            bassManagementConfiguration.monitorMode.cType,
            DSPGainConfiguration.linearGain(forDB: bassManagementConfiguration.subGainDB),
            bassManagementConfiguration.subPolarityInverted,
            bassManagementConfiguration.enabled
        ) else {
            throw BassManagementConfigurationError.graphDesignFailed
        }
        graph.dynamics = try compiledDynamics.makeSnapshot(sampleRate: sampleRate)
'''
crossover_block = '''        guard N60DSPGraphSnapshotSetCrossover(
            &graph,
            bassManagementConfiguration.frequencyHz,
            bassManagementConfiguration.topology.cType,
            bassManagementConfiguration.monitorMode.cType,
            DSPGainConfiguration.linearGain(forDB: bassManagementConfiguration.subGainDB),
            bassManagementConfiguration.subPolarityInverted,
            bassManagementConfiguration.enabled
        ) else {
            throw BassManagementConfigurationError.graphDesignFailed
        }
        guard N60DSPGraphSnapshotSetSubPhaseAlignment(
            &graph,
            bassManagementConfiguration.subPhaseAlignmentFrequencyHz,
            bassManagementConfiguration.subPhaseAlignmentQ,
            bassManagementConfiguration.subPhaseAlignmentEnabled
        ) else {
            throw BassManagementConfigurationError.graphDesignFailed
        }
        graph.dynamics = try compiledDynamics.makeSnapshot(sampleRate: sampleRate)
'''
if "N60DSPGraphSnapshotSetSubPhaseAlignment(" not in text:
    if crossover_anchor not in text:
        raise SystemExit("Expected stereo crossover publication anchor was not found")
    text = text.replace(crossover_anchor, crossover_block, 1)

path.write_text(text)
print("PR34 sub-phase validation/publication is present in StereoEQConfiguration.")
