import Foundation
import XCTest
@testable import NotchSixty

/// E33 S2: the Equalizer APO codec, page import, clipboard, lane copy and handle accessibility actions.
@MainActor
final class EQImportExportTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private let everyType: [EQBand] = [
        EQBand(type: .peaking, frequencyHz: 1_234.5678, gainDB: -6.2345, q: 2.4321),
        EQBand(type: .lowShelf, frequencyHz: 85.25, gainDB: 4.5, q: 0.71, slope: .db18),
        EQBand(type: .highShelf, frequencyHz: 9_500, gainDB: -3.125, q: 0.9, slope: .db6),
        EQBand(type: .lowPass, frequencyHz: 14_000, q: 0.5, slope: .db24),
        EQBand(type: .highPass, frequencyHz: 32.5, q: 0.8, slope: .db12),
        EQBand(type: .bandPass, frequencyHz: 2_000, q: 3.3),
        EQBand(type: .notch, frequencyHz: 60, q: 8),
        EQBand(type: .allPass, frequencyHz: 700, q: 1.7),
        EQBand(enabled: false, type: .peaking, frequencyHz: 500, gainDB: 2, q: 1),
    ]

    private func sameBands(_ a: [EQBand], _ b: [EQBand], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.type, y.type, file: file, line: line)
            XCTAssertEqual(x.enabled, y.enabled, file: file, line: line)
            XCTAssertEqual(x.slope, y.slope, file: file, line: line)
            XCTAssertEqual(x.frequencyHz, y.frequencyHz, accuracy: 1e-4, file: file, line: line)
            XCTAssertEqual(x.gainDB, y.gainDB, accuracy: 1e-4, file: file, line: line)
            XCTAssertEqual(x.q, y.q, accuracy: 1e-5, file: file, line: line)
        }
    }

    func testRoundTripOfEveryTypeKeepsBandsAndResponseAtTheEightRates() {
        let written = EqualizerAPOCodec.write(bands: everyType, preampDB: -4.5)
        XCTAssertTrue(written.issues.isEmpty)
        let parsed = EqualizerAPOCodec.parse(written.text)
        XCTAssertEqual(parsed.preampDB ?? .nan, -4.5, accuracy: 1e-9)
        XCTAssertTrue(parsed.issues.isEmpty, "\(parsed.issues)")
        sameBands(parsed.bands, everyType)
        for rate in Self.rates {
            let a = ProductionEQResponseMath.compile(bands: everyType, sampleRate: rate)
            let b = ProductionEQResponseMath.compile(bands: parsed.bands, sampleRate: rate)
            for f in stride(from: 20.0, through: min(20_000, rate * 0.45), by: 97.0) {
                let da = ProductionEQResponseMath.responseDB(program: a, sampleRate: rate, frequencyHz: f)
                let db = ProductionEQResponseMath.responseDB(program: b, sampleRate: rate, frequencyHz: f)
                XCTAssertEqual(da, db, accuracy: 0.01, "rate \(rate) f \(f)")
            }
        }
    }

    func testUnwritableTypesAreReportedNotWritten() {
        let bands = [EQBand(type: .tilt), EQBand(type: .linkwitzTransform), EQBand(type: .peaking, gainDB: 1)]
        let written = EqualizerAPOCodec.write(bands: bands)
        XCTAssertEqual(written.issues.count, 2)
        XCTAssertEqual(EqualizerAPOCodec.parse(written.text).bands.count, 1)
    }

    func testAutoEQFileImportsWithStatedIssues() {
        let text = """
        Preamp: -6.4 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.2 dB Q 0.70
        Filter 2: ON PK Fc 2500 Hz Gain -3.1 dB Q 1.41
        Filter 3: ON HSC Fc 10000 Hz Gain 2.3 dB Q 0.70
        Filter 4: ON None
        Filter 5: OFF PK Fc 60 Hz Gain 1 dB Q 2
        GraphicEQ: 20 -2; 100 0
        Filter 6: ON XX Fc 1000 Hz
        """
        let parsed = EqualizerAPOCodec.parse(text)
        XCTAssertEqual(parsed.preampDB, -6.4)
        XCTAssertEqual(parsed.bands.map(\.type), [.lowShelf, .peaking, .highShelf, .peaking])
        XCTAssertFalse(parsed.bands[3].enabled)
        XCTAssertEqual(parsed.bands[0].q, 0.70, accuracy: 1e-9)
        XCTAssertEqual(parsed.issues.count, 2, "\(parsed.issues)")
        XCTAssertTrue(parsed.issues[0].contains("line 7"))
        XCTAssertTrue(parsed.issues[1].contains("line 8"))
    }

    func testREWFileWithBandwidthSlopeAndCommasImports() {
        let text = """
        # REW
        Filter  1: ON  PK       Fc     50,5 Hz  Gain  -4,2 dB  Q  4,36
        Filter  2: ON  LS 12 dB Fc    120 Hz   Gain   3 dB
        Filter  3: ON  HP       Fc     20 Hz
        Filter  4: ON  NO       Fc    100 Hz    Q 5
        Filter  5: ON  PK       Fc    300 Hz  Gain 2 dB  BW Oct 1
        """
        let parsed = EqualizerAPOCodec.parse(text)
        XCTAssertTrue(parsed.issues.isEmpty, "\(parsed.issues)")
        XCTAssertEqual(parsed.bands.map(\.type), [.peaking, .lowShelf, .highPass, .notch, .peaking])
        XCTAssertEqual(parsed.bands[0].frequencyHz, 50.5, accuracy: 1e-9)
        XCTAssertEqual(parsed.bands[0].gainDB, -4.2, accuracy: 1e-9)
        XCTAssertEqual(parsed.bands[1].slope, .db12)
        XCTAssertEqual(parsed.bands[4].q, 1.4142, accuracy: 1e-3)
    }

    // MARK: Page import

    private func config(_ bands: [EQBand]) -> StereoEQConfiguration { StereoEQConfiguration(linkedBands: bands) }

    func testImportReplacesOrAppendsInTheEditedLane() throws {
        let parsed = EqualizerAPOCodec.parse("Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1\nFilter 2: ON PK Fc 2000 Hz Gain -3 dB Q 1")
        var stereo = StereoEQConfiguration(channelMode: .independent, editChannel: .right,
                                           leftBands: [EQBand(frequencyHz: 100)], rightBands: [EQBand(frequencyHz: 200)])
        stereo.independentSeeded = true
        let replaced = try EQBandTransfer.importing(parsed, into: stereo, mode: .replace)
        XCTAssertEqual(replaced.configuration.rightBands.count, 2)
        XCTAssertEqual(replaced.configuration.leftBands, stereo.leftBands)
        let appended = try EQBandTransfer.importing(parsed, into: stereo, mode: .append)
        XCTAssertEqual(appended.configuration.rightBands.count, 3)
        XCTAssertEqual(appended.configuration.rightBands.first, stereo.rightBands.first)
    }

    func testImportClampsAndReportsAndRefusesTooMany() throws {
        let clamped = try EQBandTransfer.importing(
            EqualizerAPOCodec.parse("Filter 1: ON PK Fc 1000 Hz Gain 40 dB Q 1"), into: config([]), mode: .replace)
        XCTAssertEqual(clamped.configuration.linkedBands[0].gainDB, StereoEQConfiguration.bandGainRange.upperBound)
        XCTAssertEqual(clamped.notes.count, 1)

        let full = config((0 ..< EQConfiguration.maximumBandCount).map { EQBand(frequencyHz: 100 + Double($0)) })
        XCTAssertThrowsError(try EQBandTransfer.importing(
            EqualizerAPOCodec.parse("Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1"), into: full, mode: .append))
        XCTAssertThrowsError(try EQBandTransfer.importing(EqualizerAPOCodec.parse("nothing"), into: full, mode: .replace))
    }

    // MARK: Clipboard and lanes

    func testClipboardRoundTripsExactlyAndTextFallbackPastes() throws {
        let encoded = try XCTUnwrap(EQBandClipboard.encode(everyType))
        XCTAssertEqual(EQBandClipboard.decode(data: encoded.data, text: nil), everyType)
        sameBands(EQBandClipboard.decode(data: nil, text: encoded.text), everyType)
        XCTAssertTrue(EQBandClipboard.decode(data: nil, text: "hello").isEmpty)
    }

    func testPasteAppendsWithFreshIDsIntoEachLaneAndMode() throws {
        let source = [EQBand(frequencyHz: 300, gainDB: 2, q: 1)]
        let modes: [(StereoEQConfiguration, EQLane)] = [
            (StereoEQConfiguration(channelMode: .linked), .linked),
            (StereoEQConfiguration(channelMode: .independent, editChannel: .left), .left),
            (StereoEQConfiguration(channelMode: .independent, editChannel: .right), .right),
            (StereoEQConfiguration(channelMode: .midSide, editChannel: .mid), .mid),
            (StereoEQConfiguration(channelMode: .midSide, editChannel: .side), .side),
        ]
        for (stereo, lane) in modes {
            XCTAssertEqual(stereo.editLane, lane)
            let outcome = try EQBandTransfer.pasting(source, into: stereo)
            let pasted = outcome.configuration.bands(in: lane)
            XCTAssertEqual(pasted.count, 1)
            XCTAssertNotEqual(pasted[0].id, source[0].id)
            XCTAssertEqual(pasted[0].frequencyHz, 300)
            for other in EQLane.allCases where other != lane {
                XCTAssertTrue(outcome.configuration.bands(in: other).isEmpty)
            }
        }
        XCTAssertThrowsError(try EQBandTransfer.pasting([], into: config([])))
    }

    func testCopyLaneReplacesTargetAndMarksSeeded() {
        var stereo = StereoEQConfiguration(channelMode: .independent, editChannel: .left,
                                           leftBands: [EQBand(frequencyHz: 100), EQBand(frequencyHz: 200)],
                                           rightBands: [EQBand(frequencyHz: 999)])
        XCTAssertEqual(EQBandTransfer.copyTargets(for: stereo), [.right, .linked])
        let result = EQBandTransfer.copyLane(.left, to: .right, in: stereo)
        XCTAssertEqual(result.rightBands.map(\.frequencyHz), [100, 200])
        XCTAssertNotEqual(result.rightBands[0].id, result.leftBands[0].id)
        stereo = StereoEQConfiguration(channelMode: .linked, linkedBands: [EQBand(frequencyHz: 50)])
        XCTAssertEqual(EQBandTransfer.copyTargets(for: stereo), [.left, .right, .mid, .side])
        let toMid = EQBandTransfer.copyLane(.linked, to: .mid, in: stereo)
        XCTAssertTrue(toMid.midSideSeeded)
        XCTAssertEqual(toMid.midBands.map(\.frequencyHz), [50])
        XCTAssertEqual(EQBandTransfer.copyLane(.linked, to: .linked, in: stereo), stereo)
    }

    func testImportPasteAndLaneCopyAreEachOneUndoStep() throws {
        var state = StereoEQConfiguration(channelMode: .linked, linkedBands: [EQBand(frequencyHz: 100)])
        let undo = UndoManager()
        undo.groupsByEvent = false
        let history = EQEditHistory(undoManager: undo, live: { state }, apply: { state = $0 })
        let original = state
        func edit(_ new: StereoEQConfiguration) {
            let before = state
            state = new
            history.record(before: before, after: state)
        }
        edit(try EQBandTransfer.importing(
            EqualizerAPOCodec.parse("Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1\nFilter 2: ON PK Fc 2000 Hz Gain 3 dB Q 1"),
            into: state, mode: .append).configuration)
        XCTAssertEqual(state.linkedBands.count, 3)
        XCTAssertEqual(history.undoStepCount, 1)
        edit(try EQBandTransfer.pasting([EQBand(frequencyHz: 5_000)], into: state).configuration)
        XCTAssertEqual(history.undoStepCount, 2)
        undo.undo()
        XCTAssertEqual(state.linkedBands.count, 3)
        undo.undo()
        XCTAssertEqual(state, original)
    }

    // MARK: Handle accessibility

    func testHandleActionsMoveFrequencyAndGainByTheNudgeRules() {
        let band = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 2, q: 1)
        let maximum = EQBandRules.maximumFrequency(sampleRate: 96_000)
        let up = EQHandleAccessibility.frequency(band, direction: .up, maximumFrequency: maximum)
        XCTAssertEqual(up.frequencyHz, EQNudge.frequency(1_000, direction: .up, step: .normal,
            range: EQValueParser.range(for: .frequency, band: band, maximumFrequency: maximum)), accuracy: 1e-9)
        XCTAssertGreaterThan(up.frequencyHz, 1_000)
        let down = EQHandleAccessibility.frequency(band, direction: .down, maximumFrequency: maximum)
        XCTAssertLessThan(down.frequencyHz, 1_000)
        XCTAssertEqual(EQHandleAccessibility.gain(band, action: .up, maximumFrequency: maximum).gainDB,
                       2 + EQNudge.gainStep(.normal), accuracy: 1e-9)
        XCTAssertEqual(EQHandleAccessibility.gain(band, action: .coarseDown, maximumFrequency: maximum).gainDB,
                       2 - EQNudge.gainStep(.coarse), accuracy: 1e-9)
        // No gain on a pass filter, and clamped at the range end.
        let pass = EQBand(type: .highPass, frequencyHz: 80)
        XCTAssertEqual(EQHandleAccessibility.gain(pass, action: .up, maximumFrequency: maximum), pass)
        let top = EQBand(type: .peaking, frequencyHz: maximum, gainDB: 24)
        XCTAssertLessThanOrEqual(EQHandleAccessibility.frequency(top, direction: .up, maximumFrequency: maximum).frequencyHz, maximum)
        XCTAssertEqual(EQHandleAccessibility.gain(top, action: .up, maximumFrequency: maximum).gainDB, 24)
        XCTAssertFalse(EQHandleAccessibility.valueText(band).isEmpty)
    }

    func testGestureHintShowsUntilMarkedShown() {
        let suite = UserDefaults(suiteName: "EQImportExportTests.\(UUID().uuidString)")!
        XCTAssertTrue(EQHandleAccessibility.shouldShowHint(defaults: suite))
        EQHandleAccessibility.markHintShown(defaults: suite)
        XCTAssertFalse(EQHandleAccessibility.shouldShowHint(defaults: suite))
    }
}
