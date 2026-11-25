import SwiftUI
import XCTest
@testable import NotchSixty

/// E13 S12 (`e13.headphones-page`): per-card bypass, the headphone side of the remote's before/after button, the saved
/// target shaping and Auto headroom (G26), and the page's final layout check (G28).
@MainActor
final class HeadphoneCompareTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let flags = FeatureFlags()

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    private func profile(spatial: HeadphoneSpatialMode = .stereo, boost: Double = 4) -> HeadphoneDeviceProfileConfiguration {
        var p = HeadphoneDeviceProfileConfiguration()
        p.enabled = true
        p.outputDeviceUID = "dac"
        p.headroomAttenuationDB = 6
        for ear in [\HeadphoneDeviceProfileConfiguration.left, \HeadphoneDeviceProfileConfiguration.right] {
            p[keyPath: ear].eqBands = [
                HeadphoneCorrectionEQBand(enabled: true, type: .peaking, frequencyHz: 1_000, gainDB: boost, q: 1),
                HeadphoneCorrectionEQBand(enabled: true, type: .peaking, frequencyHz: 3_000, gainDB: -2, q: 1)]
        }
        p.crossfeed.applyPreset(.standard)
        if spatial == .virtualSpeakers {
            p.spatialMode = .virtualSpeakers
            p.binauralProfile = GenericHRTF.reference
        }
        return p
    }

    // MARK: Bypass transform

    func testBypassKeepsSectionCountsAndNeverTouchesTheSavedProfile() throws {
        let saved = profile(spatial: .virtualSpeakers)
        let copy = saved
        let off = HeadphoneBypassSet.all.applied(to: saved)
        XCTAssertEqual(saved, copy, "a transform returns a new value")
        XCTAssertEqual(off.left.eqBands.count, saved.left.eqBands.count, "live edit: section count unchanged")
        XCTAssertTrue(off.left.eqBands.allSatisfy { !$0.enabled })
        XCTAssertEqual(off.crossfeed.preset, .off)
        XCTAssertEqual(off.spatialMode, .stereo)
        XCTAssertNil(off.headTracking)
        XCTAssertEqual(HeadphoneBypassSet([]).applied(to: saved), saved)
        for rate in Self.rates {
            XCTAssertNoThrow(try off.validateStructure(sampleRate: rate), "bypassed profile validates at \(rate)")
            XCTAssertEqual(off.conservativeRequiredHeadroomDB, 0, accuracy: 1e-12)
        }
    }

    func testEachCardBypassesOnlyItsOwnPart() {
        let saved = profile(spatial: .virtualSpeakers)
        let corr = HeadphoneBypassSet.correction.applied(to: saved)
        XCTAssertEqual(corr.crossfeed, saved.crossfeed)
        XCTAssertEqual(corr.spatialMode, .virtualSpeakers)
        let xf = HeadphoneBypassSet.crossfeed.applied(to: saved)
        XCTAssertEqual(xf.left, saved.left)
        XCTAssertEqual(xf.crossfeed.preset, .off)
        let vs = HeadphoneBypassSet.virtualSpeakers.applied(to: saved)
        XCTAssertEqual(vs.left, saved.left)
        XCTAssertEqual(vs.spatialMode, .stereo)
        XCTAssertTrue(HeadphoneBypassSet.available(in: saved).contains(.virtualSpeakers))
        XCTAssertFalse(HeadphoneBypassSet.available(in: profile()).contains(.virtualSpeakers))
        XCTAssertEqual(HeadphoneBypassSet.available(in: HeadphoneDeviceProfileConfiguration()), [])
    }

    func testBypassStateIsSessionOnlyAndTransformsEffectiveProfile() {
        let state = HeadphoneBypassState()
        let saved = profile()
        XCTAssertEqual(state.effective(saved), saved)
        state.set(.crossfeed, on: true)
        XCTAssertEqual(state.effective(saved).crossfeed.preset, .off)
        state.set(.crossfeed, on: false)
        XCTAssertEqual(state.effective(saved), saved)
        state.set(.correction, on: true)
        state.clear()
        XCTAssertTrue(state.bypassed.isEmpty)
    }

    func testBypassLevelDropsWithBoostAtEveryRate() {
        let saved = profile(boost: 6)
        for rate in Self.rates {
            let on = HeadphoneBypassLevel.levelDB(of: saved, sampleRate: rate)
            let off = HeadphoneBypassLevel.levelDB(of: HeadphoneBypassSet.correction.applied(to: saved), sampleRate: rate)
            XCTAssertEqual(off, -6, accuracy: 1e-9, "no correction leaves only the headroom (\(rate))")
            XCTAssertGreaterThan(on, off + 2, "a 6 dB band at 1 kHz raises the level (\(rate))")
        }
    }

    // MARK: Before and after on a headphone session

    @MainActor
    private final class FakeHeadphone: HeadphoneCompareSupporting {
        var unavailableReason: String?
        var hasEffect = true
        var levelIsApproximate = false
        var on = 3.0, off = 0.0
        private(set) var calls: [Bool] = []
        func levelDB(bypassed: Bool) -> Double { bypassed ? off : on }
        func apply(bypassed: Bool) throws { calls.append(bypassed) }
    }

    private final class Clock { var now = Date(timeIntervalSince1970: 9_000) }

    private func flatContent() -> ContentABAuditionState {
        ContentABAuditionState(stereoEQ: StereoEQConfiguration(), inputPreampDB: 0, headroomAttenuationDB: 0, dynamics: DynamicsConfiguration())
    }

    func testBeforeAfterSwitchesHeadphoneProcessingAndLevelMatchesIt() throws {
        let player = BlindLiveComparisonTests.FakePlayer(current: flatContent())
        let headphone = FakeHeadphone()
        let clock = Clock()
        let model = BeforeAfterModel(player: player, headphone: headphone, clock: { clock.now })
        model.show(.before)
        XCTAssertEqual(model.side, .before, "content alone is identical, the headphone side makes the comparison real")
        XCTAssertEqual(headphone.calls, [true])
        // The headphone side is 3 dB louder with correction on, so the "after" side is turned down by 3 dB.
        clock.now.addTimeInterval(1)
        model.show(.after)
        XCTAssertEqual(headphone.calls, [true, false])
        XCTAssertEqual(try XCTUnwrap(player.applied.last?.attenuation), -3, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(player.applied.first?.attenuation), 0, accuracy: 0.1)
        model.done()
        XCTAssertEqual(headphone.calls.last, false, "done renders the saved profile")
        XCTAssertNil(model.side)
    }

    func testBeforeAfterOnVirtualSpeakersSaysTheLevelIsNotMatched() {
        let headphone = FakeHeadphone()
        headphone.levelIsApproximate = true
        let model = BeforeAfterModel(player: BlindLiveComparisonTests.FakePlayer(current: flatContent()), headphone: headphone)
        model.show(.before)
        XCTAssertTrue(model.levelSummary?.contains("Virtual Speakers level is not matched") == true)
    }

    func testBeforeAfterRefusesWhenBypassSwitchesAreOnOrNothingProcesses() {
        let headphone = FakeHeadphone()
        headphone.unavailableReason = "Turn off the bypass switches on the Headphones page first."
        let model = BeforeAfterModel(player: BlindLiveComparisonTests.FakePlayer(current: flatContent()), headphone: headphone)
        model.show(.before)
        XCTAssertNil(model.side)
        XCTAssertEqual(model.message, headphone.unavailableReason)
        headphone.unavailableReason = nil
        headphone.hasEffect = false
        model.show(.before)
        XCTAssertEqual(model.message, BlindLiveComparisonError.identicalSides.errorDescription)
        XCTAssertTrue(headphone.calls.isEmpty)
    }

    func testProductionSupportIsOffWithTheFlagOffAndReportsNoEffectWhenIdle() {
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        let product = ProductController(audioEngine: engine)
        let support = ProfileHeadphoneCompare(profiles: product.profiles)
        XCTAssertFalse(support.hasEffect, "flag off")
        flags.setEnabled(true, for: .headphonesPage)
        XCTAssertFalse(support.hasEffect, "not running")
        product.profiles.headphoneBypass.set(.crossfeed, on: true)
        XCTAssertNotNil(support.unavailableReason)
    }

    // MARK: G26 saved shaping and Auto headroom

    func testShapingAndAutoHeadroomSurviveRelaunchPerPair() throws {
        flags.setEnabled(true, for: .headphonesPage)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("profiles.json")
        let profiles = ProductProfileController(engine: AudioIOEngine(), storageURL: url)
        var shaping = HeadphoneTargetShaping()
        shaping.bassShelfDB = 3
        shaping.trebleTiltDB = -1.5
        try profiles.replaceSelectedSystemHeadphoneDeviceProfile(profile(), targetShaping: shaping, autoHeadroom: true)
        let entry = try XCTUnwrap(ProductProfileController(engine: AudioIOEngine(), storageURL: url).selectedSystemHeadphoneList?.selected)
        XCTAssertEqual(entry.targetShaping, shaping)
        XCTAssertEqual(entry.autoHeadroom, true)
        // A copy carries them; an older list without the keys reads as nil.
        var list = try XCTUnwrap(profiles.selectedSystemHeadphoneList)
        let copy = try list.duplicate(entry.id)
        XCTAssertEqual(list.entries.first { $0.id == copy }?.targetShaping, shaping)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any] ?? [:]
        json.removeValue(forKey: "targetShaping")
        json.removeValue(forKey: "autoHeadroom")
        let old = try JSONDecoder().decode(HeadphoneListEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.targetShaping)
        XCTAssertNil(old.autoHeadroom)
    }

    // MARK: G28 layout (the picker card and the bypass switches)

    func testPageWithAListAndBypassSwitchesFitsAtBothSizes() throws {
        flags.setEnabled(true, for: .headphonesPage)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        let product = ProductController(audioEngine: engine)
        try product.profiles.editSelectedSystemHeadphoneList { list in
            _ = try list.add(name: "A very long pair of studio reference headphones, second revision", enabled: false, outputDeviceUID: nil)
            _ = try list.add(name: "Travel earbuds", enabled: false, outputDeviceUID: nil)
        }
        for size in [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)] {
            let page = HostedPage(
                ProductionHeadphoneWorkspace(engine: engine, profiles: product.profiles, calibration: product.multichannelCalibration),
                size: size)
            // The harness does not expose a toggle's label or help; the correction and crossfeed bypass switches are disabled while idle.
            XCTAssertGreaterThanOrEqual(page.controls(of: .toggle).filter { !$0.isEnabled }.count, 2,
                                        "the correction and crossfeed bypass switches are shown (Virtual Speakers card only in that mode)")
            for control in page.controls {
                let frame = control.view.convert(control.view.bounds, to: page.hosting)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(control.label) at \(size.width)")
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(control.label) \(control.title) at \(size.width)")
            }
        }
    }
}
