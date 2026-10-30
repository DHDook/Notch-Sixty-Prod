import Foundation

/// E4 S22b1: when the render callback may record the speaker drive. Pure, so a test can show
/// that with `e4.feedforward-live` off nothing ever sets the demand.
enum SpeakerDriveDemandPolicy {
    static func demand(requested: Bool, featureEnabled: Bool, transportAvailable: Bool) -> Bool {
        requested && featureEnabled && transportAvailable
    }
}
