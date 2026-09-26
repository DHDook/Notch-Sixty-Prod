from pathlib import Path

ROOT = Path('.')

def read(path):
    return (ROOT / path).read_text()

def write(path, text):
    (ROOT / path).write_text(text)

def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f'anchor not found: {label}')
    return text.replace(old, new, 1)

# ---------- ContentView.swift ----------
p = 'NotchSixty/ContentView.swift'
s = read(p)

s = replace_once(
    s,
    '''            dynamicsValidationView\n            advancedDynamicsValidationView\n            crossoverValidationView\n''',
    '''            dynamicsValidationView\n            advancedDynamicsValidationView\n            pr33ValidationView\n            crossoverValidationView\n''',
    'body PR33 validation insertion'
)

s = replace_once(
    s,
    '''    @ViewBuilder\n    private var dynamicsValidationView: some View {\n''',
    '''    private func dynamicEQBandBinding<Value>(\n        index: Int,\n        _ keyPath: WritableKeyPath<DynamicEQBandConfiguration, Value>\n    ) -> Binding<Value> {\n        Binding(\n            get: { engine.dynamicsConfiguration.dynamicEQ.bands[index][keyPath: keyPath] },\n            set: { value in\n                var updated = engine.dynamicsConfiguration\n                guard updated.dynamicEQ.bands.indices.contains(index) else { return }\n                updated.dynamicEQ.bands[index][keyPath: keyPath] = value\n                try? engine.replaceDynamicsConfiguration(updated)\n            }\n        )\n    }\n\n    private func addDynamicEQBand() {\n        var updated = engine.dynamicsConfiguration\n        guard updated.dynamicEQ.bands.count < DynamicEQConfiguration.maximumBandCount else { return }\n        updated.dynamicEQ.bands.append(DynamicEQBandConfiguration())\n        try? engine.replaceDynamicsConfiguration(updated)\n    }\n\n    private func removeDynamicEQBand(at index: Int) {\n        var updated = engine.dynamicsConfiguration\n        guard updated.dynamicEQ.bands.indices.contains(index) else { return }\n        updated.dynamicEQ.bands.remove(at: index)\n        try? engine.replaceDynamicsConfiguration(updated)\n    }\n\n    @ViewBuilder\n    private var dynamicsValidationView: some View {\n''',
    'dynamic EQ binding helpers'
)

pr33_view = r'''
    @ViewBuilder
    private var pr33ValidationView: some View {
        let dynamicEQEnabled = dynamicsBinding(\.dynamicEQ.enabled)
        let oversampling = dynamicsBinding(\.oversampling)
        let softClipperEnabled = dynamicsBinding(\.softClipper.enabled)
        let clipperAsymmetry = dynamicsBinding(\.softClipper.asymmetryTrimDB)
        let limiterEnabled = dynamicsBinding(\.limiter.enabled)
        let truePeakGuard = dynamicsBinding(\.limiter.truePeakGuardEnabled)
        let gainRiderEnabled = dynamicsBinding(\.gainRider.enabled)
        let gainRiderTarget = dynamicsBinding(\.gainRider.targetGainReductionDB)
        let gainRiderMax = dynamicsBinding(\.gainRider.maxReductionDB)
        let gainRiderSpeed = dynamicsBinding(\.gainRider.speed)
        let autoHeadroomEnabled = dynamicsBinding(\.automaticHeadroom.enabled)
        let autoHeadroomMax = dynamicsBinding(\.automaticHeadroom.maxAttenuationDB)
        let loudnessEnabled = dynamicsBinding(\.loudnessContour.enabled)
        let loudnessStrength = dynamicsBinding(\.loudnessContour.strength)
        let loudnessReference = dynamicsBinding(\.loudnessContour.referencePhons)
        let loudnessMaxBoost = dynamicsBinding(\.loudnessContour.maxBoostDB)
        let loudnessMaxCut = dynamicsBinding(\.loudnessContour.maxCutDB)
        let loudnessLevelSource = dynamicsBinding(\.loudnessContour.levelSource)
        let deHarshEnabled = dynamicsBinding(\.deHarsh.enabled)
        let deHarshAmount = dynamicsBinding(\.deHarsh.amountDB)
        let deHarshFrequency = dynamicsBinding(\.deHarsh.frequencyHz)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PR33 residual dynamics validation").font(.headline)
                Spacer()
                Text("Dynamic EQ + gain/protection + perceptual conditioning")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("General Dynamic EQ") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Toggle("Dynamic EQ", isOn: dynamicEQEnabled).toggleStyle(.switch)
                        Button("Add Band", action: addDynamicEQBand)
                            .disabled(engine.dynamicsConfiguration.dynamicEQ.bands.count >= DynamicEQConfiguration.maximumBandCount)
                        Text("\(engine.dynamicsConfiguration.dynamicEQ.bands.count) / \(DynamicEQConfiguration.maximumBandCount) bands")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if engine.dynamicsConfiguration.dynamicEQ.bands.isEmpty {
                        Text("Add a band to exercise the PR33 Dynamic EQ processor.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(engine.dynamicsConfiguration.dynamicEQ.bands.indices, id: \.self) { index in
                        let bandEnabled = dynamicEQBandBinding(index: index, \.enabled)
                        let frequency = dynamicEQBandBinding(index: index, \.frequencyHz)
                        let q = dynamicEQBandBinding(index: index, \.q)
                        let staticGain = dynamicEQBandBinding(index: index, \.staticGainDB)
                        let direction = dynamicEQBandBinding(index: index, \.direction)
                        let threshold = dynamicEQBandBinding(index: index, \.thresholdDB)
                        let ratio = dynamicEQBandBinding(index: index, \.ratio)
                        let range = dynamicEQBandBinding(index: index, \.rangeDB)
                        let attack = dynamicEQBandBinding(index: index, \.attackMs)
                        let release = dynamicEQBandBinding(index: index, \.releaseMs)
                        let boostThreshold = dynamicEQBandBinding(index: index, \.boostThresholdDB)
                        let boostRatio = dynamicEQBandBinding(index: index, \.boostRatio)
                        let maxBoost = dynamicEQBandBinding(index: index, \.maxBoostDB)
                        let detector = dynamicEQBandBinding(index: index, \.detectorMode)
                        let rmsWindow = dynamicEQBandBinding(index: index, \.rmsWindowMs)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Toggle("Band \(index + 1)", isOn: bandEnabled).toggleStyle(.switch)
                                Text("Freq")
                                Slider(value: frequency, in: DynamicEQBandConfiguration.frequencyRange, step: 10).frame(width: 150)
                                Text("\(engine.dynamicsConfiguration.dynamicEQ.bands[index].frequencyHz, specifier: "%.0f") Hz")
                                    .monospacedDigit().frame(width: 72)
                                Text("Q")
                                Slider(value: q, in: DynamicEQBandConfiguration.qRange, step: 0.1).frame(width: 105)
                                Text("\(engine.dynamicsConfiguration.dynamicEQ.bands[index].q, specifier: "%.1f")")
                                    .monospacedDigit().frame(width: 38)
                                Button("Remove") { removeDynamicEQBand(at: index) }
                            }
                            HStack(spacing: 10) {
                                Picker("Direction", selection: direction) {
                                    ForEach(DynamicEQDirection.allCases) { value in Text(value.displayName).tag(value) }
                                }.frame(width: 190)
                                Text("Static")
                                Slider(value: staticGain, in: DynamicEQBandConfiguration.staticGainRange, step: 0.5).frame(width: 110)
                                Text("\(engine.dynamicsConfiguration.dynamicEQ.bands[index].staticGainDB, specifier: "%+.1f") dB").monospacedDigit().frame(width: 70)
                                Text("Threshold")
                                Slider(value: threshold, in: DynamicEQBandConfiguration.thresholdRange, step: 0.5).frame(width: 110)
                                Text("\(engine.dynamicsConfiguration.dynamicEQ.bands[index].thresholdDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 70)
                                Text("Ratio")
                                Slider(value: ratio, in: DynamicEQBandConfiguration.ratioRange, step: 0.1).frame(width: 90)
                            }
                            HStack(spacing: 10) {
                                Text("Max cut")
                                Slider(value: range, in: DynamicEQBandConfiguration.rangeRange, step: 0.5).frame(width: 110)
                                Text("\(engine.dynamicsConfiguration.dynamicEQ.bands[index].rangeDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 66)
                                Text("Attack")
                                Slider(value: attack, in: DynamicEQBandConfiguration.attackRange, step: 1).frame(width: 100)
                                Text("Release")
                                Slider(value: release, in: DynamicEQBandConfiguration.releaseRange, step: 5).frame(width: 100)
                                Picker("Detector", selection: detector) {
                                    ForEach(DynamicEQDetectorMode.allCases) { value in Text(value.displayName).tag(value) }
                                }.frame(width: 150)
                                if engine.dynamicsConfiguration.dynamicEQ.bands[index].detectorMode == .rms {
                                    Text("RMS")
                                    Slider(value: rmsWindow, in: DynamicEQBandConfiguration.rmsWindowRange, step: 5).frame(width: 90)
                                }
                            }
                            HStack(spacing: 10) {
                                Text("Boost threshold")
                                Slider(value: boostThreshold, in: DynamicEQBandConfiguration.boostThresholdRange, step: 0.5).frame(width: 120)
                                Text("\(engine.dynamicsConfiguration.dynamicEQ.bands[index].boostThresholdDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 70)
                                Text("Boost ratio")
                                Slider(value: boostRatio, in: DynamicEQBandConfiguration.boostRatioRange, step: 0.1).frame(width: 95)
                                Text("Max boost")
                                Slider(value: maxBoost, in: DynamicEQBandConfiguration.maxBoostRange, step: 0.5).frame(width: 105)
                                Text("\(engine.dynamicsConfiguration.dynamicEQ.bands[index].maxBoostDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 66)
                            }
                        }
                        .padding(.vertical, 4)
                        if index != engine.dynamicsConfiguration.dynamicEQ.bands.indices.last { Divider() }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Gain / protection integration") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Picker("Oversampling", selection: oversampling) {
                            ForEach(OversamplingFactor.allCases) { factor in Text(factor.displayName).tag(factor) }
                        }.frame(width: 170)
                        Toggle("Soft Clipper", isOn: softClipperEnabled).toggleStyle(.switch)
                        Text("Asymmetry")
                        Slider(value: clipperAsymmetry, in: SoftClipperConfiguration.asymmetryTrimRange, step: 0.1).frame(width: 140)
                        Text("\(engine.dynamicsConfiguration.softClipper.asymmetryTrimDB, specifier: "%+.1f") dB")
                            .monospacedDigit().frame(width: 72)
                    }
                    HStack(spacing: 12) {
                        Toggle("Limiter", isOn: limiterEnabled).toggleStyle(.switch)
                        Toggle("True-Peak Guard", isOn: truePeakGuard).toggleStyle(.switch)
                        Text("Guard ON forces the accepted PR27 4× reconstruction path; OFF follows selected oversampling.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Toggle("Dynamic Gain Rider", isOn: gainRiderEnabled).toggleStyle(.switch)
                        Text("Target GR")
                        Slider(value: gainRiderTarget, in: GainRiderConfiguration.targetRange, step: 0.25).frame(width: 120)
                        Text("\(engine.dynamicsConfiguration.gainRider.targetGainReductionDB, specifier: "%.2f") dB").monospacedDigit().frame(width: 72)
                        Text("Max cut")
                        Slider(value: gainRiderMax, in: GainRiderConfiguration.maxReductionRange, step: 0.5).frame(width: 110)
                        Picker("Speed", selection: gainRiderSpeed) {
                            ForEach(GainRiderSpeed.allCases) { speed in Text(speed.displayName).tag(speed) }
                        }.frame(width: 145)
                    }
                    HStack(spacing: 12) {
                        Toggle("Automatic Headroom", isOn: autoHeadroomEnabled).toggleStyle(.switch)
                        Text("Max attenuation")
                        Slider(value: autoHeadroomMax, in: AutomaticHeadroomConfiguration.maxAttenuationRange, step: 0.5).frame(width: 180)
                        Text("\(engine.dynamicsConfiguration.automaticHeadroom.maxAttenuationDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 72)
                        Text("Predictive pre-EQ headroom; raw Global Bypass remains untouched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Per-Band Loudness / De-Harsh") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Toggle("Per-Band Loudness", isOn: loudnessEnabled).toggleStyle(.switch)
                        Picker("Level source", selection: loudnessLevelSource) {
                            ForEach(LoudnessLevelSource.allCases) { source in Text(source.displayName).tag(source) }
                        }.frame(width: 200)
                        Text("Strength")
                        Slider(value: loudnessStrength, in: LoudnessContourConfiguration.strengthRange, step: 0.05).frame(width: 120)
                        Text("\(engine.dynamicsConfiguration.loudnessContour.strength, specifier: "%.2f")").monospacedDigit().frame(width: 44)
                    }
                    HStack(spacing: 12) {
                        Text("Reference")
                        Slider(value: loudnessReference, in: LoudnessContourConfiguration.referencePhonsRange, step: 1).frame(width: 140)
                        Text("\(engine.dynamicsConfiguration.loudnessContour.referencePhons, specifier: "%.0f") phons").monospacedDigit().frame(width: 76)
                        Text("Max boost")
                        Slider(value: loudnessMaxBoost, in: LoudnessContourConfiguration.maxBoostRange, step: 1).frame(width: 120)
                        Text("\(engine.dynamicsConfiguration.loudnessContour.maxBoostDB, specifier: "%.0f") dB").monospacedDigit().frame(width: 58)
                        Text("Max cut")
                        Slider(value: loudnessMaxCut, in: LoudnessContourConfiguration.maxCutRange, step: 0.5).frame(width: 110)
                        Text("\(engine.dynamicsConfiguration.loudnessContour.maxCutDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 62)
                    }
                    HStack(spacing: 12) {
                        Toggle("De-Harsh", isOn: deHarshEnabled).toggleStyle(.switch)
                        Text("Amount")
                        Slider(value: deHarshAmount, in: DeHarshConfiguration.amountRange, step: 0.1).frame(width: 160)
                        Text("\(engine.dynamicsConfiguration.deHarsh.amountDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 66)
                        Text("Frequency")
                        Slider(value: deHarshFrequency, in: DeHarshConfiguration.frequencyRange, step: 100).frame(width: 180)
                        Text("\(engine.dynamicsConfiguration.deHarsh.frequencyHz, specifier: "%.0f") Hz").monospacedDigit().frame(width: 76)
                    }
                    Text("Per-Band Loudness supersedes the shallow PR29 contour in the Swift path. The System Volume mapping is a relative reference model, not a calibrated SPL measurement.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

'''

s = replace_once(
    s,
    '''    @ViewBuilder\n    private var crossoverValidationView: some View {\n''',
    pr33_view + '''    @ViewBuilder\n    private var crossoverValidationView: some View {\n''',
    'PR33 validation view placement'
)

write(p, s)

# ---------- Slice 1 provenance closure ----------
p = 'docs/PROVENANCE.md'
s = read(p)
entry = r'''

## PR33 Slice 1 — General Dynamic EQ

Classification: **specification-derived / independently authored commercial implementation**.

Observable legacy configuration/UI state was used only to establish the user-facing Dynamic EQ contract: up to 16 bands, center frequency/Q/static gain, threshold/ratio/range, attack/release, Cut Only / Boost Only / Both direction, boost threshold/ratio/max boost, Peak/RMS detector selection, and RMS window. Historical Dynamic EQ DSP implementation files and historical DSP tests were not used as implementation templates.

The commercial processor is an independently authored fixed/preallocated C design using public peaking-biquad mathematics, linked-stereo detector decisions, precomputed analysis coefficients, bounded gain laws, one-pole timing, and immutable control-plane snapshots. It has zero intentional look-ahead latency and performs no allocation, locking, logging, I/O, or coefficient design in the render callback.
'''
if '## PR33 Slice 1 — General Dynamic EQ' not in s:
    s += entry
write(p, s)

print('PR33 validation UI and Slice 1 provenance patch applied')
