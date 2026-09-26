from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)


# Correct the shared Dynamic-EQ source-of-truth mapping. Dynamic processing remains
# one physical-stereo layer; only its control-plane source follows the audited
# Linked / Left / Mid ownership contract.
path = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
text = path.read_text()

text = replace_once(
    text,
    '''    private func conservativeAutomaticHeadroomDB(
        dynamics: DynamicsConfiguration
    ) -> Double {
''',
    '''    private var sharedDynamicSourceBands: [EQBand] {
        switch channelMode {
        case .linked: return linkedBands
        case .independent: return leftBands
        case .midSide: return midBands
        }
    }

    private func conservativeAutomaticHeadroomDB(
        dynamics: DynamicsConfiguration
    ) -> Double {
''',
    "shared Dynamic EQ source helper",
)

text = replace_once(
    text,
    '''        let dynamicBoost: Double
        if phaseMode != .linearPhase && !bypassed {
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
    '''        let dynamicBoost: Double
        if phaseMode != .linearPhase && !bypassed {
            // Dynamic EQ remains one physical-stereo layer. Its controls follow
            // the audited source-of-truth bank: Linked, Left, or Mid.
            dynamicBoost = sharedDynamicSourceBands.lazy
                .filter { $0.enabled && $0.type == .peaking && $0.dynamic.enabled }
                .reduce(0.0) { partial, band in
                    let dynamicPart = band.dynamic.direction == .cutOnly ? 0.0 : max(0.0, band.dynamic.maxBoostDB)
                    return partial + dynamicPart
                }
        } else {
            dynamicBoost = 0
        }
''',
    "shared Dynamic EQ automatic headroom owner",
)

text = replace_once(
    text,
    '''        // Dynamic EQ is intentionally shared across channel-editing modes.
        // The Linked bank owns the detector/gain settings; the realtime engine
        // applies that one physical-stereo dynamic layer after any Mid/Side
        // decode so no independent M/S or L/R detector behavior is invented.
        dynamics.dynamicEQ = DynamicEQConfiguration()
        guard phaseMode != .linearPhase,
              !bypassed else { return }

        let dynamicBands = try validatedEnabledBands(linkedBands, sampleRate: sampleRate)
            .filter { $0.type == .peaking && $0.dynamic.enabled }
''',
    '''        // Dynamic EQ is intentionally shared across channel-editing modes.
        // Linked owns its controls in Linked mode, Left in Independent mode, and
        // Mid in Mid/Side mode. The realtime engine still applies exactly one
        // physical-stereo layer after any Mid/Side decode; no asymmetric detector
        // behavior is implied or created by the static channel editor.
        dynamics.dynamicEQ = DynamicEQConfiguration()
        guard phaseMode != .linearPhase,
              !bypassed else { return }

        let dynamicBands = try validatedEnabledBands(sharedDynamicSourceBands, sampleRate: sampleRate)
            .filter { $0.type == .peaking && $0.dynamic.enabled }
''',
    "shared Dynamic EQ compiler owner",
)
path.write_text(text)


# Make the UI editable on the actual owner banks instead of globally disabling
# Dynamic whenever the static editor leaves Linked mode.
view_path = Path("NotchSixty/ContentView.swift")
view = view_path.read_text()

view = replace_once(
    view,
    '''        let binding = eqBandBinding(for: band.id)
        let dynamicSupported = engine.eqConfiguration.phaseMode != .linearPhase
            && engine.stereoEQConfiguration.channelMode == .linked
            && band.type == .peaking
''',
    '''        let binding = eqBandBinding(for: band.id)
        let dynamicOwnerChannel: Bool = {
            switch engine.stereoEQConfiguration.channelMode {
            case .linked:
                return true
            case .independent:
                return engine.stereoEQConfiguration.editChannel == .left
            case .midSide:
                return engine.stereoEQConfiguration.editChannel == .mid
            }
        }()
        let dynamicSupported = engine.eqConfiguration.phaseMode != .linearPhase
            && dynamicOwnerChannel
            && band.type == .peaking
''',
    "Dynamic EQ UI owner enablement",
)

view = replace_once(
    view,
    '''                Button("Remove") { try? engine.removeEQBand(id: band.id) }
            }

            if band.type.supportsSlope {
''',
    '''                Button("Remove") { try? engine.removeEQBand(id: band.id) }
            }

            if engine.eqConfiguration.phaseMode != .linearPhase && band.type == .peaking && !dynamicOwnerChannel {
                Text(engine.stereoEQConfiguration.channelMode == .midSide
                     ? "Dynamic EQ is shared across physical L/R; edit Dynamic settings from Mid."
                     : "Dynamic EQ is shared across physical L/R; edit Dynamic settings from Left.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if band.type.supportsSlope {
''',
    "Dynamic EQ owner guidance",
)

view = replace_once(
    view,
    'Text("Commercial capacity: up to \\(EQConfiguration.maximumBandCount) EQ bands. Dynamic settings are owned by Linked minimum-phase Peak bands and remain active as one identical physical-stereo layer while static EQ editing is Independent or Mid/Side.")',
    'Text("Commercial capacity: up to \\(EQConfiguration.maximumBandCount) EQ bands. Dynamic settings are owned by Linked, Left (Independent), or Mid (Mid/Side) Peak bands in Minimum/Mixed Phase and render as one identical physical-stereo layer.")',
    "Dynamic EQ validation copy",
)
view_path.write_text(view)


# Replace the earlier Linked-only regression with the audited owner-bank contract,
# and add the corresponding Independent-mode check.
tests_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = tests_path.read_text()
old_test = r'''    func testMidSideKeepsLinkedDynamicEQAsOneSharedPhysicalStereoLayer() throws {
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
new_test = r'''    func testMidSideUsesMidBankForSharedDynamicEQ() throws {
        var dynamic = EQBandDynamicConfiguration()
        dynamic.enabled = true
        dynamic.thresholdDB = -30
        dynamic.ratio = 2
        dynamic.rangeDB = -6

        let midDynamicBand = EQBand(
            type: .peaking,
            frequencyHz: 1_000,
            gainDB: 0,
            q: 1.0,
            dynamic: dynamic
        )
        let sideStaticBand = EQBand(type: .peaking, frequencyHz: 4_000, gainDB: -2, q: 1.0)

        let configuration = StereoEQConfiguration(
            channelMode: .midSide,
            editChannel: .mid,
            phaseMode: .minimumPhase,
            linkedBands: [],
            midBands: [midDynamicBand],
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

        let sideOnly = StereoEQConfiguration(
            channelMode: .midSide,
            editChannel: .side,
            phaseMode: .minimumPhase,
            linkedBands: [],
            midBands: [],
            sideBands: [midDynamicBand],
            midSideSeeded: true
        )
        let sideOnlyGraph = try sideOnly.makeGraphSnapshot(
            sampleRate: 96_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertFalse(sideOnlyGraph.dynamics.dynamicEQ.enabled)
        XCTAssertEqual(sideOnlyGraph.dynamics.dynamicEQ.bandCount, 0)
    }

    func testIndependentUsesLeftBankForSharedDynamicEQ() throws {
        var dynamic = EQBandDynamicConfiguration()
        dynamic.enabled = true
        let leftDynamicBand = EQBand(
            type: .peaking,
            frequencyHz: 1_600,
            gainDB: 0,
            q: 1.2,
            dynamic: dynamic
        )

        let leftOwned = StereoEQConfiguration(
            channelMode: .independent,
            editChannel: .left,
            phaseMode: .mixedPhase,
            linkedBands: [],
            leftBands: [leftDynamicBand],
            rightBands: [],
            independentSeeded: true
        )
        let leftGraph = try leftOwned.makeGraphSnapshot(
            sampleRate: 192_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertTrue(leftGraph.dynamics.dynamicEQ.enabled)
        XCTAssertEqual(leftGraph.dynamics.dynamicEQ.bandCount, 1)

        let rightOnly = StereoEQConfiguration(
            channelMode: .independent,
            editChannel: .right,
            phaseMode: .mixedPhase,
            linkedBands: [],
            leftBands: [],
            rightBands: [leftDynamicBand],
            independentSeeded: true
        )
        let rightGraph = try rightOnly.makeGraphSnapshot(
            sampleRate: 192_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertFalse(rightGraph.dynamics.dynamicEQ.enabled)
        XCTAssertEqual(rightGraph.dynamics.dynamicEQ.bandCount, 0)
    }

'''
if new_test not in tests:
    if old_test not in tests:
        raise SystemExit("Expected old shared Dynamic EQ regression test was not found")
    tests = tests.replace(old_test, new_test, 1)
tests_path.write_text(tests)

print("PR34 Dynamic EQ owner-bank parity fix applied.")
