import AudioToolbox
import AVFAudio

extension AVAudioNode {
    /// Scoped access to the node's `AUAudioUnit` on every supported macOS.
    ///
    /// macOS 27 adds `withAUAudioUnit(_:)` and deprecates the `auAudioUnit`
    /// property; macOS 26 has only the property. Control plane only: callers
    /// must not invoke this from an audio callback.
    func withNodeAUAudioUnit<R, E: Error>(
        _ body: (AUAudioUnit) throws(E) -> R
    ) throws(E) -> R {
        if #available(macOS 27, *) {
            return try withAUAudioUnit { (au: borrowing AUAudioUnit) throws(E) -> R in
                try body(copy au)
            }
        }
        return try body(auAudioUnit)
    }
}
