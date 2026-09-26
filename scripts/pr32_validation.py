from pathlib import Path


def replace_once(path, old, new):
    p=Path(path); s=p.read_text()
    if old not in s: raise SystemExit(f'pattern not found in {path}: {old[:120]!r}')
    p.write_text(s.replace(old,new,1))

# ---- diagnostics bridge -------------------------------------------------
h='NotchSixty/Audio/Realtime/N60RenderKernel.h'
replace_once(h,
'''    float loudnessContourScale;
    bool compressorEnabled;
''',
'''    float loudnessContourScale;
    float dialogueProgramLevelDBFS;
    float dialogueBandLevelDBFS;
    float dialogueGapDB;
    float dialogueVoiceConfidence;
    float dialogueBoostDB;
    bool compressorEnabled;
''')

c='NotchSixty/Audio/Realtime/N60RenderKernel.c'
replace_once(c,
'''    _Atomic uint32_t loudnessContourScaleBits;
    _Atomic uint32_t compressorGainReductionBits;
''',
'''    _Atomic uint32_t loudnessContourScaleBits;
    _Atomic uint32_t dialogueProgramLevelBits;
    _Atomic uint32_t dialogueBandLevelBits;
    _Atomic uint32_t dialogueGapBits;
    _Atomic uint32_t dialogueVoiceConfidenceBits;
    _Atomic uint32_t dialogueBoostBits;
    _Atomic uint32_t compressorGainReductionBits;
''')
replace_once(c,
'''    atomic_store_explicit(&kernel->denoiserSpectralFramesProcessed, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->inputPeakLeftBits, 0, memory_order_relaxed);
''',
'''    atomic_store_explicit(&kernel->denoiserSpectralFramesProcessed, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->dialogueProgramLevelBits, float_to_bits(-120.0f), memory_order_relaxed);
    atomic_store_explicit(&kernel->dialogueBandLevelBits, float_to_bits(-120.0f), memory_order_relaxed);
    atomic_store_explicit(&kernel->dialogueGapBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->dialogueVoiceConfidenceBits, float_to_bits(1.0f), memory_order_relaxed);
    atomic_store_explicit(&kernel->dialogueBoostBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->inputPeakLeftBits, 0, memory_order_relaxed);
''')
replace_once(c,
'''        atomic_store_explicit(&kernel->loudnessContourScaleBits, float_to_bits(telemetry.loudnessContourScale), memory_order_relaxed);
        atomic_store_explicit(&kernel->compressorGainReductionBits, float_to_bits(telemetry.compressorGainReductionDB), memory_order_relaxed);
''',
'''        atomic_store_explicit(&kernel->loudnessContourScaleBits, float_to_bits(telemetry.loudnessContourScale), memory_order_relaxed);
        atomic_store_explicit(&kernel->dialogueProgramLevelBits, float_to_bits(telemetry.dialogueProgramLevelDBFS), memory_order_relaxed);
        atomic_store_explicit(&kernel->dialogueBandLevelBits, float_to_bits(telemetry.dialogueBandLevelDBFS), memory_order_relaxed);
        atomic_store_explicit(&kernel->dialogueGapBits, float_to_bits(telemetry.dialogueGapDB), memory_order_relaxed);
        atomic_store_explicit(&kernel->dialogueVoiceConfidenceBits, float_to_bits(telemetry.dialogueVoiceConfidence), memory_order_relaxed);
        atomic_store_explicit(&kernel->dialogueBoostBits, float_to_bits(telemetry.dialogueBoostDB), memory_order_relaxed);
        atomic_store_explicit(&kernel->compressorGainReductionBits, float_to_bits(telemetry.compressorGainReductionDB), memory_order_relaxed);
''')
replace_once(c,
'''    diagnostics.loudnessContourScale = bits_to_float(atomic_load_explicit(&kernel->loudnessContourScaleBits, memory_order_relaxed));
    diagnostics.compressorGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->compressorGainReductionBits, memory_order_relaxed));
''',
'''    diagnostics.loudnessContourScale = bits_to_float(atomic_load_explicit(&kernel->loudnessContourScaleBits, memory_order_relaxed));
    diagnostics.dialogueProgramLevelDBFS = bits_to_float(atomic_load_explicit(&kernel->dialogueProgramLevelBits, memory_order_relaxed));
    diagnostics.dialogueBandLevelDBFS = bits_to_float(atomic_load_explicit(&kernel->dialogueBandLevelBits, memory_order_relaxed));
    diagnostics.dialogueGapDB = bits_to_float(atomic_load_explicit(&kernel->dialogueGapBits, memory_order_relaxed));
    diagnostics.dialogueVoiceConfidence = bits_to_float(atomic_load_explicit(&kernel->dialogueVoiceConfidenceBits, memory_order_relaxed));
    diagnostics.dialogueBoostDB = bits_to_float(atomic_load_explicit(&kernel->dialogueBoostBits, memory_order_relaxed));
    diagnostics.compressorGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->compressorGainReductionBits, memory_order_relaxed));
''')

sw='NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift'
replace_once(sw,
'''    let loudnessContourScale: Float
    let compressorEnabled: Bool
''',
'''    let loudnessContourScale: Float
    let dialogueProgramLevelDBFS: Float
    let dialogueBandLevelDBFS: Float
    let dialogueGapDB: Float
    let dialogueVoiceConfidence: Float
    let dialogueBoostDB: Float
    let compressorEnabled: Bool
''')
replace_once(sw,
'''        loudnessContourScale = diagnostics.loudnessContourScale
        compressorEnabled = diagnostics.compressorEnabled
''',
'''        loudnessContourScale = diagnostics.loudnessContourScale
        dialogueProgramLevelDBFS = diagnostics.dialogueProgramLevelDBFS
        dialogueBandLevelDBFS = diagnostics.dialogueBandLevelDBFS
        dialogueGapDB = diagnostics.dialogueGapDB
        dialogueVoiceConfidence = diagnostics.dialogueVoiceConfidence
        dialogueBoostDB = diagnostics.dialogueBoostDB
        compressorEnabled = diagnostics.compressorEnabled
''')

# ---- validation UI ------------------------------------------------------
u='NotchSixty/ContentView.swift'
# Compressor bindings.
replace_once(u,
'''        let compressorRelease = dynamicsBinding(\\.compressor.releaseMs)
        let expanderEnabled = dynamicsBinding(\\.expander.enabled)
''',
'''        let compressorRelease = dynamicsBinding(\\.compressor.releaseMs)
        let compressorTopology = dynamicsBinding(\\.compressor.topology)
        let compressorProgramRelease = dynamicsBinding(\\.compressor.programDependentRelease)
        let compressorSidechainHPF = dynamicsBinding(\\.compressor.sidechainHighPassHz)
        let expanderEnabled = dynamicsBinding(\\.expander.enabled)
''')
replace_once(u,
'''            HStack(spacing: 12) {
                Toggle("Expander", isOn: expanderEnabled).toggleStyle(.switch)
''',
'''            HStack(spacing: 12) {
                Text("Comp detector").frame(width: 90, alignment: .leading)
                Picker("Topology", selection: compressorTopology) {
                    ForEach(CompressorTopology.allCases) { topology in Text(topology.displayName).tag(topology) }
                }.frame(width: 190)
                Toggle("Program-dependent release", isOn: compressorProgramRelease).toggleStyle(.switch)
                Text("Sidechain HPF")
                Slider(value: compressorSidechainHPF, in: CompressorConfiguration.sidechainHighPassRange, step: 5).frame(width: 140)
                Text("\(engine.dynamicsConfiguration.compressor.sidechainHighPassHz, specifier: "%.0f") Hz").monospacedDigit().frame(width: 62)
            }

            HStack(spacing: 12) {
                Toggle("Expander", isOn: expanderEnabled).toggleStyle(.switch)
''')
replace_once(u,
'''            Text("Compressor and Expander are linked-stereo. Pause Gate uses Attack for fade-out and Release for fade-in. This is validation UI; the full legacy Dynamics surface remains tracked in docs/DYNAMICS_PARITY_INVENTORY.md.")
''',
'''            Text("Compressor and Expander are linked-stereo. PR32 adds feed-forward/feed-back detector topology, program-dependent release, and detector-only sidechain HPF. Pause Gate uses Attack for fade-out and Release for fade-in.")
''')

# Advanced bindings: replace deesser/multiband binding block.
replace_once(u,
'''        let deEsserEnabled = dynamicsBinding(\\.deEsser.enabled)
        let deEsserFrequency = dynamicsBinding(\\.deEsser.frequencyHz)
        let deEsserThreshold = dynamicsBinding(\\.deEsser.thresholdDB)
        let deEsserDynamicEQ = dynamicsBinding(\\.deEsser.dynamicEQMode)

        let multibandEnabled = dynamicsBinding(\\.multibandCompressor.enabled)
        let multibandLowMid = dynamicsBinding(\\.multibandCompressor.lowMidFrequencyHz)
        let multibandMidHigh = dynamicsBinding(\\.multibandCompressor.midHighFrequencyHz)
        let multibandSlope = dynamicsBinding(\\.multibandCompressor.slope)
        let multibandLowThreshold = dynamicsBinding(\\.multibandCompressor.lowThresholdDB)
        let multibandMidThreshold = dynamicsBinding(\\.multibandCompressor.midThresholdDB)
        let multibandHighThreshold = dynamicsBinding(\\.multibandCompressor.highThresholdDB)
''',
'''        let dialogueEnabled = dynamicsBinding(\\.dialogueRelativeLeveler.enabled)
        let dialogueVoiceGate = dynamicsBinding(\\.dialogueRelativeLeveler.voiceGate.enabled)
        let dialogueLow = dynamicsBinding(\\.dialogueRelativeLeveler.bandLowHz)
        let dialogueHigh = dynamicsBinding(\\.dialogueRelativeLeveler.bandHighHz)
        let dialogueGap = dynamicsBinding(\\.dialogueRelativeLeveler.targetGapDB)
        let dialogueRatio = dynamicsBinding(\\.dialogueRelativeLeveler.boostRatio)
        let dialogueMaxBoost = dynamicsBinding(\\.dialogueRelativeLeveler.maxBoostDB)
        let dialogueDetector = dynamicsBinding(\\.dialogueRelativeLeveler.detectorWindowMs)
        let dialogueAttack = dynamicsBinding(\\.dialogueRelativeLeveler.attackMs)
        let dialogueRelease = dynamicsBinding(\\.dialogueRelativeLeveler.releaseMs)
        let dialogueProgramGate = dynamicsBinding(\\.dialogueRelativeLeveler.programGateThresholdDB)
        let voiceCenter = dynamicsBinding(\\.dialogueRelativeLeveler.voiceGate.modulationCenterHz)
        let voiceBandwidth = dynamicsBinding(\\.dialogueRelativeLeveler.voiceGate.modulationBandwidthHz)
        let voiceEnvelopeWindow = dynamicsBinding(\\.dialogueRelativeLeveler.voiceGate.envelopeWindowMs)
        let voiceMeasurementWindow = dynamicsBinding(\\.dialogueRelativeLeveler.voiceGate.measurementWindowMs)
        let voiceConfidenceFloor = dynamicsBinding(\\.dialogueRelativeLeveler.voiceGate.confidenceFloorIndex)
        let voiceConfidenceCeiling = dynamicsBinding(\\.dialogueRelativeLeveler.voiceGate.confidenceCeilingIndex)
        let voiceMinimumConfidence = dynamicsBinding(\\.dialogueRelativeLeveler.voiceGate.minConfidence)

        let deEsserEnabled = dynamicsBinding(\\.deEsser.enabled)
        let deEsserFrequency = dynamicsBinding(\\.deEsser.frequencyHz)
        let deEsserThreshold = dynamicsBinding(\\.deEsser.thresholdDB)
        let deEsserRatio = dynamicsBinding(\\.deEsser.ratio)
        let deEsserRange = dynamicsBinding(\\.deEsser.rangeDB)
        let deEsserQ = dynamicsBinding(\\.deEsser.detectionQ)
        let deEsserAttack = dynamicsBinding(\\.deEsser.attackMs)
        let deEsserRelease = dynamicsBinding(\\.deEsser.releaseMs)
        let deEsserDynamicEQ = dynamicsBinding(\\.deEsser.dynamicEQMode)

        let multibandEnabled = dynamicsBinding(\\.multibandCompressor.enabled)
        let multibandLowMid = dynamicsBinding(\\.multibandCompressor.lowMidFrequencyHz)
        let multibandMidHigh = dynamicsBinding(\\.multibandCompressor.midHighFrequencyHz)
        let multibandLowSlope = dynamicsBinding(\\.multibandCompressor.lowMidSlope)
        let multibandHighSlope = dynamicsBinding(\\.multibandCompressor.midHighSlope)
        let multibandLowThreshold = dynamicsBinding(\\.multibandCompressor.lowThresholdDB)
        let multibandMidThreshold = dynamicsBinding(\\.multibandCompressor.midThresholdDB)
        let multibandHighThreshold = dynamicsBinding(\\.multibandCompressor.highThresholdDB)
        let multibandLowRatio = dynamicsBinding(\\.multibandCompressor.lowRatio)
        let multibandMidRatio = dynamicsBinding(\\.multibandCompressor.midRatio)
        let multibandHighRatio = dynamicsBinding(\\.multibandCompressor.highRatio)
        let multibandLowAttack = dynamicsBinding(\\.multibandCompressor.lowAttackMs)
        let multibandMidAttack = dynamicsBinding(\\.multibandCompressor.midAttackMs)
        let multibandHighAttack = dynamicsBinding(\\.multibandCompressor.highAttackMs)
        let multibandLowRelease = dynamicsBinding(\\.multibandCompressor.lowReleaseMs)
        let multibandMidRelease = dynamicsBinding(\\.multibandCompressor.midReleaseMs)
        let multibandHighRelease = dynamicsBinding(\\.multibandCompressor.highReleaseMs)
        let multibandLowKnee = dynamicsBinding(\\.multibandCompressor.lowKneeDB)
        let multibandMidKnee = dynamicsBinding(\\.multibandCompressor.midKneeDB)
        let multibandHighKnee = dynamicsBinding(\\.multibandCompressor.highKneeDB)
        let multibandLowSC = dynamicsBinding(\\.multibandCompressor.lowSidechainHighPassHz)
        let multibandMidSC = dynamicsBinding(\\.multibandCompressor.midSidechainHighPassHz)
        let multibandHighSC = dynamicsBinding(\\.multibandCompressor.highSidechainHighPassHz)
        let multibandLowMakeup = dynamicsBinding(\\.multibandCompressor.lowMakeupGainDB)
        let multibandMidMakeup = dynamicsBinding(\\.multibandCompressor.midMakeupGainDB)
        let multibandHighMakeup = dynamicsBinding(\\.multibandCompressor.highMakeupGainDB)
''')

# Header label.
replace_once(u, 'Text("PR28 + PR29")', 'Text("PR28 + PR29 + PR32")')

# Insert dialogue block before de-esser divider/row.
replace_once(u,
'''            Divider()

            HStack(spacing: 12) {
                Toggle("De-Esser", isOn: deEsserEnabled).toggleStyle(.switch)
''',
'''            Divider()

            HStack(spacing: 12) {
                Toggle("Dialogue-Relative Leveler", isOn: dialogueEnabled).toggleStyle(.switch)
                Toggle("Voice confidence gate", isOn: dialogueVoiceGate).toggleStyle(.switch)
                Text("Band")
                TextField("Low", value: dialogueLow, format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                Text("–")
                TextField("High", value: dialogueHigh, format: .number).frame(width: 66).textFieldStyle(.roundedBorder)
                Text("Hz")
                Text("Target gap")
                Slider(value: dialogueGap, in: DialogueRelativeLevelerConfiguration.targetGapRange, step: 0.5).frame(width: 110)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.targetGapDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 62)
            }
            HStack(spacing: 10) {
                Text("Dialogue gain").frame(width: 90, alignment: .leading)
                Text("Ratio")
                Slider(value: dialogueRatio, in: DialogueRelativeLevelerConfiguration.boostRatioRange, step: 0.1).frame(width: 110)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.boostRatio, specifier: "%.1f"):1").monospacedDigit().frame(width: 48)
                Text("Max boost")
                Slider(value: dialogueMaxBoost, in: DialogueRelativeLevelerConfiguration.maxBoostRange, step: 0.5).frame(width: 110)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.maxBoostDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 60)
                Text("Program gate")
                Slider(value: dialogueProgramGate, in: DialogueRelativeLevelerConfiguration.programGateRange, step: 1).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.programGateThresholdDB, specifier: "%.0f") dBFS").monospacedDigit().frame(width: 68)
            }
            HStack(spacing: 10) {
                Text("Dialogue time").frame(width: 90, alignment: .leading)
                Text("Detector")
                Slider(value: dialogueDetector, in: DialogueRelativeLevelerConfiguration.detectorWindowRange, step: 10).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.detectorWindowMs, specifier: "%.0f") ms").monospacedDigit().frame(width: 58)
                Text("Attack")
                Slider(value: dialogueAttack, in: DialogueRelativeLevelerConfiguration.attackRange, step: 10).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.attackMs, specifier: "%.0f")").monospacedDigit().frame(width: 44)
                Text("Release")
                Slider(value: dialogueRelease, in: DialogueRelativeLevelerConfiguration.releaseRange, step: 25).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.releaseMs, specifier: "%.0f") ms").monospacedDigit().frame(width: 58)
            }
            if engine.dynamicsConfiguration.dialogueRelativeLeveler.voiceGate.enabled {
                HStack(spacing: 8) {
                    Text("Voice gate").frame(width: 90, alignment: .leading)
                    Text("Center"); TextField("Hz", value: voiceCenter, format: .number).frame(width: 52).textFieldStyle(.roundedBorder)
                    Text("BW"); TextField("Hz", value: voiceBandwidth, format: .number).frame(width: 52).textFieldStyle(.roundedBorder)
                    Text("Env ms"); TextField("ms", value: voiceEnvelopeWindow, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                    Text("Measure ms"); TextField("ms", value: voiceMeasurementWindow, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                    Text("Floor"); TextField("", value: voiceConfidenceFloor, format: .number.precision(.fractionLength(2))).frame(width: 54).textFieldStyle(.roundedBorder)
                    Text("Ceil"); TextField("", value: voiceConfidenceCeiling, format: .number.precision(.fractionLength(2))).frame(width: 54).textFieldStyle(.roundedBorder)
                    Text("Min"); TextField("", value: voiceMinimumConfidence, format: .number.precision(.fractionLength(2))).frame(width: 54).textFieldStyle(.roundedBorder)
                }
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let d = engine.diagnosticsSnapshot().renderKernelDiagnostics
                HStack(spacing: 14) {
                    Text("Program: \(d?.dialogueProgramLevelDBFS ?? -120, specifier: "%.1f") dBFS")
                    Text("Dialogue band: \(d?.dialogueBandLevelDBFS ?? -120, specifier: "%.1f")")
                    Text("Gap: \(d?.dialogueGapDB ?? 0, specifier: "%.1f") dB")
                    Text("Voice: \((d?.dialogueVoiceConfidence ?? 1) * 100, specifier: "%.0f")%")
                    Text("Boost: \(d?.dialogueBoostDB ?? 0, specifier: "%+.2f") dB")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 12) {
                Toggle("De-Esser", isOn: deEsserEnabled).toggleStyle(.switch)
''')

# De-esser advanced row after main row.
replace_once(u,
'''            HStack(spacing: 12) {
                Toggle("3-band Multiband", isOn: multibandEnabled).toggleStyle(.switch)
''',
'''            HStack(spacing: 10) {
                Text("De-Esser depth").frame(width: 90, alignment: .leading)
                Text("Ratio")
                Slider(value: deEsserRatio, in: DeEsserConfiguration.ratioRange, step: 0.5).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.deEsser.ratio, specifier: "%.1f")").monospacedDigit().frame(width: 42)
                Text("Max cut")
                Slider(value: deEsserRange, in: DeEsserConfiguration.rangeRange, step: 0.5).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.deEsser.rangeDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 60)
                Text("Q")
                Slider(value: deEsserQ, in: DeEsserConfiguration.detectionQRange, step: 0.1).frame(width: 90)
                Text("\(engine.dynamicsConfiguration.deEsser.detectionQ, specifier: "%.1f")").monospacedDigit().frame(width: 38)
                Text("A/R")
                TextField("A", value: deEsserAttack, format: .number).frame(width: 52).textFieldStyle(.roundedBorder)
                TextField("R", value: deEsserRelease, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                Text("ms").foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Toggle("3-band Multiband", isOn: multibandEnabled).toggleStyle(.switch)
''')
# Replace single slope picker with independent.
replace_once(u,
'''                Picker("Slope", selection: multibandSlope) {
                    ForEach(MultibandSlope.allCases) { slope in
                        Text(slope.displayName).tag(slope)
                    }
                }
                .frame(width: 170)
''',
'''                Picker("Low slope", selection: multibandLowSlope) {
                    ForEach(MultibandSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                }.frame(width: 160)
                Picker("High slope", selection: multibandHighSlope) {
                    ForEach(MultibandSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                }.frame(width: 160)
''')
# Add compact per-band control rows before telemetry.
replace_once(u,
'''            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                HStack(spacing: 16) {
                    Text("De-Esser GR: \\(diagnostics?.deEsserGainReductionDB ?? 0, specifier: \"%.2f\") dB")
''',
'''            HStack(spacing: 8) {
                Text("MB ratios").frame(width: 90, alignment: .leading)
                Text("L"); Slider(value: multibandLowRatio, in: MultibandCompressorConfiguration.ratioRange, step: 0.5).frame(width: 90); Text("\(engine.dynamicsConfiguration.multibandCompressor.lowRatio, specifier: "%.1f")")
                Text("M"); Slider(value: multibandMidRatio, in: MultibandCompressorConfiguration.ratioRange, step: 0.5).frame(width: 90); Text("\(engine.dynamicsConfiguration.multibandCompressor.midRatio, specifier: "%.1f")")
                Text("H"); Slider(value: multibandHighRatio, in: MultibandCompressorConfiguration.ratioRange, step: 0.5).frame(width: 90); Text("\(engine.dynamicsConfiguration.multibandCompressor.highRatio, specifier: "%.1f")")
            }
            HStack(spacing: 8) {
                Text("MB attack").frame(width: 90, alignment: .leading)
                TextField("L", value: multibandLowAttack, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                TextField("M", value: multibandMidAttack, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                TextField("H", value: multibandHighAttack, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                Text("ms   release")
                TextField("L", value: multibandLowRelease, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                TextField("M", value: multibandMidRelease, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                TextField("H", value: multibandHighRelease, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                Text("ms")
            }
            HStack(spacing: 8) {
                Text("MB knee").frame(width: 90, alignment: .leading)
                TextField("L", value: multibandLowKnee, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                TextField("M", value: multibandMidKnee, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                TextField("H", value: multibandHighKnee, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                Text("dB   sidechain HPF")
                TextField("L", value: multibandLowSC, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                TextField("M", value: multibandMidSC, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                TextField("H", value: multibandHighSC, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                Text("Hz")
            }
            HStack(spacing: 8) {
                Text("MB makeup").frame(width: 90, alignment: .leading)
                TextField("L", value: multibandLowMakeup, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                TextField("M", value: multibandMidMakeup, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                TextField("H", value: multibandHighMakeup, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                Text("dB (linked stereo per band)").font(.caption).foregroundStyle(.secondary)
            }

            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                HStack(spacing: 16) {
                    Text("De-Esser GR: \\(diagnostics?.deEsserGainReductionDB ?? 0, specifier: \"%.2f\") dB")
''')
# Caption.
replace_once(u,
'''            Text("This engineering surface intentionally exposes the PR28 + PR29 controls needed for hardware validation. Stereo widening defaults remain conservative; extreme settings are available only for deliberate testing.")
''',
'''            Text("PR32 validation adds the legacy control depth for Compressor, De-Esser and Multiband plus the independently authored Dialogue-Relative Leveler. Defaults preserve the already accepted commercial behavior unless a PR32 control is deliberately changed.")
''')

print('PR32 validation patch applied')