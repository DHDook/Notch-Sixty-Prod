from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)

engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()

old_validation = '''    func validate(for outputSampleRate: Double) throws {
        guard !taps.isEmpty, taps.count <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw EQConfigurationError.invalidFIRTapCount(taps.count)
        }
        guard taps.allSatisfy(\.isFinite) else {
            throw EQConfigurationError.nonFiniteFIRTap
        }
        if let sampleRate {
            guard sampleRate.isFinite, sampleRate > 0, abs(sampleRate - outputSampleRate) < 0.5 else {
                throw EQConfigurationError.firSampleRateMismatch(filter: sampleRate, output: outputSampleRate)
            }
        }
    }
'''
new_validation = '''    func validateMetadata() throws {
        guard !taps.isEmpty, taps.count <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw EQConfigurationError.invalidFIRTapCount(taps.count)
        }
        guard taps.allSatisfy(\.isFinite) else {
            throw EQConfigurationError.nonFiniteFIRTap
        }
        if let sampleRate {
            guard sampleRate.isFinite, sampleRate > 0 else {
                throw EQConfigurationError.firSampleRateMismatch(filter: sampleRate, output: 0)
            }
        }
    }

    func validate(for outputSampleRate: Double) throws {
        try validateMetadata()
        if let sampleRate {
            guard outputSampleRate.isFinite,
                  outputSampleRate > 0,
                  abs(sampleRate - outputSampleRate) < 0.5 else {
                throw EQConfigurationError.firSampleRateMismatch(filter: sampleRate, output: outputSampleRate)
            }
        }
    }
'''
engine = replace_once(engine, old_validation, new_validation, "FIR metadata validation split")

old_storage = '''                if band.type == .fir {
                    guard let kernel = band.firKernel else { throw EQConfigurationError.firKernelRequired }
                    try kernel.validate(for: transportSession?.outputFormat.sampleRate ?? 48_000)
                    continue
                }
'''
new_storage = '''                if band.type == .fir {
                    guard let kernel = band.firKernel else { throw EQConfigurationError.firKernelRequired }
                    try kernel.validateMetadata()
                    if let activeSampleRate = transportSession?.outputFormat.sampleRate {
                        try kernel.validate(for: activeSampleRate)
                    }
                    continue
                }
'''
engine = replace_once(engine, old_storage, new_storage, "pre-transport FIR storage validation")
engine_path.write_text(engine)

tests_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = tests_path.read_text()
test = r'''    func testFIRMetadataCanBeStoredBeforeTransportWithoutAssuming48k() throws {
        let kernel96k = EQFIRKernel(name: "96k FIR", sampleRate: 96_000, taps: [1])
        try kernel96k.validateMetadata()
        XCTAssertNoThrow(try kernel96k.validate(for: 96_000))
        XCTAssertThrowsError(try kernel96k.validate(for: 48_000))

        let untied = EQFIRKernel(name: "Untied FIR", taps: [1])
        try untied.validateMetadata()
        XCTAssertNoThrow(try untied.validate(for: 48_000))
        XCTAssertNoThrow(try untied.validate(for: 384_000))
    }

'''
if "testFIRMetadataCanBeStoredBeforeTransportWithoutAssuming48k" not in tests:
    marker = "    func testPerBandFIRKernelValidationAndCascade() throws {\n"
    if marker not in tests:
        raise SystemExit("Expected FIR validation regression insertion point was not found")
    tests = tests.replace(marker, test + marker, 1)
tests_path.write_text(tests)

print("PR34 FIR pre-transport validation cleanup applied.")
