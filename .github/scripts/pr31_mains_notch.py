from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"anchor not found: {label}")
    return text.replace(old, new, 1)

# ---- Portable C snapshot/runtime -------------------------------------------------
h = Path('NotchSixty/Audio/Realtime/N60Dynamics.h')
text = h.read_text()
text = replace_once(text,
    '#define N60_MAX_INFRASONIC_SECTIONS 8\n',
    '#define N60_MAX_INFRASONIC_SECTIONS 8\n#define N60_MAX_MAINS_HARMONICS 16\n',
    'mains max define')

infrasonic_struct = '''typedef struct {
    bool enabled;
    double cutoffHz;
    N60InfrasonicSlope slope;
    uint32_t sectionCount;
    N60BiquadCoefficients highPass[N60_MAX_INFRASONIC_SECTIONS];
} N60InfrasonicFilterSnapshot;
'''
mains_struct = infrasonic_struct + '''
typedef struct {
    bool enabled;
    double fundamentalHz;
    uint32_t harmonicCount;
    float q;
    float depthsDB[N60_MAX_MAINS_HARMONICS];
    N60BiquadCoefficients filters[N60_MAX_MAINS_HARMONICS];
} N60MainsNotchSnapshot;
'''
text = replace_once(text, infrasonic_struct, mains_struct, 'mains snapshot struct')
text = replace_once(text,
    '    N60InfrasonicFilterSnapshot infrasonicFilter;\n    N60LoudnessMatchSnapshot loudnessMatch;\n',
    '    N60InfrasonicFilterSnapshot infrasonicFilter;\n    N60MainsNotchSnapshot mainsNotch;\n    N60LoudnessMatchSnapshot loudnessMatch;\n',
    'mains snapshot member')
text = replace_once(text,
    '    N60BiquadState infrasonicRight[N60_MAX_INFRASONIC_SECTIONS];\n    float infrasonicMix;\n',
    '    N60BiquadState infrasonicRight[N60_MAX_INFRASONIC_SECTIONS];\n    float infrasonicMix;\n    N60BiquadState mainsNotchLeft[N60_MAX_MAINS_HARMONICS];\n    N60BiquadState mainsNotchRight[N60_MAX_MAINS_HARMONICS];\n    float mainsNotchMix;\n',
    'mains runtime state')

infrasonic_decl = '''bool N60DynamicsSnapshotSetInfrasonicFilter(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double cutoffHz,
    N60InfrasonicSlope slope
);
'''
mains_decl = infrasonic_decl + '''
bool N60DynamicsSnapshotSetMainsNotch(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double fundamentalHz,
    uint32_t harmonicCount,
    float q,
    const float * _Nonnull depthsDB,
    uint32_t depthCount
);
'''
text = replace_once(text, infrasonic_decl, mains_decl, 'mains setter declaration')
h.write_text(text)

c = Path('NotchSixty/Audio/Realtime/N60Dynamics.c')
text = c.read_text()

infrasonic_default = '''    snapshot.infrasonicFilter.enabled = false;
    snapshot.infrasonicFilter.cutoffHz = 18.0;
    snapshot.infrasonicFilter.slope = N60InfrasonicSlope48DBPerOctave;
    snapshot.infrasonicFilter.sectionCount = 0;
    for (uint32_t index = 0; index < N60_MAX_INFRASONIC_SECTIONS; ++index) {
        snapshot.infrasonicFilter.highPass[index] = N60BiquadCoefficientsMakeIdentity();
    }
'''
mains_default = infrasonic_default + '''
    snapshot.mainsNotch.enabled = false;
    snapshot.mainsNotch.fundamentalHz = 60.0;
    snapshot.mainsNotch.harmonicCount = 8;
    snapshot.mainsNotch.q = 30.0f;
    for (uint32_t index = 0; index < N60_MAX_MAINS_HARMONICS; ++index) {
        snapshot.mainsNotch.depthsDB[index] = 0.0f;
        snapshot.mainsNotch.filters[index] = N60BiquadCoefficientsMakeIdentity();
    }
'''
text = replace_once(text, infrasonic_default, mains_default, 'mains default snapshot')

setter_anchor = '''    snapshot->infrasonicFilter = configured;
    return true;
}

bool N60DynamicsSnapshotSetLoudnessMatch(
'''
setter_code = '''    snapshot->infrasonicFilter = configured;
    return true;
}

bool N60DynamicsSnapshotSetMainsNotch(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double fundamentalHz,
    uint32_t harmonicCount,
    float q,
    const float *depthsDB,
    uint32_t depthCount
) {
    if (snapshot == NULL || depthsDB == NULL
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(fundamentalHz) || fundamentalHz < 40.0 || fundamentalHz > 70.0
        || harmonicCount < 1 || harmonicCount > N60_MAX_MAINS_HARMONICS
        || depthCount < harmonicCount || depthCount > N60_MAX_MAINS_HARMONICS
        || !isfinite(q) || q < 5.0f || q > 60.0f) return false;

    N60MainsNotchSnapshot configured = {0};
    configured.enabled = enabled;
    configured.fundamentalHz = fundamentalHz;
    configured.harmonicCount = harmonicCount;
    configured.q = q;
    for (uint32_t index = 0; index < N60_MAX_MAINS_HARMONICS; ++index) {
        configured.depthsDB[index] = 0.0f;
        configured.filters[index] = N60BiquadCoefficientsMakeIdentity();
    }

    for (uint32_t index = 0; index < harmonicCount; ++index) {
        float depthDB = depthsDB[index];
        if (!isfinite(depthDB) || depthDB < -40.0f || depthDB > 0.0f) return false;
        configured.depthsDB[index] = depthDB;
        double harmonicHz = fundamentalHz * (double)(index + 1u);
        if (harmonicHz >= sampleRate * 0.45 || fabsf(depthDB) < 1.0e-6f) continue;
        if (!N60BiquadDesign(
                N60BiquadFilterTypePeaking,
                sampleRate,
                harmonicHz,
                depthDB,
                q,
                &configured.filters[index])) return false;
    }

    snapshot->mainsNotch = configured;
    return true;
}

bool N60DynamicsSnapshotSetLoudnessMatch(
'''
text = replace_once(text, setter_anchor, setter_code, 'mains setter implementation')

valid_anchor = '''    for (uint32_t index = 0; index < snapshot.infrasonicFilter.sectionCount; ++index) {
        if (!N60BiquadCoefficientsAreFinite(snapshot.infrasonicFilter.highPass[index])) return false;
    }
    if (!isfinite(snapshot.loudnessMatch.targetLUFS)'''
valid_code = '''    for (uint32_t index = 0; index < snapshot.infrasonicFilter.sectionCount; ++index) {
        if (!N60BiquadCoefficientsAreFinite(snapshot.infrasonicFilter.highPass[index])) return false;
    }
    if (!isfinite(snapshot.mainsNotch.fundamentalHz)
        || snapshot.mainsNotch.fundamentalHz < 40.0 || snapshot.mainsNotch.fundamentalHz > 70.0
        || snapshot.mainsNotch.harmonicCount < 1 || snapshot.mainsNotch.harmonicCount > N60_MAX_MAINS_HARMONICS
        || !isfinite(snapshot.mainsNotch.q) || snapshot.mainsNotch.q < 5.0f || snapshot.mainsNotch.q > 60.0f) return false;
    for (uint32_t index = 0; index < snapshot.mainsNotch.harmonicCount; ++index) {
        if (!isfinite(snapshot.mainsNotch.depthsDB[index])
            || snapshot.mainsNotch.depthsDB[index] < -40.0f || snapshot.mainsNotch.depthsDB[index] > 0.0f
            || !N60BiquadCoefficientsAreFinite(snapshot.mainsNotch.filters[index])) return false;
    }
    if (!isfinite(snapshot.loudnessMatch.targetLUFS)'''
text = replace_once(text, valid_anchor, valid_code, 'mains validity')

pre_eq_anchor = '''    runtime->infrasonicMix = smooth_toward(runtime->infrasonicMix, infrasonicTarget, snapshot.bypassTransitionCoefficient);
    *left = dryLeft + (hpLeft - dryLeft) * runtime->infrasonicMix;
    *right = dryRight + (hpRight - dryRight) * runtime->infrasonicMix;
}

static void process_stereo_mode'''
pre_eq_code = '''    runtime->infrasonicMix = smooth_toward(runtime->infrasonicMix, infrasonicTarget, snapshot.bypassTransitionCoefficient);
    *left = dryLeft + (hpLeft - dryLeft) * runtime->infrasonicMix;
    *right = dryRight + (hpRight - dryRight) * runtime->infrasonicMix;

    dryLeft = *left;
    dryRight = *right;
    float notchLeft = process_filter_cascade(
        snapshot.mainsNotch.filters,
        runtime->mainsNotchLeft,
        snapshot.mainsNotch.harmonicCount,
        dryLeft
    );
    float notchRight = process_filter_cascade(
        snapshot.mainsNotch.filters,
        runtime->mainsNotchRight,
        snapshot.mainsNotch.harmonicCount,
        dryRight
    );
    float mainsTarget = snapshot.mainsNotch.enabled ? 1.0f : 0.0f;
    runtime->mainsNotchMix = smooth_toward(runtime->mainsNotchMix, mainsTarget, snapshot.bypassTransitionCoefficient);
    *left = dryLeft + (notchLeft - dryLeft) * runtime->mainsNotchMix;
    *right = dryRight + (notchRight - dryRight) * runtime->mainsNotchMix;
}

static void process_stereo_mode'''
text = replace_once(text, pre_eq_anchor, pre_eq_code, 'mains pre-EQ processing')
c.write_text(text)

# ---- Swift control plane ---------------------------------------------------------
sw = Path('NotchSixty/Audio/DynamicsConfiguration.swift')
text = sw.read_text()
text = replace_once(text,
    '    case invalidInfrasonicFilter\n    case invalidLoudnessMatch\n',
    '    case invalidInfrasonicFilter\n    case invalidMainsNotch\n    case invalidLoudnessMatch\n',
    'mains error case')
text = replace_once(text,
    '        case .invalidInfrasonicFilter:\n            return "Infrasonic Filter parameters are outside the supported production range."\n        case .invalidLoudnessMatch:\n',
    '        case .invalidInfrasonicFilter:\n            return "Infrasonic Filter parameters are outside the supported production range."\n        case .invalidMainsNotch:\n            return "Mains Hum Notch parameters are outside the supported production range."\n        case .invalidLoudnessMatch:\n',
    'mains error description')

insert_after_infrasonic = '''struct InfrasonicFilterConfiguration: Equatable, Sendable {
    static let cutoffRange = 10.0...30.0
    var enabled = false
    var cutoffHz = 18.0
    var slope: InfrasonicSlope = .db48

    func validate() throws {
        guard cutoffHz.isFinite, Self.cutoffRange.contains(cutoffHz) else {
            throw DynamicsConfigurationError.invalidInfrasonicFilter
        }
    }
}
'''
mains_swift = insert_after_infrasonic + '''
enum MainsRegion: Int, CaseIterable, Identifiable, Sendable {
    case hz50 = 50
    case hz60 = 60

    var id: Int { rawValue }
    var displayName: String { "\(rawValue) Hz" }
    var fundamentalHz: Double { Double(rawValue) }
}

struct MainsNotchConfiguration: Equatable, Sendable {
    static let harmonicCountRange = 1...16
    static let qRange = 5.0...60.0
    static let depthRange = -40.0...0.0
    static let maximumHarmonics = 16

    var enabled = false
    var region: MainsRegion = .hz60
    var harmonicCount = 8
    var q = 30.0
    var harmonicDepthsDB: [Double] = [
        -24, -18, -15, -12, -10, -8, -6, -6,
        0, 0, 0, 0, 0, 0, 0, 0,
    ]

    var fundamentalHz: Double { region.fundamentalHz }

    func validate() throws {
        guard Self.harmonicCountRange.contains(harmonicCount),
              q.isFinite, Self.qRange.contains(q),
              harmonicDepthsDB.count == Self.maximumHarmonics,
              harmonicDepthsDB.allSatisfy({ $0.isFinite && Self.depthRange.contains($0) }) else {
            throw DynamicsConfigurationError.invalidMainsNotch
        }
    }
}
'''
text = replace_once(text, insert_after_infrasonic, mains_swift, 'Swift mains config')
text = replace_once(text,
    '    var infrasonicFilter = InfrasonicFilterConfiguration()\n    var loudnessMatch = LoudnessMatchConfiguration()\n',
    '    var infrasonicFilter = InfrasonicFilterConfiguration()\n    var mainsNotch = MainsNotchConfiguration()\n    var loudnessMatch = LoudnessMatchConfiguration()\n',
    'Dynamics mains member')
text = replace_once(text,
    '        try infrasonicFilter.validate()\n        try loudnessMatch.validate()\n',
    '        try infrasonicFilter.validate()\n        try mainsNotch.validate()\n        try loudnessMatch.validate()\n',
    'Dynamics mains validation')
text = replace_once(text,
    '        guard N60DynamicsSnapshotSetInfrasonicFilter(&snapshot, sampleRate, infrasonicFilter.enabled, infrasonicFilter.cutoffHz, infrasonicFilter.slope.cType) else { throw DynamicsConfigurationError.invalidInfrasonicFilter }\n        guard N60DynamicsSnapshotSetLoudnessMatch(\n',
    '''        guard N60DynamicsSnapshotSetInfrasonicFilter(&snapshot, sampleRate, infrasonicFilter.enabled, infrasonicFilter.cutoffHz, infrasonicFilter.slope.cType) else { throw DynamicsConfigurationError.invalidInfrasonicFilter }
        let mainsDepths = mainsNotch.harmonicDepthsDB.map(Float.init)
        let mainsConfigured = mainsDepths.withUnsafeBufferPointer { depths in
            N60DynamicsSnapshotSetMainsNotch(
                &snapshot,
                sampleRate,
                mainsNotch.enabled,
                mainsNotch.fundamentalHz,
                UInt32(mainsNotch.harmonicCount),
                Float(mainsNotch.q),
                depths.baseAddress!,
                UInt32(depths.count)
            )
        }
        guard mainsConfigured else { throw DynamicsConfigurationError.invalidMainsNotch }
        guard N60DynamicsSnapshotSetLoudnessMatch(
''',
    'Dynamics mains snapshot')
sw.write_text(text)

# ---- Dedicated PR31 validation tab ---------------------------------------------
app = Path('NotchSixty/NotchSixtyApp.swift')
text = app.read_text()
marker = '@main\nstruct NotchSixtyApp: App {'
if 'private struct PR31NoiseHumValidationView' not in text:
    if marker not in text:
        raise SystemExit('PR31 app marker missing')
    view = r'''
private struct PR31NoiseHumValidationView: View {
    @ObservedObject var engine: AudioIOEngine

    private func mainsBinding<Value>(_ keyPath: WritableKeyPath<MainsNotchConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch[keyPath: keyPath] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch[keyPath: keyPath] = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private var harmonicCountBinding: Binding<Double> {
        Binding(
            get: { Double(engine.dynamicsConfiguration.mainsNotch.harmonicCount) },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.harmonicCount = Int(value.rounded())
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private func harmonicDepthBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch.harmonicDepthsDB[index] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.harmonicDepthsDB[index] = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    var body: some View {
        let enabled = mainsBinding(\.enabled)
        let region = mainsBinding(\.region)
        let q = mainsBinding(\.q)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PR31 Noise / Hum Validation")
                    .font(.title2.bold())
                Text("First PR31 slice: independently authored static mains-hum harmonic suppression. Detection/tracking and spectral denoising follow in the same PR.")
                    .foregroundStyle(.secondary)

                GroupBox("Mains Hum Notch") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable Mains Hum Notch", isOn: enabled).toggleStyle(.switch)

                        Picker("Region", selection: region) {
                            ForEach(MainsRegion.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)

                        HStack(spacing: 12) {
                            Text("Harmonics").frame(width: 90, alignment: .leading)
                            Slider(value: harmonicCountBinding, in: 1...16, step: 1)
                            Text("\(engine.dynamicsConfiguration.mainsNotch.harmonicCount)")
                                .monospacedDigit().frame(width: 36)
                        }

                        HStack(spacing: 12) {
                            Text("Q").frame(width: 90, alignment: .leading)
                            Slider(value: q, in: MainsNotchConfiguration.qRange, step: 1)
                            Text("\(engine.dynamicsConfiguration.mainsNotch.q, specifier: "%.0f")")
                                .monospacedDigit().frame(width: 48)
                        }

                        Divider()
                        Text("Per-harmonic depth")
                            .font(.subheadline.bold())
                        ForEach(0..<engine.dynamicsConfiguration.mainsNotch.harmonicCount, id: \.self) { index in
                            HStack(spacing: 12) {
                                let frequency = engine.dynamicsConfiguration.mainsNotch.fundamentalHz * Double(index + 1)
                                Text("H\(index + 1)  \(frequency, specifier: "%.0f") Hz")
                                    .frame(width: 105, alignment: .leading)
                                Slider(value: harmonicDepthBinding(index), in: MainsNotchConfiguration.depthRange, step: 1)
                                Text("\(engine.dynamicsConfiguration.mainsNotch.harmonicDepthsDB[index], specifier: "%.0f") dB")
                                    .monospacedDigit().frame(width: 70)
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox("Detection / Tracking") {
                    Text("One-shot Detect and Continuous Tracking are the next PR31 slice. The static 50/60 Hz processor is intentionally validated first so detector behavior cannot hide filter-path errors.")
                        .foregroundStyle(.secondary)
                        .padding(6)
                }

                GroupBox("Spectral Denoising") {
                    Text("Natural / Standard / Aggressive / Dehiss presets, profile Capture / Reset, protected-frequency range, and Quality / High / Ultra modes are the following PR31 slice.")
                        .foregroundStyle(.secondary)
                        .padding(6)
                }

                Text("Acceptance focus for this slice: with the filter disabled the path must be transparent; with it enabled, a 50/60 Hz tone and selected harmonics should fall by the configured depth without broad tonal loss. Toggle and parameter changes must remain stable and click-free enough for interactive validation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 880, minHeight: 700)
    }
}

'''
    text = text.replace(marker, view + marker, 1)

tab_anchor = '''                PR30PhaseTimeValidationView(engine: product.audioEngine)
                    .tabItem { Label("PR30 Phase / Time", systemImage: "timeline.selection") }'''
if 'Label("PR31 Noise / Hum"' not in text:
    if tab_anchor not in text:
        raise SystemExit('PR30 tab anchor missing')
    text = text.replace(tab_anchor, tab_anchor + '''

                PR31NoiseHumValidationView(engine: product.audioEngine)
                    .tabItem { Label("PR31 Noise / Hum", systemImage: "waveform.slash") }''', 1)
app.write_text(text)

# ---- Deterministic regression tests --------------------------------------------
tests = Path('NotchSixtyTests/NotchSixtyTests.swift')
text = tests.read_text()
if 'testMainsNotchSuppressesConfiguredFundamentalAcrossRates' not in text:
    text += r'''

extension NotchSixtyTests {
    func testMainsNotchSuppressesConfiguredFundamentalAcrossRates() throws {
        for rate in [48_000.0, 96_000.0, 384_000.0] {
            let gainDB = try measuredMainsNotchGainDB(
                sampleRate: rate,
                toneFrequency: 60,
                region: .hz60,
                harmonic: 1,
                depthDB: -24
            )
            XCTAssertLessThan(gainDB, -20.0, "Insufficient 60 Hz rejection at \(rate) Hz")
        }
    }

    func testMainsNotchTargetsSelectedHarmonicWithoutBroadLevelLoss() throws {
        let secondHarmonic = try measuredMainsNotchGainDB(
            sampleRate: 96_000,
            toneFrequency: 120,
            region: .hz60,
            harmonic: 2,
            depthDB: -18
        )
        let offBand = try measuredMainsNotchGainDB(
            sampleRate: 96_000,
            toneFrequency: 1_000,
            region: .hz60,
            harmonic: 2,
            depthDB: -18
        )
        XCTAssertLessThan(secondHarmonic, -14.0)
        XCTAssertGreaterThan(offBand, -0.15)
    }

    func testMainsNotchDisabledIsTransparent() throws {
        guard let kernel = N60RenderKernelCreate() else { return XCTFail("Unable to create render kernel") }
        defer { N60RenderKernelDestroy(kernel) }
        var dynamics = DynamicsConfiguration()
        dynamics.mainsNotch.enabled = false
        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        graph.dynamics = try dynamics.makeSnapshot(sampleRate: 96_000)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        for frame in 0..<4_000 {
            let leftIn = Float(sin(Double(frame) * 0.071) * 0.35)
            let rightIn = Float(cos(Double(frame) * 0.053) * 0.27)
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, leftIn, rightIn, &left, &right)
            XCTAssertEqual(left, leftIn, accuracy: 0.000_001)
            XCTAssertEqual(right, rightIn, accuracy: 0.000_001)
        }
    }

    private func measuredMainsNotchGainDB(
        sampleRate: Double,
        toneFrequency: Double,
        region: MainsRegion,
        harmonic: Int,
        depthDB: Double
    ) throws -> Double {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to create render kernel")
            return 0
        }
        defer { N60RenderKernelDestroy(kernel) }

        var dynamics = DynamicsConfiguration()
        dynamics.mainsNotch.enabled = true
        dynamics.mainsNotch.region = region
        dynamics.mainsNotch.harmonicCount = max(1, harmonic)
        dynamics.mainsNotch.q = 30
        dynamics.mainsNotch.harmonicDepthsDB = Array(repeating: 0, count: MainsNotchConfiguration.maximumHarmonics)
        dynamics.mainsNotch.harmonicDepthsDB[harmonic - 1] = depthDB

        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        graph.dynamics = try dynamics.makeSnapshot(sampleRate: sampleRate)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        let frameCount = max(Int(sampleRate * 0.35), 16_000)
        let settleFrames = max(Int(sampleRate * 0.08), 4_000)
        var inputEnergy = 0.0
        var outputEnergy = 0.0
        var measuredFrames = 0
        for frame in 0..<frameCount {
            let sample = Float(0.1 * sin(2.0 * Double.pi * toneFrequency * Double(frame) / sampleRate))
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
            if frame >= settleFrames {
                inputEnergy += Double(sample * sample)
                outputEnergy += Double(left * left)
                measuredFrames += 1
            }
        }
        let inputRMS = sqrt(inputEnergy / Double(measuredFrames))
        let outputRMS = sqrt(outputEnergy / Double(measuredFrames))
        return 20.0 * log10(max(outputRMS, 1.0e-12) / max(inputRMS, 1.0e-12))
    }
}
'''
tests.write_text(text)

# ---- Provenance ----------------------------------------------------------------
prov = Path('docs/PROVENANCE.md')
text = prov.read_text()
entry = '''

## PR31 — Noise / Hum suppression

PR31 is a clean-room implementation. Historical Notch Sixty documentation, UI, and configuration state are used only to inventory observable behavior for Mains Hum Notch and spectral denoising. Historical `SpectralDenoiser`, `MainsHumDetector`, `GoertzelEstimator`, `MainsNotchCoefficients`, and DSP tests are explicitly excluded as implementation references.

The first slice implements the static harmonic-notch signal path independently from standard parametric-biquad mathematics already present in the commercial engine. Nominal 50/60 Hz selection, harmonic count, Q, and per-harmonic attenuation are product controls; coefficients are designed on the control plane and consumed by fixed realtime state. Detector/tracker and spectral-denoising mathematics will be independently derived in later PR31 slices from public DSP references and synthetic test vectors.
'''
if '## PR31 — Noise / Hum suppression' not in text:
    text += entry
prov.write_text(text)
