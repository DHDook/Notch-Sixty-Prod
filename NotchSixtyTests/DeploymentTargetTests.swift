import AudioToolbox
import AVFAudio
import XCTest
@testable import NotchSixty

/// E2: Notch Sixty's minimum macOS is 26.0. The app's Info.plist takes
/// `LSMinimumSystemVersion` from `MACOSX_DEPLOYMENT_TARGET`, so checking the built
/// host app covers both settings.
final class DeploymentTargetTests: XCTestCase {
    func testHostAppDeclaresMacOS26Minimum() {
        let minimum = Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String
        XCTAssertEqual(minimum, "26.0")
    }

    func testNodeAUAudioUnitAccessReachesTheNodesAudioUnit() {
        let delay = AVAudioUnitDelay()
        let description = delay.withNodeAUAudioUnit { au in au.componentDescription }
        XCTAssertEqual(description.componentType, kAudioUnitType_Effect)
        XCTAssertEqual(description.componentSubType, kAudioUnitSubType_Delay)
    }

    func testNodeAUAudioUnitAccessPropagatesThrownErrors() {
        struct Expected: Error {}
        let delay = AVAudioUnitDelay()
        XCTAssertThrowsError(
            try delay.withNodeAUAudioUnit { _ throws(Expected) in throw Expected() }
        ) { error in
            XCTAssertTrue(error is Expected)
        }
    }
}
