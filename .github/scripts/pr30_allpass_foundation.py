from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing anchor: {label}")
    return text.replace(old, new, 1)


# 1) Portable C biquad: add a standard second-order all-pass section.
p = Path("NotchSixty/Audio/Realtime/N60Biquad.h")
s = p.read_text()
s = replace_once(
    s,
    """    N60BiquadFilterTypeNotch = 5,\n} N60BiquadFilterType;""",
    """    N60BiquadFilterTypeNotch = 5,\n    N60BiquadFilterTypeAllPass = 6,\n} N60BiquadFilterType;""",
    "all-pass enum",
)
s = replace_once(
    s,
    """    case N60BiquadFilterTypeNotch:\n        b0 = 1.0;\n        b1 = -2.0 * cosOmega;\n        b2 = 1.0;\n        a0 = 1.0 + alpha;\n        a1 = -2.0 * cosOmega;\n        a2 = 1.0 - alpha;\n        break;\n    default:""",
    """    case N60BiquadFilterTypeNotch:\n        b0 = 1.0;\n        b1 = -2.0 * cosOmega;\n        b2 = 1.0;\n        a0 = 1.0 + alpha;\n        a1 = -2.0 * cosOmega;\n        a2 = 1.0 - alpha;\n        break;\n    case N60BiquadFilterTypeAllPass:\n        // RBJ-style second-order all-pass. Magnitude is unity; frequency and Q\n        // control the phase-rotation region. Coefficients are designed only on\n        // the control plane and consumed as immutable snapshots in realtime.\n        b0 = 1.0 - alpha;\n        b1 = -2.0 * cosOmega;\n        b2 = 1.0 + alpha;\n        a0 = 1.0 + alpha;\n        a1 = -2.0 * cosOmega;\n        a2 = 1.0 - alpha;\n        break;\n    default:""",
    "all-pass design",
)
p.write_text(s)


# 2) Swift product/control-plane filter inventory and explicit phase-mode rule.
p = Path("NotchSixty/Audio/AudioIOEngine.swift")
s = p.read_text()
s = replace_once(
    s,
    """    case highPass\n    case notch\n\n    var id:""",
    """    case highPass\n    case notch\n    case allPass\n\n    var id:""",
    "Swift all-pass enum",
)
s = replace_once(
    s,
    """        case .highPass: return \"High Pass\"\n        case .notch: return \"Notch\"\n        }""",
    """        case .highPass: return \"High Pass\"\n        case .notch: return \"Notch\"\n        case .allPass: return \"All-Pass\"\n        }""",
    "all-pass display name",
)
s = replace_once(
    s,
    """        case .highPass: return N60BiquadFilterTypeHighPass\n        case .notch: return N60BiquadFilterTypeNotch\n        }""",
    """        case .highPass: return N60BiquadFilterTypeHighPass\n        case .notch: return N60BiquadFilterTypeNotch\n        case .allPass: return N60BiquadFilterTypeAllPass\n        }""",
    "all-pass C mapping",
)
s = replace_once(
    s,
    """    case invalidBand(index: Int)\n    case linearPhaseDesignFailed""",
    """    case invalidBand(index: Int)\n    case allPassRequiresMinimumPhase\n    case linearPhaseDesignFailed""",
    "all-pass configuration error",
)
s = replace_once(
    s,
    """        case .invalidBand(let index):\n            return \"EQ band \\(index + 1) is invalid for the current output sample rate.\"\n        case .linearPhaseDesignFailed:""",
    """        case .invalidBand(let index):\n            return \"EQ band \\(index + 1) is invalid for the current output sample rate.\"\n        case .allPassRequiresMinimumPhase:\n            return \"All-Pass bands are phase-only IIR filters and require Minimum phase EQ mode.\"\n        case .linearPhaseDesignFailed:""",
    "all-pass error description",
)
# Legacy single-list control path: fail clearly instead of handing an all-pass to the FIR magnitude designer.
s = replace_once(
    s,
    """        for (index, band) in bands.enumerated() where band.enabled {\n            guard try validateBand(band, index: index, sampleRate: sampleRate) else { continue }\n            var cBand = N60LinearPhaseEQBand()""",
    """        for (index, band) in bands.enumerated() where band.enabled {\n            guard try validateBand(band, index: index, sampleRate: sampleRate) else { continue }\n            guard band.type != .allPass else {\n                throw EQConfigurationError.allPassRequiresMinimumPhase\n            }\n            var cBand = N60LinearPhaseEQBand()""",
    "legacy linear phase all-pass guard",
)
p.write_text(s)


# Stereo control path has its own linear-phase band projection.
p = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
s = p.read_text()
s = replace_once(
    s,
    """        let bands = try validatedEnabledBands(source, sampleRate: sampleRate)\n        return bands.map { band in\n            var cBand = N60LinearPhaseEQBand()""",
    """        let bands = try validatedEnabledBands(source, sampleRate: sampleRate)\n        guard !bands.contains(where: { $0.type == .allPass }) else {\n            throw EQConfigurationError.allPassRequiresMinimumPhase\n        }\n        return bands.map { band in\n            var cBand = N60LinearPhaseEQBand()""",
    "stereo linear phase all-pass guard",
)
p.write_text(s)


# 3) Deterministic regression coverage.
p = Path("NotchSixtyTests/NotchSixtyTests.swift")
s = p.read_text()
anchor = """    func testParametricEQRejectsInvalidBandDesigns() {\n"""
test = r'''    func testAllPassMaintainsUnityMagnitudeAcrossSupportedRates() {
        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            for tone in [100.0, 1_000.0, min(10_000.0, rate * 0.20)] {
                let gain = measuredEQGainDB(
                    sampleRate: rate,
                    toneFrequency: tone,
                    filterType: N60BiquadFilterTypeAllPass,
                    filterFrequency: min(2_000.0, rate * 0.10),
                    gainDB: 0,
                    q: 0.707
                )
                XCTAssertEqual(gain, 0.0, accuracy: 0.08, "All-pass magnitude drift at \(rate) Hz / \(tone) Hz")
            }
        }
    }

    func testAllPassIsRejectedByLinearPhaseProjection() {
        let configuration = EQConfiguration(
            phaseMode: .linearPhase,
            bands: [EQBand(type: .allPass, frequencyHz: 1_000, gainDB: 0, q: 0.707)]
        )
        XCTAssertThrowsError(try configuration.linearPhaseBands(sampleRate: 48_000)) { error in
            XCTAssertEqual(error as? EQConfigurationError, .allPassRequiresMinimumPhase)
        }
    }

'''
s = replace_once(s, anchor, test + anchor, "all-pass tests")
p.write_text(s)


# 4) Documentation/provenance. This section intentionally documents independent derivation.
p = Path("docs/PARAMETRIC_EQ.md")
s = p.read_text()
if "## PR30 All-Pass extension" not in s:
    s += """

## PR30 All-Pass extension

The minimum-phase EQ engine also supports a second-order **All-Pass** band. Frequency and Q control the phase-rotation region while magnitude remains at unity. All-Pass is intentionally unavailable in Linear phase mode because the current FIR EQ designer is a magnitude-response equaliser; silently discarding a phase-only request would be misleading.

The coefficient design uses the standard public-domain/RBJ second-order digital all-pass form and is prepared on the control plane. The realtime callback consumes only precomputed coefficients and fixed filter state.
"""
p.write_text(s)

p = Path("docs/PROVENANCE.md")
s = p.read_text()
if "## PR30 — Phase & Time Alignment Foundation" not in s:
    s += """

## PR30 — Phase & Time Alignment Foundation

- **Classification:** specification-derived / original commercial implementation.
- **Behavioral references:** legacy user-facing inventory establishes that All-Pass is an EQ filter type used for phase alignment/group-delay correction and that inter-channel timing alignment is a supported product need. Legacy DSP implementation source and tests are not implementation references.
- **Implementation sources:** standard second-order digital all-pass equations from public DSP literature plus the proprietary `N60Biquad`/render-graph architecture.
- **All-Pass contract:** unity magnitude, phase rotation controlled by frequency and Q, minimum-phase/IIR mode only.
- **Realtime contract:** coefficient design remains off the render callback; fixed-size state only; no allocation, locks, logging, file/device I/O, or coefficient construction in realtime.
- **Follow-on in this PR:** independently designed signed fractional inter-channel delay with click-safe transitions. Excess-phase room correction remains deferred to the measurement/room-correction milestone because it requires phase-resolved measurements.
"""
p.write_text(s)

print("PR30 all-pass foundation applied")
