import XCTest
@testable import NotchSixty

final class SystemSetupStartStepsTests: XCTestCase {
    func testStereoPresetDisablesBassManagement() {
        var state = PlaybackSystemState()
        state.bassManagement.enabled = true
        state.bassManagement.physicalOutputMode = .mainsSub
        let out = SystemSetupTopologyPreset(topology: .stereo).applying(to: state)
        XCTAssertFalse(out.bassManagement.enabled)
        // E8 A2a: a stored legacy output mode is left as it is.
        XCTAssertEqual(out.bassManagement.physicalOutputMode, .mainsSub)
    }

    func testSubwooferPresetsWriteCrossoverAndTouchNothingElse() {
        let state = PlaybackSystemState()
        for topology in [SystemSetupTopology.twoPointOne, .twoPointTwo] {
            let preset = SystemSetupTopologyPreset(topology: topology, crossoverHz: 100, slope: .linkwitzRiley48)
            let out = preset.applying(to: state)
            XCTAssertTrue(out.bassManagement.enabled)
            XCTAssertNil(out.bassManagement.physicalOutputMode, "the preset never writes the legacy output mode")
            XCTAssertEqual(out.bassManagement.frequencyHz, 100)
            XCTAssertEqual(out.bassManagement.topology, .linkwitzRiley48)
            var restored = out
            restored.bassManagement = state.bassManagement
            XCTAssertEqual(restored, state)
        }
    }

    func testCrossoverIsClampedToRange() {
        let out = SystemSetupTopologyPreset(topology: .twoPointOne, crossoverHz: 5_000).applying(to: PlaybackSystemState())
        XCTAssertEqual(out.bassManagement.frequencyHz, BassManagementConfiguration.frequencyRange.upperBound)
    }

    func testCurrentTopologyRoundTrips() {
        let state = SystemSetupTopologyPreset(topology: .twoPointOne, crossoverHz: 90).applying(to: PlaybackSystemState())
        let back = SystemSetupTopologyPreset.current(from: state)
        XCTAssertEqual(back.topology, .twoPointOne)
        XCTAssertEqual(back.crossoverHz, 90)
        XCTAssertEqual(SystemSetupTopologyPreset.current(from: PlaybackSystemState()).topology, .stereo)
    }

    func testLevelStartsAtMinus40AndNeverExceedsCeiling() {
        var plan = SystemSetupLevelPlan()
        XCTAssertEqual(plan.levelDB, -40)
        XCTAssertEqual(plan.generatorSettings().kind, .bandLimitedPink)
        for _ in 0..<100 {
            plan.raise()
            XCTAssertLessThanOrEqual(plan.levelDB, SignalGeneratorSettings.hardCeilingDB)
            XCTAssertLessThanOrEqual(plan.generatorSettings().effectiveLevelDB, SignalGeneratorSettings.hardCeilingDB)
        }
        XCTAssertTrue(plan.atCeiling)
        plan.reset()
        XCTAssertEqual(plan.levelDB, -40)
    }

    func testRaiseOnlyOnRequest() {
        var plan = SystemSetupLevelPlan()
        plan.raise()
        XCTAssertEqual(plan.levelDB, -37)
        plan.lower()
        plan.lower()
        XCTAssertEqual(plan.levelDB, -43)
    }

    func testSweepLevelFromSimulatedSPL() {
        var plan = SystemSetupLevelPlan()
        plan.raise(); plan.raise() // -34 dBFS
        // 65 dB(C) measured: 10 dB below target, so 10 dB louder.
        XCTAssertEqual(plan.sweepLevel(measuredSPLdBC: 65), -24, accuracy: 1e-9)
        // Already at target.
        XCTAssertEqual(plan.sweepLevel(measuredSPLdBC: 75), -34, accuracy: 1e-9)
        // Very quiet reading is clamped to the ceiling.
        XCTAssertEqual(plan.sweepLevel(measuredSPLdBC: 20), SignalGeneratorSettings.hardCeilingDB)
        // Very loud reading is clamped to the floor.
        XCTAssertEqual(plan.sweepLevel(measuredSPLdBC: 140), SystemSetupLevelPlan.minimumSweepLevelDB)
        XCTAssertEqual(plan.sweepLevel(measuredSPLdBC: .nan), -34)
    }

    func testEntryAvailability() {
        let none = SystemCalibrationStatus.notCalibrated
        func avail(name: String? = "Studio Monitors", uid: String? = "u",
                   status: SystemCalibrationStatus = none) -> SystemSetupEntryPolicy.Availability {
            SystemSetupEntryPolicy.availability(
                outputName: name, outputUID: uid, state: PlaybackSystemState(), calibration: status)
        }
        XCTAssertEqual(avail(uid: nil), .hidden)
        XCTAssertEqual(avail(), .offer)
        XCTAssertEqual(avail(name: "Bob's AirPods Pro"), .headphonesPointer)
        XCTAssertEqual(avail(name: "USB Headphones"), .headphonesPointer)
    }

    func testHeadphoneProfileMarksHeadphones() {
        var state = PlaybackSystemState()
        state.headphoneDeviceProfile = HeadphoneDeviceProfileConfiguration()
        state.headphoneDeviceProfile?.enabled = true
        XCTAssertTrue(SystemSetupEntryPolicy.isHeadphoneOutput(name: "DAC", uid: "x", state: state))
        state.headphoneDeviceProfile?.outputDeviceUID = "other"
        XCTAssertFalse(SystemSetupEntryPolicy.isHeadphoneOutput(name: "DAC", uid: "x", state: state))
    }

    /// E8 A2a: presets change only enabled, frequencyHz and topology; stored legacy fields survive byte-identical.
    func testPresetsLeaveStoredLegacyFieldsAlone() {
        var state = PlaybackSystemState()
        state.bassManagement.physicalOutputMode = .triAmp
        state.bassManagement.upperFrequencyHz = 3_000
        state.bassManagement.upperTopology = .linkwitzRiley24
        state.outputRouting = MultiOutputRoutingConfiguration(enabled: true, routes: [])
        for topology in [SystemSetupTopology.stereo, .twoPointOne, .twoPointTwo] {
            let out = SystemSetupTopologyPreset(topology: topology, crossoverHz: 90, slope: .linkwitzRiley48).applying(to: state)
            XCTAssertEqual(out.bassManagement.physicalOutputMode, .triAmp)
            XCTAssertEqual(out.bassManagement.upperFrequencyHz, 3_000)
            XCTAssertEqual(out.bassManagement.upperTopology, .linkwitzRiley24)
            XCTAssertEqual(out.outputRouting, state.outputRouting)
            var restored = out
            restored.bassManagement.enabled = state.bassManagement.enabled
            restored.bassManagement.frequencyHz = state.bassManagement.frequencyHz
            restored.bassManagement.topology = state.bassManagement.topology
            XCTAssertEqual(restored, state)
        }
    }
}
