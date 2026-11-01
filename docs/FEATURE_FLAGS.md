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
| `e13.byo-import` | E13 | Frequency-response and target import, target categories, Correction tab "Import target..." (S1); removed at the end of S2 |
