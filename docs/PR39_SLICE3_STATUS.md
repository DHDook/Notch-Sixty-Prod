# PR39 Slice 3 status

Slice 3 integrates the off-callback production analysis engine.

- `ProductionAnalysisWorker` is owned by the active `CoreAudioTransportSession` and is stopped synchronously before its realtime bridge is destroyed.
- The worker is the single consumer of the Slice 2 SPSC analysis ring.
- Analysis runs on a dedicated serial queue only while Spectrum or Stereo demand is active.
- RTA uses an independently authored Accelerate DFT implementation with retained setup/work buffers and adaptive 4096 / 8192 / 16384 / 32768 transforms through 384 kHz.
- Input and Output are analyzed simultaneously into 96 logarithmic display bands from 20 Hz to the lower of 20 kHz or the valid Nyquist range.
- Hann-window amplitude normalization is used so a full-scale sine maps near 0 dBFS rather than reporting an arbitrary FFT-bin magnitude.
- Spectrum peak hold is approximately one second at the 20 Hz worker cadence, followed by bounded decay.
- Output phase correlation uses normalized cross-correlation over approximately 100 ms and reports silence as undefined rather than inventing a phase value.
- The output goniometer uses the standard 45-degree stereo rotation and a bounded recent-history point set.
- Deterministic tests cover adaptive FFT sizing, correlation canonical cases, goniometer rotation, silence floor, and 1 kHz full-scale calibration through 384 kHz.

The production Spectrum and Stereo SwiftUI surfaces are wired in the next slice after this analyzer/core integration passes the normal macOS build and XCTest gate.
