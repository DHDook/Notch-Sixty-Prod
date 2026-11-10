# Feature flags

Unfinished epics merge to `main` dark, behind a feature flag that is off by default. This keeps
`main` releasable while an epic lands over several PRs.

## Adding a flag

1. Add an entry to `FeatureFlag.all` in `NotchSixty/State/FeatureFlags.swift`, with a stable `id`,
   a title, and the owning epic (for example `epic: "E6"`).
2. Gate the new behaviour in the app shell with `featureFlags.isEnabled(.yourFlag)`. Views get
   the store from the environment (`@EnvironmentObject var featureFlags: FeatureFlags`).
   Controllers take it as an initialiser argument so tests can inject one.
3. Keep the shipping behaviour unchanged while the flag is off, and test both states.

When the epic ships, delete the flag and every check that reads it in the same PR.

## Rules

- **The engine never reads flags.** Swift decides, then publishes the resulting configuration
  through the normal graph/snapshot path. The realtime core stays flag-free and portable (E21).
- **Debug builds** show a Developer section in Settings to switch flags on. The choice is stored
  as `feature.<id>` in `UserDefaults`.
- **Release builds** ignore stored overrides, so a shipped build never shows unfinished work by
  accident. For TestFlight testing, launch with `-NotchSixtyFeatures id1,id2`.
- Flags that aren't in `FeatureFlag.all` are always off. A stale override left by a removed
  flag, or a mistyped launch argument, can't switch anything on.
- All persisted keys live in `NotchSixty/State/PreferenceKeys.swift`. Never rename a stored key.

## Current flags

| id | epic | gates |
| --- | --- | --- |
| `e6.legacy-kernel` | E6 | Selects the frozen legacy render kernel (E23 deletes it) |
| `e4.adaptive-tonal-live` | E4 | Live adaptive tonal canceller and the supervised microphone-move re-solve; still needs the per-feature arm switch (S18b) |
| `e4.earned-cap` | E4 | Anti-noise cap earned in 3 dB steps from -40 to -18 dBFS per binding (S20); needs `e4.adaptive-tonal-live` |
| `e4.feedforward-live` | E4 | Live feed-forward cancellation (S22); S22b1 gates only the speaker-drive recording for the echo model; off means nothing sets the demand |
| `e4.conversation-unmasking` | E4 | Conversation Focus unmasking by SII per-band music cuts and syllable-rate speech detection (S30); ambient compensation only, no ANC output |
| `e4.virtual-microphone` | E4 | Tonal virtual microphone at the ears: monitor-to-ear ratio survey and effective secondary path (S26a); offline maths, no output |
| `e4.zones` | E4 | Choose the quiet zone: fixed seat, follow, or two zones with the 2 x 2 per-tone core and zone mode in the earned-cap binding (S27); offline maths, no output |
| `e4.overnight` | E4 | Overnight Quiet Zone runs: keep the Mac awake while armed (power assertion, S29) and the 10-minute thermal mean; type only, nothing arms it |
| `e26.sub-aware-anc` | E26 | On by default, including release builds (owner decision, E26 S7). Sub-aware Quiet Zone: bass-path records and readiness replace the blanket subwoofer refusal (S1 so far: mono bass on the pair no longer counts as a sub). The undeclared-receiver refusal and its declaration picker are always on |
| `e9.long-fir` | E9 | Off by default. Graph FIRs (program, room, speaker IR, driver) of up to 262,144 taps on the non-uniform engine (`firScheme` 1) at the same 256-frame latency; Swift lifts the 32,768 eligibility and lane-plan limits. Read once at launch (takes effect on relaunch). Off: 32,768 and the kernel fallback above it, unchanged |
| `e9.output-protection` | E9 | Off by default. Every graph output is protected: sub lanes get their own PROTECTION stage with the program settings, an Advanced "Independent per output" switch gives every program lane its own stage, and an always-on hard limit (-1 dBFS, no look-ahead, zero latency) closes every output, routed outputs included. Read once at launch (takes effect on relaunch). Off: the graph is bit-identical to before |
| `e13.headphones` | E13 | Off by default. Guided personal BRIR capture in Headphones (S7): in-ear microphones, speaker passes at 1, 3 or 5 head yaws, optional headphone compensation, quality-gated passes and a review before saving. S3 to S5 (live tuning, long BRIRs, interpolation) join this flag. Off: no capture button |
| `e19.mimo-treatment` | E19 | Off by default. MIMO room treatment (S3 so far: the Swift designer calling the portable design core and checking the realised filters; nothing in the app calls it yet). Off: today's code paths, UI and routing refusal. On: the new designer and, in later slices, the stage, safety layer, verifier and controls; live output still needs a permit and the arm |
