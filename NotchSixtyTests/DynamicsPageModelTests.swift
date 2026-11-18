import XCTest
@testable import NotchSixty

/// E33 S4: chain numbers, the dynamic EQ link row, navigator accessibility, empty-telemetry reasons, the relative-grab
/// slider with 30 Hz commits, and field limits shown on sliders.
final class DynamicsPageModelTests: XCTestCase {
    func testGroupNumbersFollowGroupsAndLayoutIsUnchanged() {
        let groups = ProductionDynamicsLayout.groups
        XCTAssertEqual(groups.count, 6)
        for (index, group) in groups.enumerated() {
            XCTAssertEqual(ProductionDynamicsLayout.numberedTitle(of: group), "\(index + 1) \(group.title)")
        }
        XCTAssertEqual(ProductionDynamicsLayout.numberedTitle(of: groups[0]), "1 Input & Clean-up")
        XCTAssertEqual(ProductionDynamicsLayout.numberedTitle(of: groups[5]), "6 Output")
        // A reordered list renumbers itself.
        let reordered = Array(groups.reversed())
        XCTAssertEqual(ProductionDynamicsLayout.numberedTitle(of: groups[5], in: reordered), "1 Output")
        // No processor moved: every module appears once, in the documented order.
        XCTAssertEqual(groups.flatMap(\.modules).count, Set(groups.flatMap(\.modules)).count)
        XCTAssertEqual(groups.map(\.id), ["input", "stereo", "level", "tone", "dynamics", "output"])
    }

    func testEQLinkRowSitsBeforeTheFirstGroupAfterEQ() {
        XCTAssertEqual(ProductionDynamicsLayout.eqRowIndex(), 1)
        XCTAssertEqual(ProductionDynamicsLayout.eqRowIndex(in: []), 0)
    }

    func testDynamicEQRowListsOnlyActiveBands() {
        var peaking = EQBand(type: .peaking, frequencyHz: 2_000)
        peaking.dynamic.enabled = true
        var low = EQBand(type: .peaking, frequencyHz: 250)
        low.dynamic.enabled = true
        let staticBand = EQBand(type: .peaking, frequencyHz: 500)
        var off = EQBand(enabled: false, type: .peaking, frequencyHz: 4_000)
        off.dynamic.enabled = true
        let entries = DynamicsEQLink.activeBands([peaking, staticBand, off, low])
        XCTAssertEqual(entries.map(\.id), [low.id, peaking.id])
        XCTAssertEqual(entries.map(\.title), ["Band 1: 250 Hz", "Band 3: 2 kHz"])
        XCTAssertEqual(DynamicsEQLink.summary(count: 0), "Dynamic EQ: no bands on")
        XCTAssertEqual(DynamicsEQLink.summary(count: 1), "Dynamic EQ: 1 band on")
        XCTAssertEqual(DynamicsEQLink.summary(count: 2), "Dynamic EQ: 2 bands on")
    }

    @MainActor
    func testBandFocusRequestIsTakenOnce() {
        let id = UUID()
        EQBandFocusRequest.shared.request(id)
        XCTAssertEqual(EQBandFocusRequest.shared.take(), id)
        XCTAssertNil(EQBandFocusRequest.shared.take())
    }

    func testNavigatorRowAccessibility() {
        XCTAssertEqual(DynamicsNavigatorAccessibility.value(isOn: true), "On")
        XCTAssertEqual(DynamicsNavigatorAccessibility.value(isOn: false), "Off")
        for module in ProductionDynamicsModule.allCases {
            let label = DynamicsNavigatorAccessibility.label(title: module.title, subtitle: module.subtitle)
            XCTAssertTrue(label.hasPrefix(module.title))
            XCTAssertFalse(module.subtitle.isEmpty)
        }
        var d = DynamicsConfiguration()
        d.compressor.enabled = true
        d.expander.enabled = false
        XCTAssertTrue(ProductionDynamicsModule.compressor.isActive(in: d))
        XCTAssertFalse(ProductionDynamicsModule.expander.isActive(in: d))
        XCTAssertEqual(ProductionDynamicsTelemetryKind.dialogue.module, .dialogueLeveler)
    }

    func testEmptyTelemetrySaysWhy() {
        XCTAssertTrue(DynamicsTelemetryEmptyReason.text(isRunning: false, processorTitle: "Compressor", processorOn: true).contains("stopped"))
        XCTAssertTrue(DynamicsTelemetryEmptyReason.text(isRunning: false, processorTitle: "Compressor", processorOn: false).contains("stopped"))
        XCTAssertTrue(DynamicsTelemetryEmptyReason.text(isRunning: true, processorTitle: "Compressor", processorOn: false).contains("Compressor is off"))
        XCTAssertTrue(DynamicsTelemetryEmptyReason.text(isRunning: true, processorTitle: "Compressor", processorOn: true).contains("first frames"))
    }

    // MARK: Slider

    func testClickWithoutDragCommitsNothing() {
        var drag = DynamicsSliderDrag(startPosition: 0.4, startX: 100, trackWidth: 216)
        XCTAssertNil(drag.update(x: 100, fine: false, time: 0))
        XCTAssertNil(drag.finish())
        XCTAssertEqual(drag.position, 0.4)
    }

    func testRelativeGrabMovesByDistanceFromGrab() {
        var drag = DynamicsSliderDrag(startPosition: 0.5, startX: 10, trackWidth: 216)  // travel 200
        XCTAssertEqual(try XCTUnwrap(drag.update(x: 50, fine: false, time: 0)), 0.7, accuracy: 1e-9)
        var fine = DynamicsSliderDrag(startPosition: 0.5, startX: 10, trackWidth: 216)
        XCTAssertEqual(try XCTUnwrap(fine.update(x: 50, fine: true, time: 0)), 0.52, accuracy: 1e-9)
        var pinned = DynamicsSliderDrag(startPosition: 0.9, startX: 0, trackWidth: 216)
        XCTAssertEqual(try XCTUnwrap(pinned.update(x: 500, fine: false, time: 0)), 1.0)
    }

    func testScriptedDragCommitsAtMost30PerSecondAndEndsWithFinalCommit() {
        var drag = DynamicsSliderDrag(startPosition: 0, startX: 0, trackWidth: 1_016)
        var commits: [(time: Double, position: Double)] = []
        // 120 Hz of drag events for one second.
        for step in 1...120 {
            let time = Double(step) / 120
            if let p = drag.update(x: Double(step) * 5, fine: false, time: time) { commits.append((time, p)) }
        }
        XCTAssertLessThanOrEqual(commits.count, 31)
        XCTAssertGreaterThanOrEqual(commits.count, 25)
        for pair in zip(commits, commits.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.time - pair.0.time, DynamicsSliderDrag.minimumInterval - 1e-9)
        }
        // The last event was throttled, so release sends the final position.
        let final = drag.finish()
        XCTAssertEqual(final ?? commits.last!.position, drag.position, accuracy: 1e-12)
        if commits.last!.position != drag.position { XCTAssertNotNil(final) } else { XCTAssertNil(final) }
    }

    // MARK: Ranges

    func testFieldLimitShownOnlyWhenFieldIsWiderThanSlider() {
        XCTAssertEqual(DynamicsParameterSpec.compressorRatio.fieldLimitNote.map { $0.hasPrefix("field: 1.0–") && $0.hasSuffix(":1") }, true)
        let wider = DynamicsParameterSpec.all.filter { $0.config.lowerBound < $0.slider.lowerBound || $0.config.upperBound > $0.slider.upperBound }
        XCTAssertFalse(wider.isEmpty)
        for spec in DynamicsParameterSpec.all {
            let isWider = spec.config.lowerBound < spec.slider.lowerBound || spec.config.upperBound > spec.slider.upperBound
            XCTAssertEqual(spec.fieldLimitNote != nil, isWider, spec.id)
        }
    }

    func testOneSpellingOfLookahead() {
        for spec in DynamicsParameterSpec.all {
            XCTAssertFalse(spec.title.lowercased().contains("look-ahead"), spec.id)
        }
    }
}
