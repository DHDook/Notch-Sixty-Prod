import XCTest
@testable import NotchSixty

/// E28 S7d: the extras' rows, their ranges and defaults, the lookahead latency text, the availability reasons, and the
/// session-only listen and solo state. The rows draw from `DynamicsParameterSpec.extras`.
@MainActor
final class DynamicsExtrasS7dTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    func testEveryExtraRowSitsInsideItsConfigRangeAndTheEngineAcceptsItsBounds() {
        for spec in DynamicsParameterSpec.extras {
            XCTAssertTrue(spec.config.contains(spec.slider.lowerBound) && spec.config.contains(spec.slider.upperBound), spec.id)
            for value in [spec.config.lowerBound, spec.config.upperBound, spec.slider.lowerBound, spec.slider.upperBound] {
                var c = DynamicsConfiguration()
                spec.apply(value, to: &c)
                XCTAssertNoThrow(try c.compressor.validate(), spec.id)
                XCTAssertNoThrow(try c.expander.validate(), spec.id)
                XCTAssertNoThrow(try c.multibandCompressor.validate(), spec.id)
                XCTAssertTrue((try? c.makeSnapshot(sampleRate: 48_000)) != nil, "\(spec.id) at \(value)")
            }
            var c = DynamicsConfiguration()
            spec.apply(spec.config.upperBound + 1_000, to: &c)
            XCTAssertEqual(c[keyPath: spec.keyPath], spec.config.upperBound, "\(spec.id) clamps")
        }
    }

    func testDefaultsLeaveTheConfigurationUntouchedAndEncodeAsBefore() throws {
        var c = DynamicsConfiguration()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(c)
        for spec in DynamicsParameterSpec.extras where spec.id != "compressorLookaheadMs" && spec.id != "multibandLookaheadMs" {
            spec.apply(spec.defaultValue, to: &c)
        }
        XCTAssertEqual(c, DynamicsConfiguration(), "default values store as nil")
        XCTAssertEqual(try encoder.encode(c), before)
    }

    func testLookaheadToggleTurnsOnAtFiveMillisecondsAndOffToNil() {
        var comp = CompressorConfiguration()
        XCTAssertFalse(comp.lookaheadOn)
        comp.lookaheadOn = true
        XCTAssertEqual(comp.lookaheadMs, 5)
        comp.lookaheadTimeMs = 8
        comp.lookaheadOn = true
        XCTAssertEqual(comp.lookaheadMs, 8, "turning on again keeps the time")
        comp.lookaheadOn = false
        XCTAssertNil(comp.lookaheadMs)
        var mb = MultibandCompressorConfiguration()
        mb.lookaheadOn = true
        XCTAssertEqual(mb.lookaheadMs, 5)
        mb.lookaheadOn = false
        XCTAssertNil(mb.lookaheadMs)
    }

    func testBandSetsToggleAndEmptyBecomesNil() {
        var set = MultibandCompressorConfiguration.toggled(nil, band: 1, on: true)
        XCTAssertEqual(set, [1])
        set = MultibandCompressorConfiguration.toggled(set, band: 2, on: true)
        XCTAssertEqual(set, [1, 2])
        set = MultibandCompressorConfiguration.toggled(set, band: 1, on: false)
        set = MultibandCompressorConfiguration.toggled(set, band: 2, on: false)
        XCTAssertNil(set)
    }

    func testAddsTextEqualsFramesOverRateAtTheEightRates() {
        for rate in rates {
            for ms in [1.0, 5.0, 10.0] {
                let frames = CompressorConfiguration.lookaheadFrames(ms: ms, sampleRate: rate)
                let text = DynamicsExtrasAvailability.addsText(ms: ms, sampleRate: rate)
                XCTAssertTrue(text.contains(String(format: "%.2f", Double(frames) / rate * 1000)), "\(text) at \(rate)")
                XCTAssertTrue(text.contains("\(frames) frames"), text)
            }
        }
        XCTAssertTrue(DynamicsExtrasAvailability.addsText(ms: 5, sampleRate: nil).contains("about 5.0 ms"))
    }

    func testAvailabilityReasons() {
        let off = DynamicsExtrasAvailability(flagOn: false, kernelRenders: false, running: true)
        XCTAssertNil(off.extrasDisabledReason)
        XCTAssertFalse(off.bypassEnabled)
        let kernel = DynamicsExtrasAvailability(flagOn: true, kernelRenders: true, running: true)
        XCTAssertFalse(kernel.extrasEnabled)
        XCTAssertFalse(kernel.listenEnabled)
        XCTAssertEqual(kernel.extrasDisabledReason, DynamicsExtrasAvailability.kernelReason)
        XCTAssertEqual(kernel.listenDisabledReason, DynamicsExtrasAvailability.kernelReason)
        XCTAssertTrue(kernel.bypassEnabled, "multiband bypass is the one extra the kernel renders")
        let idle = DynamicsExtrasAvailability(flagOn: true, kernelRenders: false, running: false)
        XCTAssertTrue(idle.extrasEnabled)
        XCTAssertFalse(idle.listenEnabled)
        XCTAssertEqual(idle.listenDisabledReason, DynamicsExtrasAvailability.notRunningReason)
        let live = DynamicsExtrasAvailability(flagOn: true, kernelRenders: false, running: true)
        XCTAssertTrue(live.listenEnabled)
        XCTAssertNil(live.listenDisabledReason)
    }

    func testBannerNamesTheStageAndListenAndSoloAreNotEncoded() throws {
        let session = DynamicsListenSession()
        session.request(DynamicsListener(stage: .multibandMid, mode: .delta))
        session.setSolo([0])
        XCTAssertTrue(session.listener?.bannerText.contains("Multiband mid band") == true)
        let json = String(decoding: try JSONEncoder().encode(DynamicsConfiguration()), as: UTF8.self).lowercased()
        XCTAssertFalse(json.contains("listen"))
        XCTAssertFalse(json.contains("solo"))
        XCTAssertTrue(session.clear())
        XCTAssertNil(session.listener)
        XCTAssertTrue(session.soloBands.isEmpty)
    }

    func testBandLowAndHighCannotBeRefused() {
        for (low, high) in [(8_000.0, 100.0), (8_000.0, 3_500.0), (100.0, 100.0)] {
            var c = DynamicsConfiguration()
            c.dialogueRelativeLeveler.bandLowHz = 300
            c.dialogueRelativeLeveler.bandHighHz = high < 301 ? 3_500 : high
            DynamicsParameterSpec.dialogueRelativeLevelerBandLowHz.apply(low, to: &c)
            DynamicsParameterSpec.dialogueRelativeLevelerBandHighHz.apply(high, to: &c)
            XCTAssertLessThan(c.dialogueRelativeLeveler.bandLowHz, c.dialogueRelativeLeveler.bandHighHz)
            XCTAssertNoThrow(try c.makeSnapshot(sampleRate: 48_000), "\(low) \(high)")
        }
    }

    func testEngineWithNothingRenderingRefusesListenAndClearsQuietly() {
        let engine = AudioIOEngine()
        engine.clearDynamicsListening()
        XCTAssertNil(engine.dynamicsListener)
        XCTAssertTrue(engine.dynamicsSoloBands.isEmpty)
        XCTAssertNoThrow(try engine.setDynamicsListener(nil))
        XCTAssertNoThrow(try engine.setDynamicsSoloBands([]))
        if FeatureFlags().isEnabled(.dynamicsExtras) {
            XCTAssertThrowsError(try engine.setDynamicsListener(DynamicsListener(stage: .compressor, mode: .sidechain)))
        } else {
            XCTAssertThrowsError(try engine.setDynamicsListener(DynamicsListener(stage: .compressor, mode: .sidechain))) { error in
                XCTAssertEqual(error as? DynamicsExtrasError, .flagOff)
            }
        }
    }
}
