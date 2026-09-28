# PR39 Slice 3 status

Slice 3 integrates the off-callback production analysis engine.

- `ProductionAnalysisWorker` is owned by the active `CoreAudioTransportSession` and is stopped synchronously before its realtime bridge is destroyed.
- The worker source lives in the existing `NotchSixty/Diagnostics` Xcode group; an initial path mismatch was corrected before the compiled Slice 3 validation pass.
- The worker is the single consumer of the Slice 2 SPSC analysis ring.
- Analysis runs on a dedicated serial queue only while Spectrum or Stereo demand is active.
- RTA uses an independently authored Accelerate DFT implementation with retained setup/work buffers and adaptive 4096 / 8192 / 16384 / 32768 transforms through 384 kHz.
- Input and Output are analyzed simultaneously into 96 logarithmic display bands from 20 Hz to the lower of 20 kHz or the valid Nyquist range.
- Left/right spectrum energy is combined after the transforms, so anti-phase stereo content is not falsely erased by a time-domain mono sum.
- Hann-window amplitude normalization is used so a full-scale sine maps near 0 dBFS rather than reporting an arbitrary FFT-bin magnitude.
- Spectrum peak hold is approximately one second at the 20 Hz worker cadence, followed by bounded decay.
- Output phase correlation uses normalized cross-correlation over approximately 100 ms and reports silence as undefined rather than inventing a phase value; the retained history now remains long enough to preserve that averaging interval through 384 kHz.
- The output goniometer uses the standard 45-degree stereo rotation and a bounded recent-history point set.
- Deterministic tests cover adaptive FFT sizing, bridge-local/sanitized analysis demand, correlation canonical cases, goniometer rotation, silence floor, 1 kHz full-scale calibration through 384 kHz, and anti-phase stereo spectrum preservation.
- The first complete production-analysis compile exposed only a Swift stored-property initialization rule: the worker's buffer initializers referenced class constants through covariant `Self`. Those initializers now use the concrete `ProductionAnalysisWorker` type name; no algorithm, realtime capture, demand, signal-location, or UI behavior changed.
- A later ownership audit found and fixed a potential SPSC race: demand changes no longer mutate the consumer read index from the control thread. The worker exclusively owns read-index advancement/discard operations on its serial queue.
- The temporary compiler-diagnostic and ownership-fix workflows were removed after their changes landed.

The production Spectrum and Stereo SwiftUI surfaces are now wired. The next gate is the normal exact-head macOS Debug/Release/XCTest suite followed by focused hardware/UI/CPU validation.
