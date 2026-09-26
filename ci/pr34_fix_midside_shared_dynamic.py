from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)

path = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
text = path.read_text()

text = replace_once(
    text,
    '''        let dynamicBoost: Double
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
''',
    '''        let dynamicBoost: Double
        if phaseMode == .minimumPhase && !bypassed {
            // Dynamic EQ is a shared physical-stereo layer. The Linked bank owns
            // its settings even while static EQ editing is Independent or Mid/Side.
            dynamicBoost = linkedBands.lazy
                .filter { $0.enabled && $0.type == .peaking && $0.dynamic.enabled }
                .reduce(0.0) { partial, band in
                    let dynamicPart = band.dynamic.direction == .cutOnly ? 0.0 : max(0.0, band.dynamic.maxBoostDB)
                    return partial + dynamicPart
                }
        } else {
            dynamicBoost = 0
        }
''',
    "shared Dynamic EQ automatic headroom",
)

text = replace_once(
    text,
    '''        // Product state is owned by the normal EQ bands. Keep the standalone C
        // Dynamic EQ engine as an implementation detail and compile only the
        // linked minimum-phase peaking bands that have Dynamic enabled.
        dynamics.dynamicEQ = DynamicEQConfiguration()
        guard phaseMode == .minimumPhase,
              !bypassed,
              channelMode == .linked else { return }

        let dynamicBands = try validatedEnabledBands(linkedBands, sampleRate: sampleRate)
''',
    '''        // Dynamic EQ is intentionally shared across channel-editing modes.
        // The Linked bank owns the detector/gain settings; the realtime engine
        // applies that one physical-stereo dynamic layer after any Mid/Side
        // decode so no independent M/S or L/R detector behavior is invented.
        dynamics.dynamicEQ = DynamicEQConfiguration()
        guard phaseMode == .minimumPhase,
              !bypassed else { return }

        let dynamicBands = try validatedEnabledBands(linkedBands, sampleRate: sampleRate)
''',
    "shared Dynamic EQ compiler",
)
path.write_text(text)

view_path = Path("NotchSixty/ContentView.swift")
view = view_path.read_text()
view = replace_once(
    view,
    'Text("Commercial capacity: up to \\(EQConfiguration.maximumBandCount) EQ bands. Dynamic is available for linked, minimum-phase Peak bands; the standalone C detector/gain engine remains an internal implementation detail.")',
    'Text("Commercial capacity: up to \\(EQConfiguration.maximumBandCount) EQ bands. Dynamic settings are owned by Linked minimum-phase Peak bands and remain active as one identical physical-stereo layer while static EQ editing is Independent or Mid/Side.")',
    "Dynamic EQ validation copy",
)
view_path.write_text(view)

tests_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = tests_path.read_text()
test = r'''    func testMidSideKeepsLinkedDynamicEQAsOneSharedPhysicalStereoLayer() throws {
        var dynamic = EQBandDynamicConfiguration()
        dynamic.enabled = true
        dynamic.thresholdDB = -30
        dynamic.ratio = 2
        dynamic.rangeDB = -6

        let sharedDynamicBand = EQBand(
            type: .peaking,
            frequencyHz: 1_000,
            gainDB: 0,
            q: 1.0,
            dynamic: dynamic
        )
        let midStaticBand = EQBand(type: .peaking, frequencyHz: 700, gainDB: 2, q: 1.0)
        let sideStaticBand = EQBand(type: .peaking, frequencyHz: 4_000, gainDB: -2, q: 1.0)

        let configuration = StereoEQConfiguration(
            channelMode: .midSide,
            editChannel: .mid,
            phaseMode: .minimumPhase,
            linkedBands: [sharedDynamicBand],
            midBands: [midStaticBand],
            sideBands: [sideStaticBand],
            midSideSeeded: true
        )
        let graph = try configuration.makeGraphSnapshot(
            sampleRate: 96_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertTrue(graph.eqMidSideMode)
        XCTAssertTrue(graph.dynamics.dynamicEQ.enabled)
        XCTAssertEqual(graph.dynamics.dynamicEQ.bandCount, 1)
    }

'''
if "testMidSideKeepsLinkedDynamicEQAsOneSharedPhysicalStereoLayer" not in tests:
    marker = "    func testMidSideRealtimeIdentityAndAuditionContracts() throws {\n"
    if marker not in tests:
        raise SystemExit("Expected shared Dynamic EQ test insertion point was not found")
    tests = tests.replace(marker, test + marker, 1)
tests_path.write_text(tests)

print("PR34 Mid/Side shared Dynamic EQ mapping applied.")
