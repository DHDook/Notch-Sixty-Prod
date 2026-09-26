from pathlib import Path

ROOT = Path('.')


def read(path):
    return (ROOT / path).read_text()


def write(path, text):
    (ROOT / path).write_text(text)


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'{label}: expected exactly one match, found {count}')
    return text.replace(old, new, 1)


# 1. Raise the realtime Dynamic EQ capacity to the commercial EQ capacity.
path = 'NotchSixty/Audio/Realtime/N60DynamicEQ.h'
text = read(path)
text = replace_once(text, '#define N60_DYNAMIC_EQ_MAX_BANDS 16u', '#define N60_DYNAMIC_EQ_MAX_BANDS 64u', 'dynamic eq capacity')
write(path, text)

# 2. Expose Dynamic EQ as an EQ-stage processing call rather than a core-dynamics stage.
path = 'NotchSixty/Audio/Realtime/N60Dynamics.h'
text = read(path)
needle = '''void N60DynamicsProcessPreEQStereoFrame(
    N60DynamicsRuntime * _Nonnull runtime,
    N60DynamicsSnapshot snapshot,
    float * _Nonnull left,
    float * _Nonnull right
);
'''
replacement = needle + '''void N60DynamicsProcessDynamicEQStereoFrame(
    N60DynamicsRuntime * _Nonnull runtime,
    N60DynamicsSnapshot snapshot,
    float * _Nonnull left,
    float * _Nonnull right
);
'''
text = replace_once(text, needle, replacement, 'dynamic eq stage declaration')
write(path, text)

path = 'NotchSixty/Audio/Realtime/N60Dynamics.c'
text = read(path)
text = replace_once(
    text,
    '    process_dialogue_leveler(runtime, snapshot, left, right);\n    N60DynamicEQProcessStereoFrame(&runtime->dynamicEQ, snapshot.dynamicEQ, left, right);\n    process_de_harsh(runtime, snapshot, left, right);',
    '    process_dialogue_leveler(runtime, snapshot, left, right);\n    process_de_harsh(runtime, snapshot, left, right);',
    'remove dynamic eq from core dynamics'
)
anchor = '''void N60DynamicsProcessCoreStereoFrameWithMasterGain(
    N60DynamicsRuntime *runtime,
'''
wrapper = '''void N60DynamicsProcessDynamicEQStereoFrame(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    if (runtime == NULL || left == NULL || right == NULL) return;
    N60DynamicEQProcessStereoFrame(&runtime->dynamicEQ, snapshot.dynamicEQ, left, right);
}

'''
text = replace_once(text, anchor, wrapper + anchor, 'dynamic eq stage implementation')
write(path, text)

path = 'NotchSixty/Audio/Realtime/N60RenderKernel.c'
text = read(path)
old = '''            advance_eq_transitions(kernel);
        }

        if (context->snapshot.convolution.enabled) {
'''
new = '''            advance_eq_transitions(kernel);
            // Dynamic EQ is a capability of the main parametric-EQ stage. Its
            // detector/gain engine remains independently implemented, but it is
            // evaluated here so enabling Dynamic does not move a band into the
            // later dynamics section of the graph.
            N60DynamicsProcessDynamicEQStereoFrame(
                &kernel->dynamicsRuntime,
                context->snapshot.dynamics,
                &left,
                &right
            );
        }

        if (context->snapshot.convolution.enabled) {
'''
text = replace_once(text, old, new, 'render graph dynamic eq placement')
write(path, text)

# 3. Make Dynamic an attribute of the normal EQ-band product model.
path = 'NotchSixty/Audio/AudioIOEngine.swift'
text = read(path)
old_band = '''struct EQBand: Identifiable, Equatable, Sendable {
    let id: UUID
    var enabled: Bool
    var type: EQFilterType
    var frequencyHz: Double
    var gainDB: Double
    var q: Double

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        type: EQFilterType = .peaking,
        frequencyHz: Double = 1_000,
        gainDB: Double = 0,
        q: Double = 0.707
    ) {
        self.id = id
        self.enabled = enabled
        self.type = type
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
    }
}
'''
new_band = '''struct EQBandDynamicConfiguration: Equatable, Sendable {
    static let thresholdRange = -60.0...0.0
    static let ratioRange = 1.0...10.0
    static let rangeRange = -24.0...0.0
    static let attackRange = 1.0...100.0
    static let releaseRange = 10.0...1_000.0
    static let boostThresholdRange = -60.0...0.0
    static let boostRatioRange = 1.0...10.0
    static let maxBoostRange = 0.0...12.0
    static let rmsWindowRange = 5.0...200.0

    var enabled = false
    var thresholdDB = -24.0
    var ratio = 2.0
    var rangeDB = -24.0
    var attackMs = 10.0
    var releaseMs = 100.0
    var direction: DynamicEQDirection = .cutOnly
    var boostThresholdDB = -40.0
    var boostRatio = 2.0
    var maxBoostDB = 6.0
    var detectorMode: DynamicEQDetectorMode = .peak
    var rmsWindowMs = 50.0

    var isValid: Bool {
        thresholdDB.isFinite && Self.thresholdRange.contains(thresholdDB)
            && ratio.isFinite && Self.ratioRange.contains(ratio)
            && rangeDB.isFinite && Self.rangeRange.contains(rangeDB)
            && attackMs.isFinite && Self.attackRange.contains(attackMs)
            && releaseMs.isFinite && Self.releaseRange.contains(releaseMs)
            && boostThresholdDB.isFinite && Self.boostThresholdRange.contains(boostThresholdDB)
            && boostRatio.isFinite && Self.boostRatioRange.contains(boostRatio)
            && maxBoostDB.isFinite && Self.maxBoostRange.contains(maxBoostDB)
            && rmsWindowMs.isFinite && Self.rmsWindowRange.contains(rmsWindowMs)
    }
}

struct EQBand: Identifiable, Equatable, Sendable {
    let id: UUID
    var enabled: Bool
    var type: EQFilterType
    var frequencyHz: Double
    var gainDB: Double
    var q: Double
    var dynamic: EQBandDynamicConfiguration

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        type: EQFilterType = .peaking,
        frequencyHz: Double = 1_000,
        gainDB: Double = 0,
        q: Double = 0.707,
        dynamic: EQBandDynamicConfiguration = EQBandDynamicConfiguration()
    ) {
        self.id = id
        self.enabled = enabled
        self.type = type
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
        self.dynamic = dynamic
    }
}
'''
text = replace_once(text, old_band, new_band, 'EQBand product model')

old_validate = '''    private func validateBand(_ band: EQBand, index: Int, sampleRate: Double) throws -> Bool {
        guard band.frequencyHz.isFinite,
              band.frequencyHz > 0,
              band.gainDB.isFinite,
              StereoEQConfiguration.bandGainRange.contains(band.gainDB),
              band.q.isFinite,
              band.q > 0 else {
            throw EQConfigurationError.invalidBand(index: index)
        }
        return band.frequencyHz < sampleRate * 0.5
    }
'''
new_validate = '''    private func validateBand(_ band: EQBand, index: Int, sampleRate: Double) throws -> Bool {
        guard band.frequencyHz.isFinite,
              band.frequencyHz > 0,
              band.gainDB.isFinite,
              StereoEQConfiguration.bandGainRange.contains(band.gainDB),
              band.q.isFinite,
              band.q > 0 else {
            throw EQConfigurationError.invalidBand(index: index)
        }
        if band.dynamic.enabled {
            guard band.type == .peaking,
                  DynamicEQBandConfiguration.frequencyRange.contains(band.frequencyHz),
                  DynamicEQBandConfiguration.qRange.contains(band.q),
                  band.dynamic.isValid else {
                throw EQConfigurationError.invalidBand(index: index)
            }
        }
        return band.frequencyHz < sampleRate * 0.5
    }
'''
text = replace_once(text, old_validate, new_validate, 'legacy EQ validation dynamic support')

crossover_anchor = '''        guard N60DSPGraphSnapshotSetCrossover(
            &graph,
'''
legacy_dynamic_compile = '''        if phaseMode == .minimumPhase && !bypassed {
            let dynamicBands = bands.filter { $0.enabled && $0.type == .peaking && $0.dynamic.enabled }
            if !dynamicBands.isEmpty {
                guard N60DynamicsSnapshotSetDynamicEQEnabled(&graph.dynamics, true) else {
                    throw DynamicsConfigurationError.invalidDynamicEQ
                }
                for (index, band) in dynamicBands.enumerated() {
                    let dynamic = band.dynamic
                    guard N60DynamicsSnapshotSetDynamicEQBand(
                        &graph.dynamics,
                        sampleRate,
                        UInt32(index),
                        true,
                        band.frequencyHz,
                        Float(band.q),
                        0.0,
                        Float(dynamic.thresholdDB),
                        Float(dynamic.ratio),
                        Float(dynamic.rangeDB),
                        Float(dynamic.attackMs),
                        Float(dynamic.releaseMs),
                        dynamic.direction.cType,
                        Float(dynamic.boostThresholdDB),
                        Float(dynamic.boostRatio),
                        Float(dynamic.maxBoostDB),
                        dynamic.detectorMode.cType,
                        Float(dynamic.rmsWindowMs)
                    ) else {
                        throw EQConfigurationError.invalidBand(index: index)
                    }
                }
            }
        }

'''
# This anchor occurs in EQConfiguration.makeGraphSnapshot before later methods.
pos = text.find(crossover_anchor)
if pos < 0:
    raise RuntimeError('legacy EQ dynamic compile anchor not found')
text = text[:pos] + legacy_dynamic_compile + text[pos:]

old_storage = '''    private func validateStereoEQStorage(_ configuration: StereoEQConfiguration) throws {
        for bands in [configuration.linkedBands, configuration.leftBands, configuration.rightBands] {
            guard bands.count <= EQConfiguration.maximumBandCount else {
                throw EQConfigurationError.tooManyBands(bands.count)
            }
            for (index, band) in bands.enumerated() where band.enabled {
                guard band.frequencyHz.isFinite,
                      band.frequencyHz > 0,
                      band.gainDB.isFinite,
                      StereoEQConfiguration.bandGainRange.contains(band.gainDB),
                      band.q.isFinite,
                      band.q > 0 else {
                    throw EQConfigurationError.invalidBand(index: index)
                }
            }
        }
    }
'''
new_storage = '''    private func validateStereoEQStorage(_ configuration: StereoEQConfiguration) throws {
        for bands in [configuration.linkedBands, configuration.leftBands, configuration.rightBands] {
            guard bands.count <= EQConfiguration.maximumBandCount else {
                throw EQConfigurationError.tooManyBands(bands.count)
            }
            for (index, band) in bands.enumerated() where band.enabled {
                guard band.frequencyHz.isFinite,
                      band.frequencyHz > 0,
                      band.gainDB.isFinite,
                      StereoEQConfiguration.bandGainRange.contains(band.gainDB),
                      band.q.isFinite,
                      band.q > 0 else {
                    throw EQConfigurationError.invalidBand(index: index)
                }
                if band.dynamic.enabled {
                    guard band.type == .peaking,
                          DynamicEQBandConfiguration.frequencyRange.contains(band.frequencyHz),
                          DynamicEQBandConfiguration.qRange.contains(band.q),
                          band.dynamic.isValid else {
                        throw EQConfigurationError.invalidBand(index: index)
                    }
                }
            }
        }
    }
'''
text = replace_once(text, old_storage, new_storage, 'stereo EQ storage validation')
write(path, text)

# 4. Compile per-band Dynamic settings into the existing standalone C engine.
path = 'NotchSixty/Audio/StereoPlaybackControl.swift'
text = read(path)
old_validated = '''    private func validatedEnabledBands(_ bands: [EQBand], sampleRate: Double) throws -> [EQBand] {
        guard bands.count <= EQConfiguration.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(bands.count)
        }
        var result: [EQBand] = []
        result.reserveCapacity(bands.count)
        for (index, band) in bands.enumerated() where band.enabled {
            guard band.frequencyHz.isFinite,
                  band.frequencyHz > 0,
                  band.gainDB.isFinite,
                  Self.bandGainRange.contains(band.gainDB),
                  band.q.isFinite,
                  band.q > 0 else {
                throw EQConfigurationError.invalidBand(index: index)
            }
            if band.frequencyHz < sampleRate * 0.5 {
                result.append(band)
            }
        }
        return result
    }
'''
new_validated = '''    private func validatedEnabledBands(_ bands: [EQBand], sampleRate: Double) throws -> [EQBand] {
        guard bands.count <= EQConfiguration.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(bands.count)
        }
        var result: [EQBand] = []
        result.reserveCapacity(bands.count)
        for (index, band) in bands.enumerated() where band.enabled {
            guard band.frequencyHz.isFinite,
                  band.frequencyHz > 0,
                  band.gainDB.isFinite,
                  Self.bandGainRange.contains(band.gainDB),
                  band.q.isFinite,
                  band.q > 0 else {
                throw EQConfigurationError.invalidBand(index: index)
            }
            if band.dynamic.enabled {
                guard band.type == .peaking,
                      DynamicEQBandConfiguration.frequencyRange.contains(band.frequencyHz),
                      DynamicEQBandConfiguration.qRange.contains(band.q),
                      band.dynamic.isValid else {
                    throw EQConfigurationError.invalidBand(index: index)
                }
            }
            if band.frequencyHz < sampleRate * 0.5 {
                result.append(band)
            }
        }
        return result
    }
'''
text = replace_once(text, old_validated, new_validated, 'validated enabled bands')

start = text.index('    private func conservativeAutomaticHeadroomDB(')
end = text.index('    func makeGraphSnapshot(', start)
old_headroom = text[start:end]
new_headroom = '''    private func conservativeAutomaticHeadroomDB(
        dynamics: DynamicsConfiguration
    ) -> Double {
        guard dynamics.automaticHeadroom.enabled else { return 0 }

        func channelBoost(_ bands: [EQBand]) -> Double {
            bands.lazy.filter(\\.enabled).reduce(0.0) { partial, band in
                partial + max(0.0, band.gainDB)
            }
        }
        let staticBoost: Double
        if bypassed {
            staticBoost = 0
        } else {
            switch channelMode {
            case .linked: staticBoost = channelBoost(linkedBands)
            case .independent: staticBoost = max(channelBoost(leftBands), channelBoost(rightBands))
            }
        }

        let dynamicBoost: Double
        if phaseMode == .minimumPhase && !bypassed && channelMode == .linked {
            dynamicBoost = linkedBands.lazy
                .filter { $0.enabled && $0.type == .peaking && $0.dynamic.enabled }
                .reduce(0.0) { partial, band in
                    let dynamicPart = band.dynamic.direction == .cutOnly ? 0.0 : max(0.0, band.dynamic.maxBoostDB)
                    return partial + dynamicPart
                }
        } else {
            dynamicBoost = 0
        }
        return min(dynamics.automaticHeadroom.maxAttenuationDB, staticBoost + dynamicBoost)
    }

    private func compileUnifiedDynamicEQ(
        into dynamics: inout DynamicsConfiguration,
        sampleRate: Double
    ) throws {
        // Product state is owned by the normal EQ bands. Keep the standalone C
        // Dynamic EQ engine as an implementation detail and compile only the
        // linked minimum-phase peaking bands that have Dynamic enabled.
        dynamics.dynamicEQ = DynamicEQConfiguration()
        guard phaseMode == .minimumPhase,
              !bypassed,
              channelMode == .linked else { return }

        let dynamicBands = try validatedEnabledBands(linkedBands, sampleRate: sampleRate)
            .filter { $0.type == .peaking && $0.dynamic.enabled }
        guard dynamicBands.count <= DynamicEQConfiguration.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(dynamicBands.count)
        }
        dynamics.dynamicEQ.enabled = !dynamicBands.isEmpty
        dynamics.dynamicEQ.bands = dynamicBands.map { band in
            let dynamic = band.dynamic
            var compiled = DynamicEQBandConfiguration()
            compiled.enabled = true
            compiled.frequencyHz = band.frequencyHz
            compiled.q = band.q
            // Static gain remains in the normal EQ biquad. The Dynamic engine
            // contributes only the time-varying delta, so enabling Dynamic does
            // not change the band's static response at the neutral operating point.
            compiled.staticGainDB = 0
            compiled.thresholdDB = dynamic.thresholdDB
            compiled.ratio = dynamic.ratio
            compiled.rangeDB = dynamic.rangeDB
            compiled.attackMs = dynamic.attackMs
            compiled.releaseMs = dynamic.releaseMs
            compiled.direction = dynamic.direction
            compiled.boostThresholdDB = dynamic.boostThresholdDB
            compiled.boostRatio = dynamic.boostRatio
            compiled.maxBoostDB = dynamic.maxBoostDB
            compiled.detectorMode = dynamic.detectorMode
            compiled.rmsWindowMs = dynamic.rmsWindowMs
            return compiled
        }
    }

'''
text = text[:start] + new_headroom + text[end:]

snapshot_anchor = '''        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
'''
compiled_insert = '''        var compiledDynamics = dynamicsConfiguration
        try compileUnifiedDynamicEQ(into: &compiledDynamics, sampleRate: sampleRate)

'''
text = replace_once(text, snapshot_anchor, compiled_insert + snapshot_anchor, 'compile unified dynamic eq')
text = replace_once(
    text,
    '        graph.dynamics = try dynamicsConfiguration.makeSnapshot(sampleRate: sampleRate)\n        graph.protection = try dynamicsConfiguration.makeProtectionSnapshot(sampleRate: sampleRate)',
    '        graph.dynamics = try compiledDynamics.makeSnapshot(sampleRate: sampleRate)\n        graph.protection = try compiledDynamics.makeProtectionSnapshot(sampleRate: sampleRate)',
    'publish compiled dynamics'
)
write(path, text)

# 5. Engineering UI: Dynamic is edited on the ordinary EQ row.
path = 'NotchSixty/ContentView.swift'
text = read(path)
helper_start = text.index('    private func dynamicEQBandBinding<Value>(')
helper_end = text.index('    @ViewBuilder\n    private var dynamicsValidationView', helper_start)
text = text[:helper_start] + text[helper_end:]
text = replace_once(text, '        let dynamicEQEnabled = dynamicsBinding(\\.dynamicEQ.enabled)\n', '', 'remove separate dynamic eq binding')

group_start = text.index('            GroupBox("General Dynamic EQ") {')
group_end = text.index('            GroupBox("Gain / protection integration") {', group_start)
new_group = '''            GroupBox("Dynamic EQ integration") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dynamic EQ is now configured on the normal Parametric EQ bands below rather than in a separate band bank.")
                    Text("Commercial capacity: up to \\(EQConfiguration.maximumBandCount) EQ bands. Dynamic is available for linked, minimum-phase Peak bands; the standalone C detector/gain engine remains an internal implementation detail.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

'''
text = text[:group_start] + new_group + text[group_end:]

row_start = text.index('    @ViewBuilder\n    private func eqBandRow(index: Int, band: EQBand) -> some View {')
row_end = text.index('    private func eqBandBinding(for id: UUID) -> Binding<EQBand> {', row_start)
new_row = '''    @ViewBuilder
    private func eqBandRow(index: Int, band: EQBand) -> some View {
        let binding = eqBandBinding(for: band.id)
        let dynamicSupported = engine.eqConfiguration.phaseMode == .minimumPhase
            && engine.stereoEQConfiguration.channelMode == .linked
            && band.type == .peaking

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\\(index + 1)").frame(width: 24, alignment: .trailing).foregroundStyle(.secondary)
                Toggle("", isOn: binding.enabled).labelsHidden()
                Picker("", selection: binding.type) {
                    ForEach(EQFilterType.allCases) { type in Text(type.displayName).tag(type) }
                }
                .labelsHidden()
                .frame(width: 115)
                TextField("Hz", value: binding.frequencyHz, format: .number.precision(.fractionLength(0...1))).frame(width: 85)
                Text("Hz").foregroundStyle(.secondary)
                TextField("dB", value: binding.gainDB, format: .number.precision(.fractionLength(1))).frame(width: 65)
                Text("dB").font(.caption).foregroundStyle(.secondary)
                TextField("Q", value: binding.q, format: .number.precision(.fractionLength(2...3))).frame(width: 65)
                Text("Q").foregroundStyle(.secondary)
                Toggle("Dynamic", isOn: binding.dynamic.enabled)
                    .toggleStyle(.switch)
                    .disabled(!dynamicSupported)
                Spacer()
                Button("Remove") { try? engine.removeEQBand(id: band.id) }
            }

            if binding.wrappedValue.dynamic.enabled && dynamicSupported {
                HStack(spacing: 8) {
                    Text("Dynamic").frame(width: 82, alignment: .leading).foregroundStyle(.secondary)
                    Picker("Direction", selection: binding.dynamic.direction) {
                        ForEach(DynamicEQDirection.allCases) { value in Text(value.displayName).tag(value) }
                    }.frame(width: 165)
                    Text("Threshold")
                    Slider(value: binding.dynamic.thresholdDB, in: EQBandDynamicConfiguration.thresholdRange, step: 0.5).frame(width: 100)
                    Text("\\(binding.wrappedValue.dynamic.thresholdDB, specifier: \"%.1f\") dB").monospacedDigit().frame(width: 64)
                    Text("Ratio")
                    Slider(value: binding.dynamic.ratio, in: EQBandDynamicConfiguration.ratioRange, step: 0.1).frame(width: 80)
                    Text("\\(binding.wrappedValue.dynamic.ratio, specifier: \"%.1f\")")
                    Text("Max cut")
                    Slider(value: binding.dynamic.rangeDB, in: EQBandDynamicConfiguration.rangeRange, step: 0.5).frame(width: 90)
                }
                HStack(spacing: 8) {
                    Text("Timing").frame(width: 82, alignment: .leading).foregroundStyle(.secondary)
                    Text("Attack")
                    Slider(value: binding.dynamic.attackMs, in: EQBandDynamicConfiguration.attackRange, step: 1).frame(width: 90)
                    Text("Release")
                    Slider(value: binding.dynamic.releaseMs, in: EQBandDynamicConfiguration.releaseRange, step: 5).frame(width: 100)
                    Picker("Detector", selection: binding.dynamic.detectorMode) {
                        ForEach(DynamicEQDetectorMode.allCases) { value in Text(value.displayName).tag(value) }
                    }.frame(width: 145)
                    if binding.wrappedValue.dynamic.detectorMode == .rms {
                        Text("RMS window")
                        Slider(value: binding.dynamic.rmsWindowMs, in: EQBandDynamicConfiguration.rmsWindowRange, step: 5).frame(width: 100)
                    }
                }
                if binding.wrappedValue.dynamic.direction != .cutOnly {
                    HStack(spacing: 8) {
                        Text("Boost").frame(width: 82, alignment: .leading).foregroundStyle(.secondary)
                        Text("Threshold")
                        Slider(value: binding.dynamic.boostThresholdDB, in: EQBandDynamicConfiguration.boostThresholdRange, step: 0.5).frame(width: 110)
                        Text("Ratio")
                        Slider(value: binding.dynamic.boostRatio, in: EQBandDynamicConfiguration.boostRatioRange, step: 0.1).frame(width: 90)
                        Text("Max")
                        Slider(value: binding.dynamic.maxBoostDB, in: EQBandDynamicConfiguration.maxBoostRange, step: 0.5).frame(width: 100)
                        Text("\\(binding.wrappedValue.dynamic.maxBoostDB, specifier: \"%.1f\") dB").monospacedDigit().frame(width: 62)
                    }
                }
            } else if band.dynamic.enabled {
                Text("Dynamic is inactive for this band. Use Linked + Minimum phase + Peak to enable dynamic operation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 40)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

'''
text = text[:row_start] + new_row + text[row_end:]
text = replace_once(text, '.frame(maxHeight: 150)', '.frame(maxHeight: 420)', 'EQ editor height')
old_setter = '''                var sanitized = updated
                sanitized.gainDB = min(
                    max(updated.gainDB, StereoEQConfiguration.bandGainRange.lowerBound),
                    StereoEQConfiguration.bandGainRange.upperBound
                )
                try? engine.updateEQBand(sanitized)
'''
new_setter = '''                var sanitized = updated
                sanitized.gainDB = min(
                    max(updated.gainDB, StereoEQConfiguration.bandGainRange.lowerBound),
                    StereoEQConfiguration.bandGainRange.upperBound
                )
                if sanitized.type != .peaking {
                    sanitized.dynamic.enabled = false
                }
                try? engine.updateEQBand(sanitized)
'''
text = replace_once(text, old_setter, new_setter, 'disable dynamic for unsupported filter types')
write(path, text)

# 6. Tests: exercise standalone engine at its EQ-stage entry point and 64-band capacity.
path = 'NotchSixtyTests/DynamicsTests.swift'
text = read(path)
for name in [
    'testDynamicEQDisabledIsTransparentWithConfiguredBand',
    'testDynamicEQCutOnlyAttenuatesInBandAndStaysLinked',
    'testDynamicEQBoostIsBounded',
]:
    start = text.index(f'    func {name}')
    next_func = text.find('\n    func ', start + 10)
    if next_func < 0:
        next_func = len(text)
    block = text[start:next_func]
    block_new = block.replace('N60DynamicsProcessCoreStereoFrame(&runtime, snapshot, &left, &right)', 'N60DynamicsProcessDynamicEQStereoFrame(&runtime, snapshot, &left, &right)')
    if block == block_new:
        raise RuntimeError(f'{name}: dynamic stage call not found')
    text = text[:start] + block_new + text[next_func:]
text = text.replace('testDynamicEQConfigurationRejectsInvalidBandAndSupportsSixteenBandsAt384k', 'testDynamicEQConfigurationRejectsInvalidBandAndSupportsSixtyFourBandsAt384k')
text = replace_once(text, '        config.dynamicEQ.bands = (0..<16).map { index in', '        config.dynamicEQ.bands = (0..<64).map { index in', '64-band dynamics test setup')
text = replace_once(text, '        XCTAssertEqual(snapshot.dynamicEQ.bandCount, 16)', '        XCTAssertEqual(snapshot.dynamicEQ.bandCount, 64)', '64-band dynamics assertion')
write(path, text)

path = 'NotchSixtyTests/StereoPlaybackControlTests.swift'
text = read(path)
insert_at = text.rfind('\n}')
if insert_at < 0:
    raise RuntimeError('StereoPlaybackControlTests closing brace not found')
new_tests = '''

    func testUnifiedDynamicEQCompilesFromMainEQBandsAtFullCapacity() throws {
        let count = EQConfiguration.maximumBandCount
        XCTAssertEqual(count, 64)
        let minimumFrequency = 30.0
        let maximumFrequency = 18_000.0
        let ratio = maximumFrequency / minimumFrequency
        let bands = (0..<count).map { index -> EQBand in
            let position = count > 1 ? Double(index) / Double(count - 1) : 0
            var dynamic = EQBandDynamicConfiguration()
            dynamic.enabled = true
            dynamic.direction = index.isMultiple(of: 2) ? .cutOnly : .both
            dynamic.maxBoostDB = 3
            return EQBand(
                enabled: true,
                type: .peaking,
                frequencyHz: minimumFrequency * pow(ratio, position),
                gainDB: index.isMultiple(of: 2) ? 0.25 : -0.25,
                q: 1.0,
                dynamic: dynamic
            )
        }
        let config = StereoEQConfiguration(linkedBands: bands)
        let graph = try config.makeGraphSnapshot(
            sampleRate: 384_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            dynamicsConfiguration: DynamicsConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertEqual(graph.eqBandCount, 64)
        XCTAssertEqual(graph.dynamics.dynamicEQ.bandCount, 64)
        XCTAssertTrue(graph.dynamics.dynamicEQ.enabled)
        XCTAssertTrue(N60DynamicEQSnapshotIsValid(graph.dynamics.dynamicEQ))
    }

    func testUnifiedDynamicEQIsAnEQStageCapabilityNotASeparateConfiguredBank() throws {
        var dynamic = EQBandDynamicConfiguration()
        dynamic.enabled = true
        dynamic.thresholdDB = -30
        dynamic.ratio = 4
        let band = EQBand(
            type: .peaking,
            frequencyHz: 1_000,
            gainDB: 3,
            q: 1.0,
            dynamic: dynamic
        )
        var staleDynamics = DynamicsConfiguration()
        staleDynamics.dynamicEQ.enabled = true
        staleDynamics.dynamicEQ.bands = [DynamicEQBandConfiguration(frequencyHz: 8_000)]
        let config = StereoEQConfiguration(linkedBands: [band])
        let graph = try config.makeGraphSnapshot(
            sampleRate: 96_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            dynamicsConfiguration: staleDynamics,
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertEqual(graph.eqBandCount, 1)
        XCTAssertEqual(graph.dynamics.dynamicEQ.bandCount, 1)
        XCTAssertTrue(graph.dynamics.dynamicEQ.enabled)
    }
'''
# Avoid relying on a synthesized memberwise init for DynamicEQBandConfiguration.
new_tests = new_tests.replace('        staleDynamics.dynamicEQ.bands = [DynamicEQBandConfiguration(frequencyHz: 8_000)]\n', '''        var staleBand = DynamicEQBandConfiguration()\n        staleBand.frequencyHz = 8_000\n        staleDynamics.dynamicEQ.bands = [staleBand]\n''')
text = text[:insert_at] + new_tests + text[insert_at:]
write(path, text)

# 7. Documentation and provenance.
path = 'docs/PR33_RESIDUAL_DYNAMICS_PARITY.md'
text = read(path)
text = replace_once(text, '- maximum 16 fixed/preallocated band runtimes', '- maximum 64 fixed/preallocated band runtimes, matching the commercial main-EQ capacity', 'PR33 commercial capacity doc')
text = replace_once(text, '- 16-band worst case remains finite through supported high sample rates', '- 64-dynamic-band worst case remains finite through supported high sample rates', 'PR33 acceptance capacity doc')
legacy_line = '- RMS detector window, default 50 ms, observable range 5…200 ms\n\nThe legacy state default direction is Cut Only and default detector mode is Peak.\n'
legacy_replacement = '''- RMS detector window, default 50 ms, observable range 5…200 ms

The legacy state default direction is Cut Only and default detector mode is Peak. The historical state exposed up to 16 Dynamic EQ bands. The commercial product deliberately improves this: Dynamic is a capability of the normal EQ-band model and may be enabled on any supported linked minimum-phase Peak band, up to the commercial 64-band EQ capacity. The standalone `N60DynamicEQ` engine remains an internal realtime implementation detail.
'''
text = replace_once(text, legacy_line, legacy_replacement, 'PR33 unified product semantics doc')
write(path, text)

path = 'docs/PR33_FINAL_DYNAMICS_PARITY_AUDIT.md'
text = read(path)
text = replace_once(
    text,
    '- General Dynamic EQ up to 16 bands with cut/boost/both, Peak/RMS detection, RMS window, timing and bounded range.',
    '- General Dynamic EQ integrated into the normal EQ-band model, with cut/boost/both, Peak/RMS detection, RMS window, timing and bounded range. Commercial capacity is 64 supported dynamic Peak bands (improving the verified 16-band legacy state limit).',
    'final audit dynamic eq'
)
write(path, text)

path = 'docs/EQ_CONTROL_PLANE.md'
text = read(path)
append = '''

## PR33 Dynamic EQ integration

PR33 keeps the independently authored `N60DynamicEQ` detector/gain engine but makes Dynamic a capability of the normal EQ-band product model rather than a second user-visible band bank. Supported linked minimum-phase Peak bands can enable Dynamic controls directly. Static gain continues to be rendered by the established parametric-EQ biquad; the Dynamic engine contributes only the time-varying correction delta at the EQ stage, preserving the band's neutral static response when no dynamic correction is active.

The realtime Dynamic EQ capacity is 64 bands to match `N60_MAX_EQ_BANDS`. Disabled/non-dynamic EQ bands incur no Dynamic-EQ per-band processing. The 64-dynamic-band / 384 kHz case is a capacity stress target for the bounded optimization pass, not a recommended ordinary preset.
'''
if '## PR33 Dynamic EQ integration' not in text:
    text += append
write(path, text)

path = 'docs/PROVENANCE.md'
text = read(path)
append = '''

### PR33 Dynamic EQ integration refinement

After hardware acceptance of the initial PR33 processor, the commercial product model was refined so Dynamic EQ is enabled on ordinary EQ bands rather than exposed as a separate user-facing band bank. The verified historical 16-band limit remains recorded only as an observable legacy-state fact; the commercial implementation intentionally extends fixed capacity to 64 to match the proprietary main-EQ engine. The standalone `N60DynamicEQ` C detector/gain engine remains independently authored and is now invoked in the EQ portion of the commercial render graph. Static EQ gain remains in the proprietary main biquad stage and the Dynamic engine contributes only time-varying correction. This integration decision is product/architecture work authored in the commercial repository and does not reuse historical DSP implementation expression.
'''
if '### PR33 Dynamic EQ integration refinement' not in text:
    text += append
write(path, text)

print('PR33 Dynamic EQ unification patch applied.')
