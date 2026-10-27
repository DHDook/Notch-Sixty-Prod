import XCTest
@testable import NotchSixty

/// E8 S6: the routing editor's view model: templates, edit-to-config mapping, plotted response and messages.
@MainActor
final class SpeakerRoutingEditorTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func ep(_ i: UInt32) -> PhysicalOutputEndpoint { PhysicalOutputEndpoint(deviceUID: "dev", channelIndex: i) }

    private func model(rate: Double = 48_000, subs: Int = 0) -> SpeakerRoutingEditorModel {
        SpeakerRoutingEditorModel(context: SpeakerRoutingContext(programLanes: 2, subwoofers: subs, sampleRate: rate))
    }

    private func twoWay(_ m: SpeakerRoutingEditorModel, hz: Double = 2_000) {
        XCTAssertTrue(m.applyTemplate(
            .twoWay,
            mains: [.init(lane: 0, name: "Left", endpoints: [ep(0), ep(1)]),
                    .init(lane: 1, name: "Right", endpoints: [ep(2), ep(3)])],
            crossoverHz: [hz]))
    }

    func testTemplateCreationMatchesModelTemplateAndCommits() {
        let m = model()
        var committed: [SpeakerRoutingConfiguration] = []
        m.onCommit = { committed.append($0) }
        twoWay(m)
        XCTAssertEqual(m.configuration.speakers.count, 2)
        XCTAssertEqual(m.configuration.wayCount, 4)
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.last, m.configuration)
        XCTAssertTrue(m.validation.isValid)
        // A mismatch (one corner for a 3-way) is refused and changes nothing.
        XCTAssertFalse(m.applyTemplate(.threeWay, mains: [.init(lane: 0, name: "L", endpoints: [ep(0), ep(1), ep(2)])],
                                       crossoverHz: [500]))
        XCTAssertEqual(committed.count, 1)
    }

    func testTemplateDetectionAndDeviceApply() {
        let m = model(subs: 1)
        XCTAssertNil(m.currentTemplate)
        for template in SpeakerRoutingTemplate.allCases {
            XCTAssertTrue(m.applyTemplate(template, deviceUID: "dev"))
            XCTAssertEqual(m.currentTemplate, template)
            XCTAssertEqual(m.configuration.wayCount, 2 * template.waysPerMain + 1)
            XCTAssertTrue(m.validation.isValid)
            // Outputs run in channel order with no reuse.
            let channels = m.configuration.outputEndpoints.map(\.channelIndex)
            XCTAssertEqual(channels, Array(0..<UInt32(channels.count)))
        }
        // Edits that keep the shape keep the template; a raw matrix entry makes it custom.
        m.setEnabled(true)
        XCTAssertEqual(m.currentTemplate, .threeWay)
        m.replace({ var c = m.configuration; c.matrix.append(RoutingMatrixEntry(source: .program(0), output: ep(20))); return c }())
        XCTAssertNil(m.currentTemplate)
        // Legacy-only state (no routing speakers) stays settable elsewhere and reads as custom here.
        XCTAssertNil(SpeakerRoutingTemplate.detect(SpeakerRoutingConfiguration(enabled: false)))
    }

    func testEditsMapToConfiguration() throws {
        let m = model()
        twoWay(m)
        let speaker = m.configuration.speakers[0]
        let low = speaker.ways[0], high = speaker.ways[1]
        m.setFilter(.init(family: .butterworth, order: 3, cornerHz: 1_500), edge: .lowPass, way: low.id, speaker: speaker.id)
        m.editWay(high.id, speaker: speaker.id) { $0.trimDB = -3; $0.polarityInverted = true; $0.delayMilliseconds = 0.2 }
        m.addEQ(.init(type: 0, frequencyHz: 800, gainDB: -2, q: 1.5), way: high.id, speaker: speaker.id)
        let edited = m.configuration.speakers[0]
        XCTAssertEqual(edited.ways[0].lowPass, .init(family: .butterworth, order: 3, cornerHz: 1_500))
        XCTAssertEqual(edited.ways[1].trimDB, -3)
        XCTAssertTrue(edited.ways[1].polarityInverted)
        XCTAssertEqual(edited.ways[1].delayMilliseconds, 0.2)
        XCTAssertEqual(edited.ways[1].eq.count, 1)
        m.removeEQ(at: 0, way: high.id, speaker: speaker.id)
        XCTAssertTrue(m.configuration.speakers[0].ways[1].eq.isEmpty)
        // Order snaps to one the family offers (Linkwitz-Riley has 2, 4, 6, 8).
        m.setFilter(.init(family: .linkwitzRiley, order: 5, cornerHz: 1_500), edge: .highPass, way: high.id, speaker: speaker.id)
        XCTAssertTrue([4, 6].contains(m.configuration.speakers[0].ways[1].highPass?.order ?? 0))
        m.setFilter(nil, edge: .highPass, way: high.id, speaker: speaker.id)
        XCTAssertNil(m.configuration.speakers[0].ways[1].highPass)
    }

    func testWayLimitsAndMinimum() {
        let m = model()
        m.addSpeaker(name: "L", source: .program(0), endpoint: ep(0))
        let id = m.configuration.speakers[0].id
        for i in 1..<RoutedSpeaker.maxWays { XCTAssertTrue(m.addWay(speaker: id, endpoint: ep(UInt32(i)))) }
        XCTAssertFalse(m.addWay(speaker: id, endpoint: ep(20)))
        XCTAssertEqual(m.configuration.speakers[0].ways.count, 8)
        m.removeSpeaker(id)
        m.addSpeaker(name: "R", source: .program(1), endpoint: ep(0))
        let only = m.configuration.speakers[0]
        XCTAssertFalse(m.removeWay(only.ways[0].id, speaker: only.id))
    }

    func testPlottedResponseEqualsCorePrediction() throws {
        for rate in Self.rates {
            let m = model(rate: rate)
            twoWay(m, hz: 2_000)
            let speaker = m.configuration.speakers[0]
            let lp = try CrossoverCore.design(speaker.ways[0].lowPass!, highPass: false, sampleRate: rate)
            let hp = try CrossoverCore.design(speaker.ways[1].highPass!, highPass: true, sampleRate: rate)
            for hz in m.plotFrequencies(points: 12) {
                XCTAssertEqual(try XCTUnwrap(m.wayMagnitudeDB(speaker.ways[0], atHz: hz)),
                               try lp.magnitudeDB(atHz: hz), accuracy: 1e-9)
                XCTAssertEqual(try XCTUnwrap(m.wayMagnitudeDB(speaker.ways[1], atHz: hz)),
                               try hp.magnitudeDB(atHz: hz), accuracy: 1e-9)
            }
            // LR4 sums flat (all-pass) with no inversion: ripple under 0.1 dB across the plotted band.
            let sums = m.plotFrequencies(points: 40).compactMap { m.summedMagnitudeDB(speaker, atHz: $0) }
            XCTAssertEqual(sums.count, 40)
            XCTAssertLessThan((sums.max() ?? 0) - (sums.min() ?? 0), 0.1, "rate \(rate)")
        }
    }

    func testPolarityAndTrimShapeTheSum() throws {
        let m = model()
        twoWay(m)
        var speaker = m.configuration.speakers[0]
        let flat = try XCTUnwrap(m.summedMagnitudeDB(speaker, atHz: 2_000))
        m.editWay(speaker.ways[1].id, speaker: speaker.id) { $0.polarityInverted = true }
        speaker = m.configuration.speakers[0]
        let notch = try XCTUnwrap(m.summedMagnitudeDB(speaker, atHz: 2_000))
        XCTAssertLessThan(notch, flat - 20)
        m.editWay(speaker.ways[1].id, speaker: speaker.id) { $0.polarityInverted = false; $0.trimDB = -6 }
        let lowered = try XCTUnwrap(m.wayMagnitudeDB(m.configuration.speakers[0].ways[1], atHz: 10_000))
        XCTAssertEqual(lowered, -6, accuracy: 0.2)
    }

    func testValidationMessages() {
        let m = model()
        XCTAssertEqual(m.messages, ["Add at least one speaker."])
        twoWay(m)
        XCTAssertTrue(m.messages.isEmpty)
        let speaker = m.configuration.speakers[0]
        // Two ways on one output, a gap between the corners, and a trim out of range.
        m.editWay(speaker.ways[1].id, speaker: speaker.id) { $0.endpoint = speaker.ways[0].endpoint; $0.trimDB = 40 }
        m.setFilter(.init(family: .linkwitzRiley, order: 4, cornerHz: 4_000), edge: .highPass,
                    way: speaker.ways[1].id, speaker: speaker.id)
        let text = m.messages.joined(separator: "\n")
        XCTAssertTrue(text.contains("used by more than one way"), text)
        XCTAssertTrue(text.contains("trim must be between"), text)
        XCTAssertTrue(text.contains("nothing covers 2000 to 4000 Hz"), text)
    }

    func testMatrixGridAndRawEntries() {
        let m = model(subs: 1)
        twoWay(m)
        XCTAssertEqual(m.matrixSources, [.program(0), .program(1), .sub(0)])
        m.setMatrixGain(source: .program(1), output: ep(0), gain: 0.5)
        XCTAssertEqual(m.configuration.matrix.count, 1)
        let cells = m.matrixCells
        XCTAssertEqual(cells.count, 3)
        XCTAssertEqual(cells[0].count, 4)
        XCTAssertTrue(cells[0][0].fedByWay)
        XCTAssertFalse(cells[0][2].fedByWay)
        XCTAssertEqual(cells[1][0].rawGain, 0.5)
        m.setMatrixGain(source: .program(1), output: ep(0), gain: 0.25)
        XCTAssertEqual(m.configuration.matrix.count, 1)
        m.removeMatrixEntry(source: .program(1), output: ep(0))
        XCTAssertTrue(m.configuration.matrix.isEmpty)
        // The unrouted sub warns.
        XCTAssertTrue(m.messages.contains("Subwoofer 1 feeds nothing."))
    }
}
