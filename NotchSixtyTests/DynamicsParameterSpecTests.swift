import Foundation
import XCTest
@testable import NotchSixty

@MainActor
final class DynamicsParameterSpecTests: XCTestCase {
    private var specs: [DynamicsParameterSpec] {
        DynamicsParameterSpec.all + (0..<DynamicsConfiguration().mainsNotch.harmonicDepthsDB.count).map { DynamicsParameterSpec.harmonicDepth($0) }
    }

    private func validates(_ c: DynamicsConfiguration) -> Bool {
        (try? c.makeSnapshot(sampleRate: 48_000)) != nil
    }

    /// Ordered pairs: the partner is parked at its far end so the pair stays valid at the other's bound.
    private func prepared(_ spec: DynamicsParameterSpec, _ c: inout DynamicsConfiguration, atLower: Bool) {
        switch spec.id {
        case "spectralDenoiserProtectedLowHz": c.spectralDenoiser.protectedHighHz = spec.config.upperBound
        case "dialogueRelativeLevelerBandLowHz": c.dialogueRelativeLeveler.bandHighHz = 8_000
        case "dialogueRelativeLevelerBandHighHz": c.dialogueRelativeLeveler.bandLowHz = 100
        default: break
        }
    }

    func testSpecIDsAreUnique() {
        XCTAssertEqual(Set(specs.map(\.id)).count, specs.count)
    }

    func testSliderRangeInsideConfigRangeAndDefaultInsideBoth() {
        for spec in specs {
            XCTAssertTrue(spec.config.contains(spec.slider.lowerBound) && spec.config.contains(spec.slider.upperBound), spec.id)
            XCTAssertTrue(spec.config.contains(spec.defaultValue), "\(spec.id) default")
        }
    }

    func testEveryConfigBoundIsAcceptedByTheEngine() {
        for spec in specs {
            for bound in [spec.config.lowerBound, spec.config.upperBound] {
                var c = DynamicsConfiguration()
                prepared(spec, &c, atLower: bound == spec.config.lowerBound)
                spec.apply(bound, to: &c)
                XCTAssertTrue(validates(c), "\(spec.id) at \(bound)")
            }
        }
    }

    func testEverySliderBoundIsAcceptedByTheEngine() {
        for spec in specs {
            for bound in [spec.slider.lowerBound, spec.slider.upperBound] {
                var c = DynamicsConfiguration()
                prepared(spec, &c, atLower: bound == spec.slider.lowerBound)
                spec.apply(bound, to: &c)
                XCTAssertTrue(validates(c), "\(spec.id) slider at \(bound)")
            }
        }
    }

    func testApplyClampsToConfigRange() {
        for spec in specs where spec.coupling == .none {
            var c = DynamicsConfiguration()
            spec.apply(spec.config.upperBound + 1_000, to: &c)
            XCTAssertEqual(c[keyPath: spec.keyPath], spec.config.upperBound, spec.id)
            spec.apply(spec.config.lowerBound - 1_000, to: &c)
            XCTAssertEqual(c[keyPath: spec.keyPath], spec.config.lowerBound, spec.id)
        }
    }

    func testMultibandSidechainRangeMatchesEveryBand() {
        for band in 0..<3 {
            let sc = DynamicsParameterSpec.multibandBand(band).last!
            XCTAssertEqual(sc.slider, 0...300, "band \(band)")
            var c = DynamicsConfiguration()
            sc.apply(300, to: &c)
            XCTAssertEqual(c[keyPath: sc.keyPath], 300)
            XCTAssertTrue(validates(c))
        }
    }

    func testRejectionMessageNamesStageAndField() {
        let spec = DynamicsParameterSpec.compressorRatio
        let message = spec.rejectionMessage(value: 120, reason: "out of range")
        XCTAssertTrue(message.contains("Compressor"))
        XCTAssertTrue(message.contains("Ratio"))
        XCTAssertTrue(message.contains("out of range"))
    }

    func testParserPerUnit() {
        XCTAssertEqual(ValueParser.parse("1.5k", unit: .hertz, locale: Locale(identifier: "en_US")) ?? 0, 1_500, accuracy: 1e-9)
        XCTAssertEqual(ValueParser.parse("-18 dB", unit: .decibels, locale: Locale(identifier: "en_US")) ?? 0, -18, accuracy: 1e-9)
        XCTAssertEqual(ValueParser.parse("0.25 s", unit: .milliseconds, locale: Locale(identifier: "en_US")) ?? 0, 250, accuracy: 1e-9)
        XCTAssertEqual(ValueParser.parse("4:1", unit: .ratio, locale: Locale(identifier: "en_US")) ?? 0, 4, accuracy: 1e-9)
        XCTAssertNil(ValueParser.parse("abc", unit: .decibels, locale: Locale(identifier: "en_US")))
        let spec = DynamicsParameterSpec.compressorRatio
        XCTAssertEqual(spec.parse("500", locale: Locale(identifier: "en_US")), spec.config.upperBound)
    }

    func testNudgePerKind() {
        typealias N = ValueNudge
        XCTAssertEqual(N.nudged(-20, kind: .decibels, direction: .up, step: .normal, range: -80...0, floor: 1), -19.5, accuracy: 1e-9)
        XCTAssertEqual(N.nudged(-20, kind: .decibels, direction: .down, step: .coarse, range: -80...0, floor: 1), -23, accuracy: 1e-9)
        XCTAssertEqual(N.nudged(-20, kind: .decibels, direction: .up, step: .fine, range: -80...0, floor: 1), -19.9, accuracy: 1e-9)
        XCTAssertEqual(N.nudged(100, kind: .multiplicativeTime, direction: .up, step: .normal, range: 1...1000, floor: 1), 100 * pow(2, 1.0 / 12), accuracy: 1e-6)
        XCTAssertEqual(N.nudged(4, kind: .ratio, direction: .up, step: .normal, range: 1...100, floor: 1), 4.4, accuracy: 1e-9)
        XCTAssertEqual(N.nudged(0.5, kind: .linear(step: 0.01), direction: .up, step: .coarse, range: 0...1, floor: 0), 0.55, accuracy: 1e-9)
        XCTAssertEqual(N.nudged(0.99, kind: .linear(step: 0.01), direction: .up, step: .coarse, range: 0...1, floor: 0), 1, accuracy: 1e-9)
    }

    func testNudgeFromOffAndBackToOff() {
        let k = ParameterStepKind.multiplicativeTime
        XCTAssertEqual(ValueNudge.nudged(0, kind: k, direction: .up, step: .normal, range: 0...300, floor: 10), 10)
        XCTAssertEqual(ValueNudge.nudged(10, kind: k, direction: .down, step: .normal, range: 0...300, floor: 10), 0)
        XCTAssertEqual(ValueNudge.nudged(0, kind: k, direction: .down, step: .normal, range: 0...300, floor: 10), 0)
    }

    func testLogScaleRoundTrips() {
        for spec in specs {
            for p in stride(from: 0.1, through: 0.9, by: 0.2) {
                let v = spec.value(atPosition: p)
                XCTAssertTrue(spec.slider.contains(v) || abs(v - spec.slider.lowerBound) < 1e-9, spec.id)
                XCTAssertEqual(spec.position(of: v), p, accuracy: 1e-6, "\(spec.id) at \(p)")
            }
            XCTAssertEqual(spec.position(of: spec.slider.upperBound + 1_000), 1, accuracy: 1e-12)
        }
    }

    func testLogScaleOffStop() {
        let spec = DynamicsParameterSpec.compressorSidechainHighPassHz
        XCTAssertEqual(spec.value(atPosition: 0), 0)
        XCTAssertEqual(spec.position(of: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(spec.position(of: spec.logFloor), ParameterScale.offStop, accuracy: 1e-12)
    }

    func testRejectedApplyKeepsTheLiveValueAndNamesTheField() {
        let engine = AudioIOEngine()
        let spec = DynamicsParameterSpec.compressorRatio
        var tooHigh = engine.dynamicsConfiguration
        tooHigh.compressor.ratio = spec.config.upperBound + 50
        XCTAssertThrowsError(try engine.replaceDynamicsConfiguration(tooHigh)) { error in
            let message = spec.rejectionMessage(value: tooHigh.compressor.ratio, reason: error.localizedDescription)
            XCTAssertTrue(message.contains("Compressor") && message.contains("Ratio"))
        }
        XCTAssertEqual(engine.dynamicsConfiguration[keyPath: spec.keyPath], DynamicsConfiguration()[keyPath: spec.keyPath])
    }

    // MARK: Auto makeup

    func testAutoMakeupAnalytic() {
        // Hard knee, threshold -24, ratio 4: gain at -18 dBFS is -(6 * 0.75) = -4.5, so makeup is 4.5.
        XCTAssertEqual(AutoMakeup.makeupDB(thresholdDB: -24, ratio: 4, kneeDB: 0, range: -24...24), 4.5, accuracy: 1e-9)
        // Below threshold: no reduction, no makeup.
        XCTAssertEqual(AutoMakeup.makeupDB(thresholdDB: -10, ratio: 4, kneeDB: 0, range: -24...24), 0, accuracy: 1e-9)
        // Soft knee, threshold -18, knee 6, ratio 2: gain = -0.5 * 3^2 / 12 = -0.375, makeup 0.4 after 0.1 rounding.
        XCTAssertEqual(AutoMakeup.makeupDB(thresholdDB: -18, ratio: 2, kneeDB: 6, range: -24...24), 0.4, accuracy: 1e-9)
        // Clamped to the range.
        XCTAssertEqual(AutoMakeup.makeupDB(thresholdDB: -60, ratio: 20, kneeDB: 0, range: -24...24), 24, accuracy: 1e-9)
    }

    func testAutoMakeupFollowsEditsAndOffKeepsValue() {
        var c = DynamicsConfiguration()
        c.compressor.autoMakeupGain = true
        DynamicsParameterSpec.compressorThresholdDB.apply(-24, to: &c)
        DynamicsParameterSpec.compressorRatio.apply(4, to: &c)
        DynamicsParameterSpec.compressorKneeWidthDB.apply(0, to: &c)
        XCTAssertEqual(c.compressor.makeupGainDB, 4.5, accuracy: 1e-9)
        c.compressor.autoMakeupGain = false
        DynamicsParameterSpec.compressorRatio.apply(2, to: &c)
        XCTAssertEqual(c.compressor.makeupGainDB, 4.5, accuracy: 1e-9)
    }

    func testAutoMakeupBands() {
        var c = DynamicsConfiguration()
        c.multibandCompressor.autoMakeupBands = [1]
        let rows = DynamicsParameterSpec.multibandBand(1)
        rows[0].apply(-24, to: &c)
        rows[1].apply(4, to: &c)
        rows[4].apply(0, to: &c)
        XCTAssertEqual(c.multibandCompressor.midMakeupGainDB, 4.5, accuracy: 1e-9)
        XCTAssertEqual(c.multibandCompressor.lowMakeupGainDB, DynamicsConfiguration().multibandCompressor.lowMakeupGainDB)
    }

    func testOldStoredConfigurationDecodesWithoutAutoMakeup() throws {
        let data = try JSONEncoder().encode(DynamicsConfiguration())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var comp = try XCTUnwrap(object["compressor"] as? [String: Any])
        comp.removeValue(forKey: "autoMakeupGain")
        object["compressor"] = comp
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DynamicsConfiguration.self, from: old)
        XCTAssertNil(decoded.compressor.autoMakeupGain)
    }

    // MARK: Coupling

    func testVoiceSensitivityKeepsFloorBelowCeiling() {
        var c = DynamicsConfiguration()
        DynamicsParameterSpec.dialogueRelativeLevelerVoiceGateSensitivity.apply(0.5, to: &c)
        let gate = c.dialogueRelativeLeveler.voiceGate
        XCTAssertEqual(gate.confidenceCeilingIndex, 0.5, accuracy: 1e-9)
        XCTAssertEqual(gate.confidenceFloorIndex, 0.2, accuracy: 1e-9)
        XCTAssertTrue(validates(c))
    }
}

@MainActor
final class DynamicsEditHistoryTests: XCTestCase {
    @MainActor private final class Harness {
        var state = DynamicsConfiguration()
        let undoManager = UndoManager()
        let history = EditHistory<DynamicsConfiguration>()
        var clock = Date(timeIntervalSince1970: 1_000)
        init() {
            undoManager.groupsByEvent = false
            history.now = { [unowned self] in self.clock }
            history.configure(undoManager: undoManager, live: { [unowned self] in self.state }, apply: { [unowned self] in self.state = $0 })
        }
        func edit(_ name: String = "Edit", key: String? = nil, _ change: (inout DynamicsConfiguration) -> Void) {
            let before = state
            change(&state)
            history.record(before: before, after: state, name: name, coalesceKey: key)
        }
    }

    func testUndoRedoPerStage() {
        let stages: [(String, (inout DynamicsConfiguration) -> Void)] = [
            ("compressor", { $0.compressor.ratio = 6 }),
            ("multiband", { $0.multibandCompressor.lowRatio = 5 }),
            ("expander", { $0.expander.ratio = 2 }),
            ("limiter", { $0.limiter.enabled.toggle() }),
            ("denoiser", { $0.spectralDenoiser.reductionAmount = 0.3 }),
        ]
        for (name, change) in stages {
            let h = Harness()
            let before = h.state
            h.edit { change(&$0) }
            let after = h.state
            XCTAssertNotEqual(before, after, name)
            h.undoManager.undo()
            XCTAssertEqual(h.state, before, name)
            h.undoManager.redo()
            XCTAssertEqual(h.state, after, name)
        }
    }

    func testSameFieldEditsCoalesceAndLaterOnesDoNot() {
        let h = Harness()
        h.edit(key: "r") { $0.compressor.ratio = 3 }
        h.clock += 0.2
        h.edit(key: "r") { $0.compressor.ratio = 4 }
        XCTAssertEqual(h.history.undoCount, 1)
        h.clock += 2
        h.edit(key: "r") { $0.compressor.ratio = 5 }
        XCTAssertEqual(h.history.undoCount, 2)
        h.undoManager.undo()
        XCTAssertEqual(h.state.compressor.ratio, 4)
    }

    func testDragGestureIsOneStep() {
        let h = Harness()
        let original = h.state
        h.history.beginGesture(before: h.state, name: "Drag")
        for v in [2.0, 3.0, 4.0, 5.0] { h.state.compressor.ratio = v }
        h.history.endGesture(after: h.state)
        XCTAssertEqual(h.history.undoCount, 1)
        h.undoManager.undo()
        XCTAssertEqual(h.state, original)
    }

    func testOutsideChangeClearsHistory() {
        let h = Harness()
        h.edit { $0.compressor.ratio = 3 }
        h.state.compressor.ratio = 9
        h.history.observeLiveChange()
        XCTAssertEqual(h.history.undoCount, 0)
        XCTAssertEqual(h.history.redoCount, 0)
    }
}
