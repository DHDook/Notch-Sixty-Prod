# PR44 — Factory Content Preset Pack

Status: **IMPLEMENTED — EXACT-HEAD SOFTWARE VALIDATION REQUIRED**

PR44 restores the owner-designed listening presets as first-class production `ContentPreset` factory choices on top of the PR43 stack.

## Factory presets

The production factory set is:

1. **Reference** — clean, transparent, detailed baseline voicing.
2. **Rock Arena** — large, fat, raw/natural rock presentation with forward guitars and vocals, controlled bass, and restrained brilliance.
3. **Classic Pop/Rock** — warmer, natural 1960s–1980s pop/rock voicing for recordings such as The Mamas & the Papas and Fleetwood Mac: modest low-end body, reduced low-mid wool, gentle vocal/guitar presence, and restrained air without modernizing the recording.
4. **Modern Pop** — polished low-end/presence/air voicing with gentle program compression and bounded stereo enhancement.
5. **Hip-Hop Club** — stronger sub/bass weight with restrained low-mid congestion, gentle compression, and conservative stereo enhancement above the mono bass region.
6. **Vocal Standards** — natural vocal/jazz-pop voicing for recordings in the Sinatra / Nat King Cole / Ella Fitzgerald tradition: subtle chest warmth, reduced boxiness, clear vocal articulation, softened upper-mid hardness, and minimal added air.
7. **Cinema** — dialogue-forward presence with reduced low-mid masking and restrained high-frequency emphasis; no content compressor or widener.
8. **Streaming** — modest presence/clarity correction and gentle dynamics intended to make variable streaming material easier to listen to without becoming aggressively processed.

Each factory preset has a stable UUID so persisted factory selections survive app updates.

## Clean-room / provenance basis

These presets are commercial product content reconstructed from the project owner's own listening decisions, accepted parameter notes, and user-authored preset specifications. They are not copied from inherited GPL implementation source, tests, project structure, or preset-loading code.

The current proprietary `ContentPresetState` model is the implementation source of truth. Historical/legacy preset data is used only as a behavioral/content specification where ownership is established.

## State ownership translation

PR39/PR42 deliberately split media voicing from physical playback-system state. PR44 preserves that architecture:

### Content Preset owns

- linked stereo EQ voicing and phase mode;
- content input preamp;
- content headroom attenuation;
- content dynamics/protection choices.

### Playback System continues to own

- output association and physical output gain/trim;
- bass-management and active-crossover configuration;
- speaker routing and per-driver processing;
- room correction;
- Speaker IR and physical-system alignment.

Accordingly, historical preset crossover values are **not** embedded in these factory Content Presets. A user's Playback System remains authoritative for crossover/bass-management behavior regardless of which music/movie preset is selected.

Historical preset output-level compensation is represented as `headroomAttenuationDB`, not Playback-System `outputGainDB`. This preserves the preset's intended gain margin without allowing a media preset to mutate physical-system trim.

## Intentional production adaptations

- All factory EQ banks use the production linked/minimum-phase EQ model.
- Common transparent protection enables the DC-offset filter, 18 Hz infrasonic protection, and true-peak limiter with explicit preset values.
- Legacy automatic-headroom/oversampling flags are not blindly recreated where their historical semantics do not map one-to-one to the current graph. Preset gain margin is explicit instead.
- **Rock Arena** uses the final listening-approved revision: the 1.8 kHz presence lift is 1.2 dB, while the compressor and stereo widener remain off because listening tests found they reduced the desired raw/immediate guitar-and-vocal presentation.
- **Classic Pop/Rock** deliberately keeps compressor and stereo widening off. Its starting EQ is modest: +0.6 dB low shelf at 50 Hz, -0.5 dB at 220 Hz, +0.5 dB at 750 Hz, +0.9 dB at 2 kHz, -0.4 dB at 4.5 kHz, and +0.6 dB high shelf at 11 kHz. This aims to preserve vintage mix dynamics and image while improving body, clarity, and presence.
- **Vocal Standards** deliberately keeps compressor and stereo widening off, particularly because mono and early hard-panned stereo recordings are common in this material. Its starting EQ is +0.2 dB low shelf at 70 Hz, +0.5 dB at 150 Hz, -0.5 dB at 350 Hz, +0.9 dB at 1.7 kHz, -0.5 dB at 4 kHz, and +0.3 dB high shelf at 10.5 kHz.
- **Streaming** adapts the older approximately-uniform widening concept to the production widener's safe low-band contract: low width remains unity while mid/high width are 1.05, avoiding invalid low-band expansion.

## UI behavior

`ProductProfileController.contentPresets` is the single source of truth for factory and user Content Presets. Both the production Content Preset menu and the menu-bar/tray preset picker enumerate that collection, so all eight factory presets are available consistently in both surfaces without duplicate UI-specific preset lists.

## Validation

`ci/validate_pr44_factory_presets.py` permanently checks:

- all eight factory preset names exist;
- stable factory IDs remain present;
- the final Rock Arena contract is retained;
- Classic Pop/Rock and Vocal Standards retain their initial natural voicing contracts;
- factory Content Presets do not acquire Playback-System fields;
- content gain/headroom translation remains explicit;
- common protection choices remain explicit rather than relying on hidden defaults.

Before merge, the exact PR44 head must also pass the cumulative macOS build/test/realtime gates and packaged DMG gate. Final listening acceptance may tune factory voicings later, but such changes should remain Content-Preset-only unless the product ownership model is intentionally revised.
