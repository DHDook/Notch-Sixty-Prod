import AudioToolbox
import AVFAudio

extension AVAudioNode {
    /// Scoped access to the node's `AUAudioUnit`.
    ///
    /// macOS 27 (the minimum) adds `withAUAudioUnit(_:)` and deprecates the `auAudioUnit`
    /// property, so the scoped call is used directly. Control plane only: callers
    /// must not invoke this from an audio callback.
    func withNodeAUAudioUnit<R, E: Error>(
        _ body: (AUAudioUnit) throws(E) -> R
    ) throws(E) -> R {
        try withAUAudioUnit { (au: borrowing AUAudioUnit) throws(E) -> R in
            try body(copy au)
        }
    }
}
