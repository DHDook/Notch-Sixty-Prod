# PR28 Advanced Dynamics — De-Esser and Multiband Compressor

## Scope

PR28 adds independently authored realtime De-Esser and three-band Multiband Compressor processing to the commercial `N60Dynamics` engine. The observable parity contract is limited to documented user-facing legacy behavior; no legacy implementation or inherited tests are used.

## Signal order

Within the existing zero-latency core dynamics stage:

`De-Esser -> 3-band Multiband Compressor -> Wideband Compressor -> Expander`

PR27 protection remains later in the graph, and Pause Gate remains after protection. Reference/Delta latency semantics are unchanged because PR28 adds no algorithmic delay.

## De-Esser

Product controls: 2–10 kHz center frequency, −60–0 dB threshold, enable, and Dynamic-EQ mode. A linked-stereo sidechain is built from precomputed high-pass and low-pass biquads around the selected center. Dynamic-EQ mode applies time-varying attenuation only to that extracted component; full-band mode applies the same linked gain to the whole signal. Attack/release and ratio are commercial implementation constants for this parity slice rather than undocumented user controls.

## Multiband Compressor

Product controls: enable, 40–250 Hz Low/Mid crossover, 1–8 kHz Mid/High crossover, independent Low/Mid/High thresholds, and LR4/LR8 slope selection. Low and high outer bands use precomputed Linkwitz-Riley legs from the commercial crossover primitives. The mid band is defined as the residual complement (`dry - low - high`), which makes recombination sample-exact at unity gain and avoids a hidden bypass coloration/gain change. Each band uses linked-stereo detection and independent gain smoothing.

## Realtime contract

All coefficient design occurs on the control plane. The render callback uses fixed-size state only: no allocation/free, locks, logging, I/O, asynchronous work, or filter design.

## Acceptance gates

- configured-disabled LR4 and LR8 multiband paths recombine to unity;
- de-esser produces measurable reduction in the configured sibilance region;
- multiband bands trigger independently and preserve linked-stereo image;
- invalid product ranges are rejected;
- Global Bypass remains raw;
- no added latency;
- hardware pass checks bypass transparency, toggling, imaging, and audible artifacts.
