import XCTest
@testable import NotchSixty

/// E11 S6: REW text, FRD, ZMA and WAV import and export.
final class MeasurementFormatsTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func curve() -> MeasurementCurve {
        let f = (0..<300).map { 20 * pow(1000.0, Double($0) / 299) }
        return MeasurementCurve(
            frequenciesHz: f, values: f.map { 80 + 6 * sin($0 / 200) }, phaseDegrees: f.map { 180 * sin($0 / 900) })
    }

    func testRoundTripAllTextFormats() throws {
        for format in MeasurementTextFormat.allCases {
            let original = curve()
            let text = MeasurementFormats.write(original, format: format)
            let back = try MeasurementFormats.parse(text, format: format)
            XCTAssertTrue(back.issues.isEmpty)
            XCTAssertEqual(back.frequenciesHz.count, original.frequenciesHz.count)
            for i in original.frequenciesHz.indices {
                XCTAssertEqual(back.frequenciesHz[i], original.frequenciesHz[i], accuracy: original.frequenciesHz[i] * 1e-8)
                XCTAssertEqual(back.values[i], original.values[i], accuracy: 0.001)
                XCTAssertEqual(back.phaseDegrees![i], original.phaseDegrees![i], accuracy: 0.01)
            }
        }
    }

    func testRewHeaderCommaAndTabFiles() throws {
        let rew = "* Measurement data saved by REW\n* Freq(Hz)\tSPL(dB)\tPhase(degrees)\n20.0\t70.5\t-10\n40.0\t71.25\t-20\n"
        let a = try MeasurementFormats.parse(rew, format: .rew)
        XCTAssertEqual(a.values, [70.5, 71.25])
        XCTAssertEqual(a.comments.count, 2)
        let comma = "20,70.5,-10\r\n40,71.25,-20\r\n"
        let b = try MeasurementFormats.parse(comma, format: .frd)
        XCTAssertEqual(b.frequenciesHz, [20, 40])
        XCTAssertEqual(b.phaseDegrees, [-10, -20])
        let spaces = "20   70.5\n40   71.25\n"
        XCTAssertNil(try MeasurementFormats.parse(spaces, format: .frd).phaseDegrees)
    }

    func testMalformedLinesReportedWithLineNumbers() throws {
        let text = "* c\n20 70\nabc def\n30\n25 71\n50 72 xyz\n60 73\n"
        let parsed = try MeasurementFormats.parse(text, format: .rew)
        XCTAssertEqual(parsed.frequenciesHz, [20, 25, 50, 60])
        XCTAssertEqual(parsed.issues.map(\.line), [3, 4, 6])
        XCTAssertTrue(parsed.issues[0].description.hasPrefix("Line 3:"))
    }

    func testNoDataAndSizeLimit() {
        XCTAssertThrowsError(try MeasurementFormats.parse("* only a comment\nbad\n", format: .rew)) {
            guard case MeasurementFormatError.noData(let issues) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(issues.first?.line, 2)
        }
        let big = Data(repeating: UInt8(ascii: "1"), count: MeasurementFormats.textLimitBytes + 1)
        XCTAssertThrowsError(try MeasurementFormats.parse(big, format: .rew))
    }

    func testZmaImpedanceConversion() throws {
        let parsed = try MeasurementFormats.parse("100 8.0 10\n200 4.0 -5\n", format: .zma)
        let response = parsed.response(format: .zma)
        XCTAssertEqual(response.magnitudeDB[0], 20 * log10(8.0), accuracy: 1e-9)
        XCTAssertEqual(response.phaseRadians![1], -5 * .pi / 180, accuracy: 1e-12)
        let back = MeasurementFormats.curve(from: response, format: .zma)
        XCTAssertEqual(back.values[1], 4.0, accuracy: 1e-9)
    }

    func testWavImpulseAtAllRates() throws {
        for rate in Self.rates {
            let ir: [Float] = (0..<512).map { $0 == 10 ? 1 : Float(sin(Double($0) * 0.1)) * 0.01 }
            let wav = MeasurementFormats.encodeWAV(ir, sampleRate: rate)
            let back = try MeasurementFormats.decodeWAV(wav, name: "ir")
            XCTAssertEqual(back.sampleRate, rate)
            XCTAssertEqual(back.samples, ir)
        }
    }

    func testPCMWavDecoding() throws {
        func wav(bits: Int, channels: Int, body: [UInt8]) -> Data {
            var d = Data("RIFF".utf8)
            func u32(_ v: Int) { d.append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 255) }) }
            func u16(_ v: Int) { d.append(contentsOf: (0..<2).map { UInt8((v >> (8 * $0)) & 255) }) }
            u32(36 + body.count); d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
            u16(1); u16(channels); u32(48_000); u32(48_000 * bits / 8 * channels); u16(bits / 8 * channels); u16(bits)
            d.append(contentsOf: Array("data".utf8)); u32(body.count); d.append(contentsOf: body)
            return d
        }
        let s16 = try MeasurementFormats.decodeWAV(wav(bits: 16, channels: 1, body: [0x00, 0x40, 0x00, 0xC0]), name: "a")
        XCTAssertEqual(s16.samples, [0.5, -0.5])
        let s24 = try MeasurementFormats.decodeWAV(wav(bits: 24, channels: 2, body: [0, 0, 0x40, 1, 2, 3, 0, 0, 0xC0, 4, 5, 6]), name: "b")
        XCTAssertEqual(s24.samples, [0.5, -0.5])
        XCTAssertThrowsError(try MeasurementFormats.decodeWAV(Data("junk".utf8), name: "c"))
    }

    func testLibraryImportExportAndSweepWav() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("n60fmt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MeasurementLibrary(root: root)
        let text = MeasurementFormats.write(curve(), format: .rew)
        let imported = try library.importCurve(Data(text.utf8), format: .rew, name: "REW curve")
        XCTAssertFalse(imported.record.hasImpulseResponse)
        XCTAssertNotNil(imported.record.response)
        let exported = try library.exportCurve(id: imported.record.id, format: .frd)
        XCTAssertEqual(try MeasurementFormats.parse(exported, format: .frd).values.count, 300)
        XCTAssertThrowsError(try library.exportImpulseWAV(id: imported.record.id))

        let ir = (0..<64).map { Float($0) / 64 }
        let wavRecord = try library.importImpulseWAV(MeasurementFormats.encodeWAV(ir, sampleRate: 96_000), name: "ir")
        XCTAssertEqual(wavRecord.sampleRate, 96_000)
        let out = try MeasurementFormats.decodeWAV(try library.exportImpulseWAV(id: wavRecord.id), name: "x")
        XCTAssertEqual(out.samples, ir)

        for rate in Self.rates {
            let data = try MeasurementFormats.sweepWAV(
                sampleRate: rate, startFrequencyHz: 20, endFrequencyHz: min(20_000, rate * 0.45), durationSeconds: 0.5,
                levelDBFS: -12, fadeSeconds: 0.02, synchronised: true)
            let sweep = try MeasurementFormats.decodeWAV(data, name: "sweep")
            XCTAssertEqual(sweep.sampleRate, rate)
            XCTAssertGreaterThan(sweep.samples.count, Int(rate * 0.25))
            XCTAssertLessThanOrEqual(sweep.samples.map { abs($0) }.max()!, 0.26)
        }
    }
}
