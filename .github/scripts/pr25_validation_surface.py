from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    t = p.read_text()
    if t.count(old) < count:
        raise SystemExit(f'pattern missing in {path}: {old[:120]!r}')
    p.write_text(t.replace(old, new, count))

# Minimal engineering validation UI: replace Flat toggle with explicit audition picker.
path = 'NotchSixty/ContentView.swift'
replace(path,
'''    private var flatAuditionBinding: Binding<Bool> {
        Binding(get: { engine.playbackControlConfiguration.flatAuditionEnabled }, set: { try? engine.setFlatAuditionEnabled($0) })
    }
''',
'''    private var auditionModeBinding: Binding<AuditionMode> {
        Binding(get: { engine.playbackControlConfiguration.auditionMode }, set: { try? engine.setAuditionMode($0) })
    }
''')
replace(path,
'''                Toggle("Global Bypass", isOn: globalBypassBinding).toggleStyle(.switch)
                Toggle("Flat", isOn: flatAuditionBinding).toggleStyle(.switch)
''',
'''                Toggle("Global Bypass", isOn: globalBypassBinding).toggleStyle(.switch)
                Picker("Audition", selection: auditionModeBinding) {
                    ForEach(AuditionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
''')
replace(path,
'''            Text("Balance is attenuation-only; center is exact unity. Global Bypass and Flat preserve all configured DSP state while auditioning the untreated input.")
''',
'''            Text("Processed runs the configured DSP. Reference is untreated input delayed to the processed-path latency. Delta is Processed − Reference. Global Bypass remains the true raw escape path.")
''')

# Roadmap: make full dynamics parity scope explicit.
path = 'docs/ROADMAP.md'
replace(path,
'''### Stage C — core dynamics + oversampling
- detector/envelope infrastructure
- compressor
- expander
- pause gate
- look-ahead/brickwall limiter
- soft clipper
- 1x / 2x / 4x oversampling
- true-peak infrastructure
- gain-reduction telemetry
- automatic-headroom hooks
''',
'''### Stage C — full legacy dynamics parity + oversampling
The legacy application exposes roughly 30 dynamics-related capabilities. **Every one of them must be inventoried and reach PARITY, IMPROVED, PORT VERIFIED, or an explicit superseding implementation before parity closure.** This stage may span multiple implementation PRs for review and realtime-risk control; splitting the work does not reduce the parity requirement.

Foundation and known capabilities include:
- detector/envelope infrastructure
- compressor and all legacy compressor variants/modes
- expander and all legacy expander variants/modes
- pause gate and related gate controls
- look-ahead / brickwall limiting and all legacy limiter modes
- soft clipping / clipping protection
- de-essing and multiband dynamics
- loudness/dynamics compensation features where classified as dynamics
- true-peak infrastructure and legacy true-peak/clip trip behavior
- stage gain-reduction telemetry and metering
- automatic-headroom interactions
- 1x / 2x / 4x oversampling and every legacy oversampling-dependent dynamics path
- all additional legacy dynamics features discovered by the formal inventory, even if not named above

For each legacy dynamics capability, apply the provenance gate: inherited/GPL-path implementations are independently recreated; demonstrably owner-authored post-fork implementations may be deliberately ported only after provenance and quality review; clean but weak/buggy implementations are reimplemented or improved.
''')
replace(path,
'''- processed/flat comparison
- Delta monitoring
''',
'''- latency-matched Processed / Reference comparison
- Delta monitoring (`Processed − latency-matched Reference`)
''')

# Provenance: append PR25 architecture row next to playback controls.
path = 'docs/PROVENANCE.md'
p = Path(path)
t = p.read_text()
needle = '| Master volume, mute, and fixed-output keyboard volume |'
idx = t.find(needle)
if idx < 0:
    raise SystemExit('master-volume provenance row missing')
line_end = t.find('\n', idx)
row = '\n| Latency-matched Reference / Delta audition | Original commercial implementation | Product audition requirements + proprietary graph latency contract + existing PR #12–24 render architecture | PR #25 adds a preallocated stereo reference-delay lane keyed directly to the published graph latency, explicit Processed/Reference/Delta semantics, and deterministic null/latency tests. Global Bypass remains a separate raw escape path. No historical GPL implementation or tests were used as implementation references. |'
t = t[:line_end] + row + t[line_end:]
p.write_text(t)
