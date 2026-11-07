import Foundation
import XCTest
@testable import NotchSixty

final class EQValueParserTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    func testFrequencyForms() {
        let cases: [(String, Double)] = [
            ("2k", 2_000), ("2kHz", 2_000), ("2 kHz", 2_000), ("250hz", 250), ("250 Hz", 250),
            ("1.5 kHz", 1_500), ("1.5k", 1_500), ("440", 440), ("  1000  ", 1_000), ("20Hz", 20),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(EQValueParser.parseFrequency(text, locale: us) ?? .nan, expected, accuracy: 1e-9, text)
        }
    }

    func testCommaLocaleForms() {
        XCTAssertEqual(EQValueParser.parseFrequency("1,5k", locale: de), 1_500)
        XCTAssertEqual(EQValueParser.parseFrequency("1,5 kHz", locale: de), 1_500)
        XCTAssertEqual(EQValueParser.parseFrequency("1.5k", locale: de), 1_500)
        XCTAssertEqual(EQValueParser.parseGain("-3,5 dB", locale: de), -3.5)
        // The comma is a decimal separator in en_US too when it cannot be grouping.
        XCTAssertEqual(EQValueParser.parseFrequency("1,5k", locale: us), 1_500)
        // A grouping separator followed by three digits is grouping.
        XCTAssertEqual(EQValueParser.parseFrequency("1,500", locale: us), 1_500)
        XCTAssertEqual(EQValueParser.parseFrequency("1,500", locale: de), 1.5)
        XCTAssertEqual(EQValueParser.parseFrequency("1.500", locale: de), 1_500)
        XCTAssertEqual(EQValueParser.parseFrequency("1.234,5", locale: de), 1_234.5)
        XCTAssertEqual(EQValueParser.parseFrequency("1,234.5", locale: us), 1_234.5)
    }

    func testGainForms() {
        let cases: [(String, Double)] = [
            ("+3", 3), ("-3", -3), ("-3 dB", -3), ("3db", 3), ("3 DB", 3), ("0", 0), ("-0.5dB", -0.5),
            ("\u{2212}2", -2), ("+12.25", 12.25),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(EQValueParser.parseGain(text, locale: us) ?? .nan, expected, accuracy: 1e-9, text)
        }
    }

    func testQForms() throws {
        XCTAssertEqual(try XCTUnwrap(EQValueParser.parseQ("0.707", locale: us)), 0.707, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(EQValueParser.parseQ("4", locale: us)), 4, accuracy: 1e-9)
        // One octave: Q = sqrt(2) / (2 - 1).
        XCTAssertEqual(try XCTUnwrap(EQValueParser.parseQ("1 oct", locale: us)), 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(EQValueParser.parseQ("1oct", locale: us)), 2.0.squareRoot(), accuracy: 1e-9)
        // Two octaves: Q = 2 / 3.
        XCTAssertEqual(try XCTUnwrap(EQValueParser.parseQ("2 octaves", locale: us)), 2.0 / 3.0, accuracy: 1e-9)
        // A third of an octave: Q = 2^(1/6) / (2^(1/3) - 1) = 4.318...
        XCTAssertEqual(try XCTUnwrap(EQValueParser.parseQ("0.3333333333 oct", locale: us)), 4.3185, accuracy: 1e-3)
    }

    func testRejection() {
        for text in ["", " ", "abc", "k", "hz", "1 2", "1kk", "2 dB", "--3", "1..5", "1,2,3", "1e3", "3 oct", ".", "NaN", "inf"] {
            XCTAssertNil(EQValueParser.parseFrequency(text, locale: us), "frequency \(text)")
        }
        XCTAssertNil(EQValueParser.parseFrequency("-100", locale: us))
        XCTAssertNil(EQValueParser.parseFrequency("0", locale: us))
        XCTAssertNil(EQValueParser.parseGain("3 Hz", locale: us))
        XCTAssertNil(EQValueParser.parseGain("3k", locale: us))
        XCTAssertNil(EQValueParser.parseGain("loud", locale: us))
        XCTAssertNil(EQValueParser.parseQ("0", locale: us))
        XCTAssertNil(EQValueParser.parseQ("-1", locale: us))
        XCTAssertNil(EQValueParser.parseQ("0 oct", locale: us))
        XCTAssertNil(EQValueParser.parseQ("-1 oct", locale: us))
        XCTAssertNil(EQValueParser.parseQ("1 dB", locale: us))
    }

    func testPerTypeClamping() {
        let peak = EQBand(type: .peaking)
        var dynamic = EQBand(type: .peaking)
        dynamic.dynamic.enabled = true
        let maximum = 48_000 * 0.49

        func value(_ text: String, _ field: EQValueParser.Field, _ band: EQBand) -> Double? {
            EQValueParser.value(from: text, field: field, band: band, maximumFrequency: maximum, locale: us)
        }

        XCTAssertEqual(value("5", .frequency, peak), 20)
        XCTAssertEqual(value("30k", .frequency, peak), maximum)
        XCTAssertEqual(value("5", .frequency, dynamic), 20)
        XCTAssertEqual(value("30k", .frequency, dynamic), min(20_000, maximum))
        XCTAssertEqual(value("99", .gain, peak), 24)
        XCTAssertEqual(value("-99 dB", .gain, peak), -24)
        XCTAssertEqual(value("0.01", .q, peak), 0.1)
        XCTAssertEqual(value("100", .q, peak), 20)
        XCTAssertEqual(value("0.1", .q, dynamic), DynamicEQBandConfiguration.qRange.lowerBound)
        XCTAssertEqual(value("100", .q, dynamic), DynamicEQBandConfiguration.qRange.upperBound)
        XCTAssertEqual(value("0.5", .linkwitzTargetFrequency, peak), 1)
        XCTAssertEqual(value("junk", .gain, peak), nil)
    }

    func testClampingFollowsTheSampleRate() {
        let band = EQBand(type: .peaking)
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let ceiling = rate * 0.49
            let typed = EQValueParser.value(from: "400k", field: .frequency, band: band, maximumFrequency: ceiling, locale: us)
            XCTAssertEqual(typed, ceiling, "rate \(rate)")
        }
    }

    func testDisplayTextParsesBack() throws {
        for locale in [us, de] {
            for (value, field) in [(1_059.4, EQValueParser.Field.frequency), (-3.5, .gain), (0.707, .q), (12_345.6, .frequency)] {
                let text = EQValueParser.displayText(value, field: field, locale: locale)
                let back = try XCTUnwrap(EQValueParser.parse(text, field: field, locale: locale), "\(text) in \(locale.identifier)")
                XCTAssertEqual(back, value, accuracy: 0.0006, "\(text) in \(locale.identifier)")
            }
        }
        XCTAssertEqual(EQValueParser.displayText(-3.5, field: .gain, locale: de), "-3,5")
        XCTAssertEqual(EQValueParser.displayText(1_000, field: .frequency, locale: us), "1000")
    }
}
