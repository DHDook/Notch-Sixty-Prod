from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)


# Clean the standalone designer before it is imported into the app target.
mixed_path = Path("NotchSixty/Audio/Realtime/N60MixedPhase.h")
mixed = mixed_path.read_text()
mixed = mixed.replace("    double correctionPhase[N60_MIXED_PHASE_ANALYSIS_POINTS] = {0};\n", "")
mixed = mixed.replace("            correctionPhase[point] += bestCandidatePhase[point];\n", "")
mixed_path.write_text(mixed)


# ---------------------------------------------------------------------------
# Realtime graph: reserve bounded internal sections without reducing the
# 64-logical-band user capacity, and expose honest Mixed diagnostics.
# ---------------------------------------------------------------------------
header_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.h")
header = header_path.read_text()
header = replace_once(
    header,
    '#include "N60FractionalDelay.h"\n#include "N60Protection.h"',
    '#include "N60FractionalDelay.h"\n#include "N60MixedPhase.h"\n#include "N60Protection.h"',
    "Mixed Phase header include",
)
header = replace_once(
    header,
    "#define N60_MAX_EQ_BANDS 64\n#define N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND 8\n#define N60_MAX_EQ_RENDER_SLOTS (N60_MAX_EQ_BANDS * 2 * N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND)",
    "#define N60_MAX_EQ_BANDS 64\n#define N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND 8\n#define N60_MAX_EQ_USER_RENDER_SLOTS (N60_MAX_EQ_BANDS * 2 * N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND)\n#define N60_MAX_EQ_MIXED_PHASE_RENDER_SLOTS (2u * N60_MIXED_PHASE_MAX_SECTIONS_PER_LANE)\n#define N60_MAX_EQ_RENDER_SLOTS (N60_MAX_EQ_USER_RENDER_SLOTS + N60_MAX_EQ_MIXED_PHASE_RENDER_SLOTS)",
    "Mixed Phase render reserve",
)
header = replace_once(
    header,
    "    bool eqBypassed;\n    bool eqMidSideMode;\n    uint32_t eqBandCount;",
    "    bool eqBypassed;\n    bool eqMidSideMode;\n    bool mixedPhaseEnabled;\n    uint32_t mixedPhaseCorrectionSectionCount;\n    uint32_t eqBandCount;",
    "Mixed Phase graph state",
)
header = replace_once(
    header,
    "    bool eqBypassed;\n    bool eqMidSideMode;\n    uint32_t eqBandCount;",
    "    bool eqBypassed;\n    bool eqMidSideMode;\n    bool mixedPhaseEnabled;\n    uint32_t mixedPhaseCorrectionSectionCount;\n    uint32_t eqBandCount;",
    "Mixed Phase diagnostics",
)
header_path.write_text(header)

kernel_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.c")
kernel = kernel_path.read_text()
kernel = replace_once(
    kernel,
    "        || snapshot.eqBandCount > N60_MAX_EQ_RENDER_SLOTS\n        || !crossover_snapshot_is_valid",
    "        || snapshot.eqBandCount > N60_MAX_EQ_RENDER_SLOTS\n        || snapshot.mixedPhaseCorrectionSectionCount > N60_MAX_EQ_MIXED_PHASE_RENDER_SLOTS\n        || (!snapshot.mixedPhaseEnabled && snapshot.mixedPhaseCorrectionSectionCount != 0u)\n        || !crossover_snapshot_is_valid",
    "Mixed Phase snapshot validation",
)
kernel = replace_once(
    kernel,
    "    snapshot.eqBypassed = false;\n    snapshot.eqBandCount = 0;",
    "    snapshot.eqBypassed = false;\n    snapshot.mixedPhaseEnabled = false;\n    snapshot.mixedPhaseCorrectionSectionCount = 0;\n    snapshot.eqBandCount = 0;",
    "Mixed Phase unity state",
)
kernel = replace_once(
    kernel,
    "        diagnostics.eqBypassed = context.snapshot.eqBypassed;\n        diagnostics.eqMidSideMode = context.snapshot.eqMidSideMode;\n        diagnostics.eqBandCount = context.snapshot.eqBandCount;",
    "        diagnostics.eqBypassed = context.snapshot.eqBypassed;\n        diagnostics.eqMidSideMode = context.snapshot.eqMidSideMode;\n        diagnostics.mixedPhaseEnabled = context.snapshot.mixedPhaseEnabled;\n        diagnostics.mixedPhaseCorrectionSectionCount = context.snapshot.mixedPhaseCorrectionSectionCount;\n        diagnostics.eqBandCount = context.snapshot.eqBandCount;",
    "Mixed Phase diagnostics publication",
)
kernel_path.write_text(kernel)


# ---------------------------------------------------------------------------
# Swift phase model + compatibility compiler.
# ---------------------------------------------------------------------------
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
engine = replace_once(
    engine,
    "enum EQPhaseMode: String, CaseIterable, Identifiable, Sendable {\n    case minimumPhase\n    case linearPhase",
    "enum EQPhaseMode: String, CaseIterable, Identifiable, Sendable {\n    case minimumPhase\n    case mixedPhase\n    case linearPhase",
    "Mixed Phase model case",
)
engine = replace_once(
    engine,
    '        case .minimumPhase: return "Minimum phase"\n        case .linearPhase: return "Linear phase"',
    '        case .minimumPhase: return "Minimum phase"\n        case .mixedPhase: return "Mixed phase"\n        case .linearPhase: return "Linear phase"',
    "Mixed Phase display name",
)
engine = replace_once(
    engine,
    "    case linearPhaseDesignFailed\n    case convolutionProgramUnavailable",
    "    case linearPhaseDesignFailed\n    case mixedPhaseDesignFailed\n    case convolutionProgramUnavailable",
    "Mixed Phase configuration error",
)
engine = replace_once(
    engine,
    '        case .linearPhaseDesignFailed:\n            return "Unable to design the linear-phase FIR for the current EQ configuration."\n        case .convolutionProgramUnavailable:',
    '        case .linearPhaseDesignFailed:\n            return "Unable to design the linear-phase FIR for the current EQ configuration."\n        case .mixedPhaseDesignFailed:\n            return "Unable to design the bounded all-pass correction for the current Mixed Phase EQ configuration."\n        case .convolutionProgramUnavailable:',
    "Mixed Phase error description",
)
engine = engine.replace(
    'return "All-Pass bands are phase-only IIR filters and require Minimum phase EQ mode."',
    'return "User All-Pass bands require Minimum phase EQ mode; Mixed Phase owns its correction all-pass sections internally."'
)

# Compatibility graph: Mixed uses the ordinary compiled IIR response plus a
# bounded internal all-pass cascade; FIR remains a separate convolution asset.
engine = replace_once(
    engine,
    "        if phaseMode == .minimumPhase && !bypassed {\n            var renderIndex: UInt32 = 0\n            for (modelIndex, band) in bands.enumerated() where band.enabled {",
    "        if phaseMode != .linearPhase && !bypassed {\n            var renderIndex: UInt32 = 0\n            var mixedSource: [N60BiquadBandSnapshot] = []\n            for (modelIndex, band) in bands.enumerated() where band.enabled {\n                if phaseMode == .mixedPhase && band.type == .allPass {\n                    throw EQConfigurationError.allPassRequiresMinimumPhase\n                }",
    "compatibility Mixed IIR compilation",
)
engine = replace_once(
    engine,
    "                    renderIndex += 1\n                }\n            }\n        }\n\n        if phaseMode == .minimumPhase && !bypassed {\n            let dynamicBands",
    "                    if phaseMode == .mixedPhase && section.type != N60BiquadFilterTypeAllPass {\n                        mixedSource.append(section)\n                    }\n                    renderIndex += 1\n                }\n            }\n\n            if phaseMode == .mixedPhase {\n                var design = N60MixedPhaseDesignInfo()\n                let designed = mixedSource.withUnsafeBufferPointer { buffer in\n                    N60MixedPhaseDesign(sampleRate, buffer.baseAddress, UInt32(buffer.count), &design)\n                }\n                guard designed else { throw EQConfigurationError.mixedPhaseDesignFailed }\n                graph.mixedPhaseEnabled = true\n                graph.mixedPhaseCorrectionSectionCount = design.sectionCount\n                let totalCapacity = UInt32(EQConfiguration.maximumBandCount * 2 * Int(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND) + 12)\n                for correctionIndex in 0..<design.sectionCount {\n                    let section = N60MixedPhaseDesignSectionAt(&design, correctionIndex)\n                    guard renderIndex < totalCapacity,\n                          N60DSPGraphSnapshotSetEQPreparedBand(\n                            &graph, renderIndex, section.type, section.frequencyHz,\n                            section.gainDB, section.q, section.coefficients, true\n                          ) else {\n                        throw EQConfigurationError.mixedPhaseDesignFailed\n                    }\n                    renderIndex += 1\n                }\n            }\n        }\n\n        if phaseMode != .linearPhase && !bypassed {\n            let dynamicBands",
    "compatibility Mixed correction publication",
)
engine_path.write_text(engine)


# ---------------------------------------------------------------------------
# Live stereo compiler: lane-specific source analysis for Linked, L/R, and M/S.
# ---------------------------------------------------------------------------
stereo_path = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
stereo = stereo_path.read_text()
stereo = stereo.replace("if phaseMode == .minimumPhase && !bypassed {\n            // Dynamic EQ is a shared physical-stereo layer.", "if phaseMode != .linearPhase && !bypassed {\n            // Dynamic EQ is a shared physical-stereo layer.")
stereo = stereo.replace("guard phaseMode == .minimumPhase,\n              !bypassed else { return }", "guard phaseMode != .linearPhase,\n              !bypassed else { return }")

helper_marker = "    var requiresEQFIRProgram: Bool {\n"
helpers = '''    private func mixedPhaseSourceSections(
        _ bands: [EQBand],
        sampleRate: Double
    ) throws -> [N60BiquadBandSnapshot] {
        var source: [N60BiquadBandSnapshot] = []
        for band in try validatedEnabledBands(bands, sampleRate: sampleRate) {
            if band.type == .fir { continue }
            if band.type == .allPass { throw EQConfigurationError.allPassRequiresMinimumPhase }
            source.append(contentsOf: try band.compiledSections(sampleRate: sampleRate))
        }
        return source
    }

    private func appendMixedPhaseCorrection(
        for bands: [EQBand],
        sampleRate: Double,
        into graph: inout N60DSPGraphSnapshot,
        renderIndex: inout UInt32,
        channelMask: UInt8? = nil
    ) throws {
        let source = try mixedPhaseSourceSections(bands, sampleRate: sampleRate)
        var design = N60MixedPhaseDesignInfo()
        let designed = source.withUnsafeBufferPointer { buffer in
            N60MixedPhaseDesign(sampleRate, buffer.baseAddress, UInt32(buffer.count), &design)
        }
        guard designed else { throw EQConfigurationError.mixedPhaseDesignFailed }
        let userCapacity = EQConfiguration.maximumBandCount * 2 * Int(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND)
        let totalCapacity = UInt32(userCapacity + 12)
        for correctionIndex in 0..<design.sectionCount {
            let section = N60MixedPhaseDesignSectionAt(&design, correctionIndex)
            guard renderIndex < totalCapacity else { throw EQConfigurationError.mixedPhaseDesignFailed }
            let ok: Bool
            if let channelMask {
                ok = N60DSPGraphSnapshotSetEQPreparedBandForChannels(
                    &graph, renderIndex, channelMask, section.type,
                    section.frequencyHz, section.gainDB, section.q,
                    section.coefficients, true
                )
            } else {
                ok = N60DSPGraphSnapshotSetEQPreparedBand(
                    &graph, renderIndex, section.type,
                    section.frequencyHz, section.gainDB, section.q,
                    section.coefficients, true
                )
            }
            guard ok else { throw EQConfigurationError.mixedPhaseDesignFailed }
            renderIndex += 1
        }
        graph.mixedPhaseCorrectionSectionCount += design.sectionCount
    }

'''
if "private func mixedPhaseSourceSections" not in stereo:
    if helper_marker not in stereo:
        raise SystemExit("Expected Mixed helper insertion point was not found")
    stereo = stereo.replace(helper_marker, helpers + helper_marker, 1)

old_block = '''        if phaseMode == .minimumPhase && !bypassed && !graph.bypassed {
            var renderIndex: UInt32 = 0
            switch channelMode {
            case .linked:
                for band in try validatedEnabledBands(linkedBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(band, into: &graph, renderIndex: &renderIndex)
                }
            case .independent:
                for band in try validatedEnabledBands(leftBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                }
                for band in try validatedEnabledBands(rightBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                }
            case .midSide:
                for band in try validatedEnabledBands(midBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                }
                for band in try validatedEnabledBands(sideBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                }
            }
        }
'''
new_block = '''        if phaseMode != .linearPhase && !bypassed && !graph.bypassed {
            var renderIndex: UInt32 = 0
            switch channelMode {
            case .linked:
                for band in try validatedEnabledBands(linkedBands, sampleRate: sampleRate) {
                    if phaseMode == .mixedPhase && band.type == .allPass {
                        throw EQConfigurationError.allPassRequiresMinimumPhase
                    }
                    try publishMinimumPhaseBand(band, into: &graph, renderIndex: &renderIndex)
                }
                if phaseMode == .mixedPhase {
                    graph.mixedPhaseEnabled = true
                    try appendMixedPhaseCorrection(
                        for: linkedBands, sampleRate: sampleRate,
                        into: &graph, renderIndex: &renderIndex
                    )
                }
            case .independent:
                for band in try validatedEnabledBands(leftBands, sampleRate: sampleRate) {
                    if phaseMode == .mixedPhase && band.type == .allPass {
                        throw EQConfigurationError.allPassRequiresMinimumPhase
                    }
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                }
                for band in try validatedEnabledBands(rightBands, sampleRate: sampleRate) {
                    if phaseMode == .mixedPhase && band.type == .allPass {
                        throw EQConfigurationError.allPassRequiresMinimumPhase
                    }
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                }
                if phaseMode == .mixedPhase {
                    graph.mixedPhaseEnabled = true
                    try appendMixedPhaseCorrection(
                        for: leftBands, sampleRate: sampleRate,
                        into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                    try appendMixedPhaseCorrection(
                        for: rightBands, sampleRate: sampleRate,
                        into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                }
            case .midSide:
                for band in try validatedEnabledBands(midBands, sampleRate: sampleRate) {
                    if phaseMode == .mixedPhase && band.type == .allPass {
                        throw EQConfigurationError.allPassRequiresMinimumPhase
                    }
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                }
                for band in try validatedEnabledBands(sideBands, sampleRate: sampleRate) {
                    if phaseMode == .mixedPhase && band.type == .allPass {
                        throw EQConfigurationError.allPassRequiresMinimumPhase
                    }
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                }
                if phaseMode == .mixedPhase {
                    graph.mixedPhaseEnabled = true
                    try appendMixedPhaseCorrection(
                        for: midBands, sampleRate: sampleRate,
                        into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                    try appendMixedPhaseCorrection(
                        for: sideBands, sampleRate: sampleRate,
                        into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                }
            }
        }
'''
if new_block not in stereo:
    if old_block not in stereo:
        raise SystemExit("Expected live minimum-phase publication block was not found")
    stereo = stereo.replace(old_block, new_block, 1)
stereo_path.write_text(stereo)


# ---------------------------------------------------------------------------
# Validation UI and XCTest contracts.
# ---------------------------------------------------------------------------
content_path = Path("NotchSixty/ContentView.swift")
content = content_path.read_text()
content = content.replace(
    "let dynamicSupported = engine.eqConfiguration.phaseMode == .minimumPhase\n            && engine.stereoEQConfiguration.channelMode == .linked",
    "let dynamicSupported = engine.eqConfiguration.phaseMode != .linearPhase\n            && engine.stereoEQConfiguration.channelMode == .linked"
)
phase_info_marker = '''            if engine.eqConfiguration.phaseMode == .linearPhase {
'''
mixed_info = '''            if engine.eqConfiguration.phaseMode == .mixedPhase {
                let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                Text("Mixed Phase: static biquad EQ plus bounded all-pass phase correction • no FIR pre-ringing • no added fixed/buffer latency • \\(diagnostics?.mixedPhaseCorrectionSectionCount ?? 0) internal correction sections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

'''
if "Mixed Phase: static biquad EQ" not in content:
    if phase_info_marker not in content:
        raise SystemExit("Expected phase info insertion point was not found")
    content = content.replace(phase_info_marker, mixed_info + phase_info_marker, 1)
content_path.write_text(content)


tests_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = tests_path.read_text()
mixed_tests = r'''
    func testMixedPhaseIsFixedThirdPhaseMode() {
        XCTAssertTrue(EQPhaseMode.allCases.contains(.mixedPhase))
        XCTAssertEqual(EQPhaseMode.mixedPhase.displayName, "Mixed phase")
    }

    func testMixedPhaseFlatGraphAddsNoCorrectionOrFixedLatency() throws {
        let configuration = StereoEQConfiguration(phaseMode: .mixedPhase)
        let graph = try configuration.makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertTrue(graph.mixedPhaseEnabled)
        XCTAssertEqual(graph.mixedPhaseCorrectionSectionCount, 0)
        XCTAssertEqual(graph.latencyFrames, 0)
    }

    func testMixedPhaseAddsOnlyUnityMagnitudeAllPassCorrectionThrough384k() throws {
        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            let bands = [
                EQBand(type: .lowShelf, frequencyHz: 120, gainDB: 5, q: 0.707),
                EQBand(type: .peaking, frequencyHz: 1_100, gainDB: 8, q: 2.0),
                EQBand(type: .highShelf, frequencyHz: 7_000, gainDB: -4, q: 0.707),
            ]
            let minimum = StereoEQConfiguration(phaseMode: .minimumPhase, linkedBands: bands)
            let mixed = StereoEQConfiguration(phaseMode: .mixedPhase, linkedBands: bands)
            let minimumGraph = try minimum.makeGraphSnapshot(
                sampleRate: rate,
                gainConfiguration: DSPGainConfiguration(),
                bassManagementConfiguration: BassManagementConfiguration(),
                playbackConfiguration: PlaybackControlConfiguration()
            )
            let mixedGraph = try mixed.makeGraphSnapshot(
                sampleRate: rate,
                gainConfiguration: DSPGainConfiguration(),
                bassManagementConfiguration: BassManagementConfiguration(),
                playbackConfiguration: PlaybackControlConfiguration()
            )
            XCTAssertTrue(mixedGraph.mixedPhaseEnabled)
            XCTAssertGreaterThan(mixedGraph.mixedPhaseCorrectionSectionCount, 0)
            XCTAssertLessThanOrEqual(mixedGraph.mixedPhaseCorrectionSectionCount, 12)
            XCTAssertEqual(mixedGraph.latencyFrames, minimumGraph.latencyFrames)
            XCTAssertGreaterThan(mixedGraph.eqBandCount, minimumGraph.eqBandCount)
            for index in Int(minimumGraph.eqBandCount)..<Int(mixedGraph.eqBandCount) {
                let section = withUnsafePointer(to: mixedGraph.eqBands) { tuple in
                    tuple.withMemoryRebound(to: N60BiquadBandSnapshot.self, capacity: Int(mixedGraph.eqBandCount)) { $0[index] }
                }
                XCTAssertEqual(section.type, N60BiquadFilterTypeAllPass)
                XCTAssertTrue(N60BiquadCoefficientsAreFinite(section.coefficients))
            }
        }
    }

    func testMixedPhaseRejectsExplicitUserAllPassButKeepsFIRSeparate() throws {
        let allPass = EQBand(type: .allPass, frequencyHz: 1_000, gainDB: 0, q: 1.0)
        let invalid = StereoEQConfiguration(phaseMode: .mixedPhase, linkedBands: [allPass])
        XCTAssertThrowsError(try invalid.makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )) { error in
            XCTAssertEqual(error as? EQConfigurationError, .allPassRequiresMinimumPhase)
        }

        let fir = EQBand(
            type: .fir,
            firKernel: EQFIRKernel(name: "User FIR", sampleRate: 48_000, taps: [0.25, 0.5, 0.25])
        )
        let mixedWithFIR = StereoEQConfiguration(
            phaseMode: .mixedPhase,
            linkedBands: [EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 3, q: 1.0), fir]
        )
        XCTAssertTrue(mixedWithFIR.requiresEQFIRProgram)
        let graph = try mixedWithFIR.makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertTrue(graph.mixedPhaseEnabled)
    }

    func testMixedPhaseUsesLaneSpecificCorrectionForIndependentAndMidSide() throws {
        let leftOrMid = [
            EQBand(type: .lowShelf, frequencyHz: 100, gainDB: 6, q: 0.707),
            EQBand(type: .peaking, frequencyHz: 900, gainDB: 7, q: 2.0),
        ]
        let rightOrSide = [
            EQBand(type: .highShelf, frequencyHz: 6_000, gainDB: -5, q: 0.707),
            EQBand(type: .peaking, frequencyHz: 2_500, gainDB: -6, q: 1.4),
        ]
        for configuration in [
            StereoEQConfiguration(
                channelMode: .independent, editChannel: .left, phaseMode: .mixedPhase,
                leftBands: leftOrMid, rightBands: rightOrSide, independentSeeded: true
            ),
            StereoEQConfiguration(
                channelMode: .midSide, editChannel: .mid, phaseMode: .mixedPhase,
                midBands: leftOrMid, sideBands: rightOrSide, midSideSeeded: true
            ),
        ] {
            let graph = try configuration.makeGraphSnapshot(
                sampleRate: 96_000,
                gainConfiguration: DSPGainConfiguration(),
                bassManagementConfiguration: BassManagementConfiguration(),
                playbackConfiguration: PlaybackControlConfiguration()
            )
            XCTAssertTrue(graph.mixedPhaseEnabled)
            XCTAssertGreaterThan(graph.mixedPhaseCorrectionSectionCount, 0)
            XCTAssertEqual(graph.latencyFrames, 0)
        }
    }

    func testMixedPhaseKeepsSharedDynamicEQActive() throws {
        var dynamic = EQBandDynamicConfiguration()
        dynamic.enabled = true
        let dynamicBand = EQBand(
            type: .peaking, frequencyHz: 1_500, gainDB: 2, q: 1.0, dynamic: dynamic
        )
        let configuration = StereoEQConfiguration(
            channelMode: .linked,
            phaseMode: .mixedPhase,
            linkedBands: [dynamicBand]
        )
        let graph = try configuration.makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertTrue(graph.dynamics.dynamicEQ.enabled)
        XCTAssertTrue(graph.mixedPhaseEnabled)
    }

'''
if "testMixedPhaseIsFixedThirdPhaseMode" not in tests:
    marker = "    func testBootstrapTestBundleRuns() {\n"
    if marker not in tests:
        raise SystemExit("Expected Mixed XCTest insertion point was not found")
    tests = tests.replace(marker, mixed_tests + marker, 1)
tests_path.write_text(tests)

print("PR34 Mixed Phase integration applied.")
