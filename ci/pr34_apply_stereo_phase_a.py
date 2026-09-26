from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)


path = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
text = path.read_text()

# Validate Linkwitz's independent target parameters in the live stereo compiler.
text = replace_once(
    text,
    '''            if band.dynamic.enabled {
                guard band.type == .peaking,''',
    '''            if band.type == .linkwitzTransform {
                guard band.linkwitzTargetHz.isFinite,
                      band.linkwitzTargetHz > 0,
                      band.linkwitzTargetHz < sampleRate * 0.5,
                      band.linkwitzTargetQ.isFinite,
                      band.linkwitzTargetQ > 0 else {
                    throw EQConfigurationError.invalidBand(index: index)
                }
            }
            if band.dynamic.enabled {
                guard band.type == .peaking,''',
    "live Linkwitz validation",
)

# One live control-plane publication helper for ordinary, Constant-Q and Linkwitz bands.
helper = '''
    private func publishMinimumPhaseBand(
        _ band: EQBand,
        into graph: inout N60DSPGraphSnapshot,
        renderIndex: UInt32,
        channelMask: UInt8? = nil
    ) throws {
        let ok: Bool
        if band.type == .linkwitzTransform {
            guard let coefficients = band.linkwitzCoefficients(sampleRate: graph.sampleRate) else {
                throw EQConfigurationError.invalidBand(index: Int(renderIndex))
            }
            if let channelMask {
                ok = N60DSPGraphSnapshotSetEQPreparedBandForChannels(
                    &graph, renderIndex, channelMask, band.compiledCType,
                    band.frequencyHz, 0.0, band.q, coefficients, true
                )
            } else {
                ok = N60DSPGraphSnapshotSetEQPreparedBand(
                    &graph, renderIndex, band.compiledCType,
                    band.frequencyHz, 0.0, band.q, coefficients, true
                )
            }
        } else if let channelMask {
            ok = N60DSPGraphSnapshotSetEQBandForChannels(
                &graph, renderIndex, channelMask, band.compiledCType,
                band.frequencyHz, band.gainDB, band.q, true
            )
        } else {
            ok = N60DSPGraphSnapshotSetEQBand(
                &graph, renderIndex, band.compiledCType,
                band.frequencyHz, band.gainDB, band.q, true
            )
        }
        guard ok else { throw EQConfigurationError.invalidBand(index: Int(renderIndex)) }
    }

'''
if helper not in text:
    marker = '''    func makeGraphSnapshot(
'''
    if marker not in text:
        raise SystemExit("Expected live graph compiler insertion point was not found")
    text = text.replace(marker, helper + marker, 1)

old_linked = '''                for band in try validatedEnabledBands(linkedBands, sampleRate: sampleRate) {
                    guard N60DSPGraphSnapshotSetEQBand(
                        &graph,
                        renderIndex,
                        band.type.cType,
                        band.frequencyHz,
                        band.gainDB,
                        band.q,
                        true
                    ) else {
                        throw EQConfigurationError.invalidBand(index: Int(renderIndex))
                    }
                    renderIndex += 1
                }
'''
new_linked = '''                for band in try validatedEnabledBands(linkedBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(band, into: &graph, renderIndex: renderIndex)
                    renderIndex += 1
                }
'''
text = replace_once(text, old_linked, new_linked, "linked Phase A publication")

old_left = '''                for band in try validatedEnabledBands(leftBands, sampleRate: sampleRate) {
                    guard N60DSPGraphSnapshotSetEQBandForChannels(
                        &graph,
                        renderIndex,
                        UInt8(N60_EQ_CHANNEL_LEFT),
                        band.type.cType,
                        band.frequencyHz,
                        band.gainDB,
                        band.q,
                        true
                    ) else {
                        throw EQConfigurationError.invalidBand(index: Int(renderIndex))
                    }
                    renderIndex += 1
                }
'''
new_left = '''                for band in try validatedEnabledBands(leftBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                    renderIndex += 1
                }
'''
text = replace_once(text, old_left, new_left, "left Phase A publication")

old_right = '''                for band in try validatedEnabledBands(rightBands, sampleRate: sampleRate) {
                    guard N60DSPGraphSnapshotSetEQBandForChannels(
                        &graph,
                        renderIndex,
                        UInt8(N60_EQ_CHANNEL_RIGHT),
                        band.type.cType,
                        band.frequencyHz,
                        band.gainDB,
                        band.q,
                        true
                    ) else {
                        throw EQConfigurationError.invalidBand(index: Int(renderIndex))
                    }
                    renderIndex += 1
                }
'''
new_right = '''                for band in try validatedEnabledBands(rightBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                    renderIndex += 1
                }
'''
text = replace_once(text, old_right, new_right, "right Phase A publication")

old_linear = '''        return bands.map { band in
            var cBand = N60LinearPhaseEQBand()
            cBand.enabled = true
            cBand.type = band.type.cType
            cBand.frequencyHz = band.frequencyHz
            cBand.gainDB = band.gainDB
            cBand.q = band.q
            return cBand
        }
'''
new_linear = '''        return try bands.enumerated().map { index, band in
            var cBand = N60LinearPhaseEQBand()
            cBand.enabled = true
            cBand.type = band.compiledCType
            cBand.frequencyHz = band.frequencyHz
            cBand.gainDB = band.type == .linkwitzTransform ? 0.0 : band.gainDB
            cBand.q = band.q
            if band.type == .linkwitzTransform {
                guard let coefficients = band.linkwitzCoefficients(sampleRate: sampleRate) else {
                    throw EQConfigurationError.invalidBand(index: index)
                }
                cBand.usesPreparedCoefficients = true
                cBand.preparedCoefficients = coefficients
            }
            return cBand
        }
'''
text = replace_once(text, old_linear, new_linear, "live Linear-Phase Phase A projection")
path.write_text(text)

# Offline storage validation must reject bad Linkwitz target fields too.
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
marker = '''                if band.dynamic.enabled {
                    guard band.type == .peaking,
'''
replacement = '''                if band.type == .linkwitzTransform {
                    guard band.linkwitzTargetHz.isFinite,
                          band.linkwitzTargetHz > 0,
                          band.linkwitzTargetQ.isFinite,
                          band.linkwitzTargetQ > 0 else {
                        throw EQConfigurationError.invalidBand(index: index)
                    }
                }
                if band.dynamic.enabled {
                    guard band.type == .peaking,
'''
# The first occurrence belongs to EQConfiguration and already has sample-rate validation;
# target the later storage validator by replacing the last still-unaugmented occurrence.
if "private func validateStereoEQStorage" in engine:
    prefix, suffix = engine.split("private func validateStereoEQStorage", 1)
    if "band.type == .linkwitzTransform" not in suffix.split("private func applyStereoEQConfiguration", 1)[0]:
        if marker not in suffix:
            raise SystemExit("Expected stereo storage validation insertion point was not found")
        suffix = suffix.replace(marker, replacement, 1)
        engine = prefix + "private func validateStereoEQStorage" + suffix
engine_path.write_text(engine)

# Regress the actual live StereoEQConfiguration compiler, not just EQConfiguration.
tests_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = tests_path.read_text()
test = '''    func testLiveStereoCompilerPublishesConstantQAndLinkwitzInMinimumAndLinearPhase() throws {
        let constant = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 2.0, constantQ: true)
        let linkwitz = EQBand(
            type: .linkwitzTransform, frequencyHz: 50, gainDB: 0, q: 0.7,
            linkwitzTargetHz: 32, linkwitzTargetQ: 0.577
        )
        let minimum = StereoEQConfiguration(
            channelMode: .linked,
            phaseMode: .minimumPhase,
            linkedBands: [constant, linkwitz]
        )
        let graph = try minimum.makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertEqual(graph.eqBandCount, 2)
        XCTAssertEqual(graph.eqBands.0.type, N60BiquadFilterTypePeakingConstantQ)
        XCTAssertEqual(graph.eqBands.1.type, N60BiquadFilterTypeLinkwitzTransform)
        XCTAssertTrue(N60BiquadCoefficientsAreFinite(graph.eqBands.1.coefficients))

        var linear = minimum
        linear.phaseMode = .linearPhase
        let projected = try linear.linearPhaseBands(for: .linked, sampleRate: 48_000)
        XCTAssertEqual(projected.count, 2)
        XCTAssertEqual(projected[0].type, N60BiquadFilterTypePeakingConstantQ)
        XCTAssertEqual(projected[1].type, N60BiquadFilterTypeLinkwitzTransform)
        XCTAssertTrue(projected[1].usesPreparedCoefficients)
    }

'''
if test not in tests:
    marker = "    func testAllPassMaintainsUnityMagnitudeAcrossSupportedRates() {\n"
    if marker not in tests:
        raise SystemExit("Expected live stereo Phase A test insertion point was not found")
    tests = tests.replace(marker, test + marker, 1)
tests_path.write_text(tests)
