# Linear-phase EQ foundation

PR #18 adds a portable control-plane designer that converts the same parametric EQ concepts used by the minimum-phase path into a symmetric FIR suitable for the production partitioned convolver.

## Design goals

- preserve the existing minimum-phase biquad engine unchanged;
- use the production FIR/convolution backend rather than introducing a second convolution path;
- keep filter design off the realtime render thread;
- preserve useful low-frequency resolution as the hardware sample rate changes;
- make all latency explicit;
- remain portable C with no Core Audio, Swift, Accelerate, or other Apple-specific dependency.

## Filter generation

The designer evaluates the magnitude response of the enabled parametric bands, constructs a zero-phase Hermitian spectrum, transforms it to an impulse response, centers it to make the filter causal, and applies a Blackman window. The resulting impulse response is symmetric, so phase is linear and group delay is constant.

The control-plane designer may allocate and perform trigonometry/FFT work. None of this runs in the audio callback. The generated taps are handed to `N60PartitionedConvolver`, whose render path remains allocation-free and lock-free.

## Time-scaled tap count

A fixed tap count gives radically different frequency resolution at 48 kHz and 384 kHz. Notch Sixty instead targets approximately 21.33 ms of FIR group delay and chooses an odd tap count from the active sample rate.

Representative designs:

| Sample rate | Tap count | FIR group delay | Convolver block latency | Approx. total |
| --- | ---: | ---: | ---: | ---: |
| 44.1 kHz | 1,883 | 21.34 ms | 5.80 ms | 27.14 ms |
| 48 kHz | 2,049 | 21.33 ms | 5.33 ms | 26.67 ms |
| 96 kHz | 4,097 | 21.33 ms | 2.67 ms | 24.00 ms |
| 192 kHz | 8,193 | 21.33 ms | 1.33 ms | 22.67 ms |
| 384 kHz | 16,385 | 21.33 ms | 0.67 ms | 22.00 ms |

This is intentionally lower than the roughly 40 ms latency observed in the legacy linear-EQ mode while retaining time-scaled low-frequency resolution.

## Current boundary

PR #18 establishes the actual FIR designer and its convolution-compatible latency contract. The existing app continues to use minimum-phase EQ by default.

Live arbitrary FIR replacement is not enabled yet. PR #17 intentionally left slot retirement/reuse unresolved while a hardware buffer may still hold the old graph generation. A later control-plane milestone must establish an explicit safe program-retirement lifecycle before linear-phase mode is exposed as a live switch.

That sequencing avoids a use-after-repurpose race in exchange for a small amount of temporary UI delay.

## Future work

- safe live FIR program replacement and graph crossfade;
- minimum/linear mode selector in the production EQ model;
- background redesign while parameters are edited;
- response-cache/debounce for rapid UI changes;
- optimized FFT/design backends where benchmarks justify them;
- reuse of the same convolution backend for room correction and linear-phase crossover.
