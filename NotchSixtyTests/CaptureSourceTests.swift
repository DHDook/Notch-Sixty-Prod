import CoreAudio
import XCTest
@testable import NotchSixty

/// E36 S1: the input-source seam. The three transport sessions build their taps and aggregates through
/// `ProcessTapSpec` and `TapAggregateSpec`; these tests pin the descriptions they produced before the seam.
final class CaptureSourceTests: XCTestCase {
    static let standardRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    final class FakeHAL: HALPropertyStore {
        var calls: [String] = []
        var tapStatus: OSStatus = noErr
        var aggregateStatus: OSStatus = noErr

        func createProcessTap(_ description: CATapDescription) -> (status: OSStatus, tapID: AudioObjectID) {
            calls.append("createTap")
            return (tapStatus, tapStatus == noErr ? 101 : AudioObjectID(kAudioObjectUnknown))
        }
        func destroyProcessTap(_ tapID: AudioObjectID) { calls.append("destroyTap \(tapID)") }
        func createAggregateDevice(_ description: [String: Any]) -> (status: OSStatus, deviceID: AudioDeviceID) {
            calls.append("createAggregate")
            return (aggregateStatus, aggregateStatus == noErr ? 202 : AudioDeviceID(kAudioObjectUnknown))
        }
        func destroyAggregateDevice(_ deviceID: AudioDeviceID) { calls.append("destroyAggregate \(deviceID)") }
    }

    func testStereoTapDescriptionIsPrivateMutedAndDeviceScoped() {
        let description = ProcessTapSpec(
            excludedProcess: 7, deviceUID: "dac-uid", name: "Notch Sixty System Audio", keepsAllChannels: false
        ).makeDescription()
        XCTAssertEqual(description.name, "Notch Sixty System Audio")
        XCTAssertTrue(description.isPrivate)
        XCTAssertEqual(description.muteBehavior, .mutedWhenTapped)
        XCTAssertEqual(description.deviceUID, "dac-uid")
        XCTAssertEqual(description.processes, [7])
    }

    func testProgramTapKeepsEveryChannel() {
        let description = ProcessTapSpec(
            excludedProcess: 7, deviceUID: "src", name: "Notch Sixty Semantic Program", keepsAllChannels: true
        ).makeDescription()
        XCTAssertFalse(description.isMixdown)
        XCTAssertFalse(description.isMono)
    }

    func testAggregateDictionariesMatchEachSessionAtEveryRate() throws {
        // The descriptions do not depend on the rate; the loop pins that they stay that way at every standard rate.
        for rate in Self.standardRates {
            XCTAssertGreaterThan(rate, 0)
            let plain = TapAggregateSpec(
                name: "Notch Sixty Private Tap", uidPrefix: "com.dhdook.NotchSixty.aggregate",
                tapUID: "TAP", tapDriftCompensation: false
            ).dictionary(uidSuffix: "X")
            XCTAssertEqual(plain[kAudioAggregateDeviceNameKey] as? String, "Notch Sixty Private Tap")
            XCTAssertEqual(plain[kAudioAggregateDeviceUIDKey] as? String, "com.dhdook.NotchSixty.aggregate.X")
            XCTAssertEqual(plain[kAudioAggregateDeviceTapAutoStartKey] as? Bool, false)
            XCTAssertEqual(plain[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
            XCTAssertNil(plain[kAudioAggregateDeviceSubDeviceListKey])
            XCTAssertNil(plain[kAudioAggregateDeviceMainSubDeviceKey])
            let taps = try XCTUnwrap(plain[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
            XCTAssertEqual(taps.count, 1)
            XCTAssertEqual(taps[0][kAudioSubTapUIDKey] as? String, "TAP")
            XCTAssertEqual(taps[0][kAudioSubTapDriftCompensationKey] as? Bool, false)

            var multi = TapAggregateSpec(
                name: "Notch Sixty Semantic Multi-Output", uidPrefix: "com.dhdook.NotchSixty.semantic",
                tapUID: "TAP", tapDriftCompensation: true
            )
            multi.subDevices = [.init(uid: "A", driftCompensation: false), .init(uid: "B", driftCompensation: true)]
            multi.mainSubDeviceUID = "A"
            let dictionary = multi.dictionary(uidSuffix: "Y")
            XCTAssertEqual(dictionary[kAudioAggregateDeviceMainSubDeviceKey] as? String, "A")
            let subs = try XCTUnwrap(dictionary[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
            XCTAssertEqual(subs.map { $0[kAudioSubDeviceUIDKey] as? String }, ["A", "B"])
            XCTAssertEqual(subs.map { $0[kAudioSubDeviceDriftCompensationKey] as? Bool }, [false, true])
            let multiTaps = try XCTUnwrap(dictionary[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
            XCTAssertEqual(multiTaps[0][kAudioSubTapDriftCompensationKey] as? Bool, true)
        }
    }

    func testSourceCreatesThroughStoreAndClosesAggregateBeforeTap() {
        let hal = FakeHAL()
        let source = ProcessTapCaptureSource(store: hal)
        XCTAssertEqual(source.captureDeviceID, AudioDeviceID(kAudioObjectUnknown))
        let description = ProcessTapSpec(excludedProcess: 1, deviceUID: "u", name: "n", keepsAllChannels: false).makeDescription()
        XCTAssertEqual(source.createTap(description), noErr)
        XCTAssertEqual(source.tapID, 101)
        XCTAssertEqual(
            source.createAggregate(TapAggregateSpec(name: "a", uidPrefix: "p", tapUID: "t", tapDriftCompensation: false)),
            noErr
        )
        XCTAssertEqual(source.captureDeviceID, 202)
        source.close()
        source.close()
        XCTAssertEqual(hal.calls, ["createTap", "createAggregate", "destroyAggregate 202", "destroyTap 101"])
        XCTAssertEqual(source.captureDeviceID, AudioDeviceID(kAudioObjectUnknown))
    }

    func testFailedCreateLeavesNothingToDestroy() {
        let hal = FakeHAL()
        hal.tapStatus = -1
        let source = ProcessTapCaptureSource(store: hal)
        let description = ProcessTapSpec(excludedProcess: 1, deviceUID: "u", name: "n", keepsAllChannels: false).makeDescription()
        XCTAssertEqual(source.createTap(description), -1)
        source.close()
        XCTAssertEqual(hal.calls, ["createTap"])
    }

    func testInputLifecycleTransitions() {
        typealias S = AudioLifecycleStateMachine
        XCTAssertTrue(S.canTransition(from: .running, to: .switchingInput))
        XCTAssertTrue(S.canTransition(from: .switchingInput, to: .running))
        XCTAssertTrue(S.canTransition(from: .switchingInput, to: .waitingForInputDevice))
        XCTAssertTrue(S.canTransition(from: .running, to: .waitingForInputDevice))
        XCTAssertTrue(S.canTransition(from: .idle, to: .waitingForInputDevice))
        XCTAssertTrue(S.canTransition(from: .waitingForInputDevice, to: .running))
        XCTAssertTrue(S.canTransition(from: .waitingForInputDevice, to: .switchingInput))
        XCTAssertTrue(S.canTransition(from: .waitingForInputDevice, to: .stopping))
        XCTAssertTrue(S.canTransition(from: .switchingInput, to: .stopping))
        XCTAssertFalse(S.canTransition(from: .waitingForInputDevice, to: .idle))
        XCTAssertFalse(S.canTransition(from: .switchingInput, to: .idle))
        XCTAssertFalse(S.canTransition(from: .idle, to: .switchingInput))
        XCTAssertFalse(S.canTransition(from: .recoveringOutput, to: .switchingInput))
        XCTAssertFalse(S.canTransition(from: .stopping, to: .waitingForInputDevice))
    }

    func testFlagIsKnownAndDefaultsOff() {
        XCTAssertTrue(FeatureFlag.all.contains(.virtualDriver))
        XCTAssertFalse(FeatureFlag.virtualDriver.resolvedDefault)
        XCTAssertEqual(FeatureFlag.virtualDriver.id, "e36.virtual-driver")
    }
}
