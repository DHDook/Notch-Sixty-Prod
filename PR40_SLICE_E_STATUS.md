# PR40 Slice E validation checkpoint

The target/correction-preview layer is green and this checkpoint adds bounded offline minimum-phase FIR synthesis on top of it.

Target/preview work already validated:
- Flat, Gentle Downward Tilt, and Bass Shelf + Tilt built-in targets;
- deterministic target text import, normalization, sorting and duplicate-frequency averaging;
- log-frequency target interpolation;
- non-destructive fractional-octave magnitude smoothing;
- correction-range / usable-range intersection;
- maximum boost/cut clamps, deep-null boost protection, and smooth edge tapering;
- explicit correction-preview headroom without changing Content Preset ownership.

FIR work in this gate:
- offline real-cepstrum conversion from the desired correction magnitude to a causal minimum-phase stereo response;
- power-of-two Accelerate complex transforms sized independently of the realtime callback;
- bounded tap generation through the existing `N60_CONVOLUTION_MAX_TAPS` limit;
- direct output in the existing `RoomCorrectionFilter` model used by the current room-correction convolution runtime;
- zero declared intentional filter latency for the minimum-phase design; existing convolution partition latency remains separate and authoritative;
- post-truncation re-measurement of the actual generated Left / Right filters rather than assuming the ideal magnitude survives finite tap length unchanged;
- predicted corrected Left / Right magnitude response derived from the actual truncated filter;
- recommended headroom derived from the actual maximum positive filter gain with a deterministic safety margin;
- finite-data, sample-rate, Nyquist and transform-size validation;
- stable algorithm version `n60-room-minphase-v1`.

Deterministic FIR tests cover:
- identity / unity correction;
- opposite stereo boost/cut and predicted-response closure;
- 44.1, 48, 96 and 384 kHz native-rate generation;
- the full 32,768-tap convolution budget;
- finite tap/response validation and zero declared latency;
- Nyquist rejection;
- successful `RoomCorrectionProject` persistence validation of a generated target/design/filter.

This checkpoint does not yet persist/edit target/design state through the project controller, expose production Target/Design controls, or deploy a generated FIR. Those remain the next Slice E integration gate and Slice F deployment gate.