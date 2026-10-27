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
| `e4.adaptive-anc` | E4 | Adaptive Quiet Zone controls |
| `e6.legacy-kernel` | E6 | Selects the frozen legacy render kernel (E23 deletes it) |
