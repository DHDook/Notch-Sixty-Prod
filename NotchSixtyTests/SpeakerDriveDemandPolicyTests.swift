import XCTest
@testable import NotchSixty

final class SpeakerDriveDemandPolicyTests: XCTestCase {
    func testFlagOffNeverSetsDemand() {
        for requested in [false, true] {
            for transport in [false, true] {
                XCTAssertFalse(SpeakerDriveDemandPolicy.demand(
                    requested: requested, featureEnabled: false, transportAvailable: transport))
            }
        }
    }

    func testDemandNeedsFlagRequestAndTransport() {
        XCTAssertTrue(SpeakerDriveDemandPolicy.demand(requested: true, featureEnabled: true, transportAvailable: true))
        XCTAssertFalse(SpeakerDriveDemandPolicy.demand(requested: false, featureEnabled: true, transportAvailable: true))
        XCTAssertFalse(SpeakerDriveDemandPolicy.demand(requested: true, featureEnabled: true, transportAvailable: false))
    }

    func testFlagIsRegisteredAndDefaultsOff() {
        XCTAssertTrue(FeatureFlag.all.contains(.feedForwardLive))
        XCTAssertFalse(FeatureFlag.feedForwardLive.defaultEnabled)
    }

    @MainActor
    func testEngineDefaultsToFeatureOff() {
        XCTAssertFalse(AudioIOEngine().speakerDriveFeatureEnabled)
    }
}
