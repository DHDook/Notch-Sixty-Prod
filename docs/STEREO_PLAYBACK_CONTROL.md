# Stereo EQ and Playback Control

PR #23 extends the proprietary realtime DSP graph from linked stereo EQ to explicit linked or independent left/right processing while preserving the existing driverless Core Audio transport.

## Behavior

- Linked mode applies one 64-band EQ configuration to both channels.
- Independent mode stores up to 64 bands per channel and preserves left/right edits when switching back to linked mode.
- The first transition from linked to independent seeds both channel configurations from the linked configuration; subsequent mode round-trips are non-destructive.
- Minimum-phase EQ compiles independent bands into channel-scoped render slots.
- Linear-phase EQ designs equal-length left/right FIRs and uses the existing stereo partitioned convolver.
- Balance is attenuation-only: center is exact unity, and neither channel can exceed unity because of balance.
- Global Bypass and Flat audition preserve all configured state while rendering the untreated captured stereo signal.
- Per-band EQ gain is limited to -24...+24 dB in the UI, product model, legacy compatibility path, and portable biquad designer.

## Realtime contract

All coefficients, FIR taps, graph state, and channel routing are prepared on the control plane. The callback uses only preallocated filter state, immutable graph snapshots, convolution programs, and smoothed gains. No allocations, locks, logging, file I/O, or UI state access are introduced.

## Transition policy

Minimum-phase coefficient/channel changes use the existing short EQ crossfade. Balance uses the existing smoothed-gain transition. FIR replacement and transitions between processed and raw bypass paths use the transport graph transition fade so latency-changing state is never switched as a hard discontinuity.

## Validation

Deterministic tests cover linked equality, left-only channel isolation, attenuation-only balance, raw bypass identity, non-destructive linked/independent round-trips, 64-band-per-channel graph compilation at 384 kHz, rejection of extreme/non-finite EQ gain values, acceptance of the -24/+24 dB boundaries, and repeated FIR-edit policy checks while Global Bypass or Flat is active. Both the stereo control model and its dedicated test suite are explicitly included in their Xcode target source phases so CI validates the shipping target configuration rather than loose source files. Hardware acceptance additionally checks audible channel isolation, balance, minimum/linear phase, Flat/Bypass transitions, repeated switching, and realtime diagnostics.

## Hardware safety hardening

The first PR #23 hardware acceptance pass exposed that free-form EQ gain entry could accept pathological values such as +300 dB, producing a dangerously loud output event. PR #23 now clamps the engineering UI and rejects per-band gains outside -24...+24 dB before graph publication; the portable C biquad designer independently rejects the same range violations as defense in depth. The hardware pass also exposed that the fixed-height engineering layout could make lower diagnostics unreachable, so the validation surface is now vertically scrollable with a smaller minimum window height. The broader automatic-headroom and true-peak protection work remains planned for the later dynamics/protection stage.

## Provenance

This implementation is original commercial work derived from current product requirements, the proprietary PR #13–22 architecture, standard DSP equations/behavior, and independently written tests. Historical GPL Notch Sixty / Equaliser implementation, tests, project files, presets, and assets were not used as implementation references.

## Raw-bypass FIR update policy

Global Bypass and Flat keep the engine on the untreated path. While either is active, linear-EQ and room-correction edits update and validate product state without preparing or rotating convolution programs and without requesting an audibly redundant fade-through-silence transition. FIR state invalidated by a bypassed edit is lazily prepared from the current configuration when processed audio resumes.
