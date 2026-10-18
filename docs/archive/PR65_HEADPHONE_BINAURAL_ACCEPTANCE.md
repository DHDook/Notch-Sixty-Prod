# PR65 Headphone + Binaural — Deferred Hardware Acceptance

PR65 is intentionally stackable before real-Mac listening acceptance. Automated CI proves the persistent Headphone Device Profile model, stopped-only realtime preparation, stereo headphone insertion point, semantic multichannel capture contract, binaural/headphone/protection composition, product UI wiring, and the arm64 application build. Complete the following checks on physical hardware before merging this PR into the release train.

## Baseline / speaker regression

- Confirm an existing Playback System with no enabled Headphone Device Profile behaves exactly as the PR64 branch.
- Confirm stereo speaker playback, EQ, Dynamics, meters, Room Correction, speaker calibration, active crossover and Stop/Start remain unchanged.
- Confirm enabling a Headphone Device Profile is mutually exclusive with active speaker Output Device Profile / legacy physical speaker routing as designed.
- Confirm disabling the Headphone Device Profile and restarting returns to the prior speaker/stereo path.

## Stereo headphone mode

- Select a true two-channel headphone DAC/output and enable a Headphone Device Profile in Stereo mode.
- Confirm ordinary stereo playback preserves the normal Content Preset EQ/dynamics/FIR chain.
- Verify independent Left/Right trim, polarity and fine delay affect only the intended ear.
- Load representative correction PEQ on each ear and verify channel isolation.
- Verify configured correction headroom prevents profiles whose conservative positive correction exceeds available headroom.
- Exercise Gentle, Standard and Wide Speakers crossfeed presets with mono, hard-panned and centered material.
- Confirm crossfeed primarily affects the intended lower-frequency contralateral path and does not collapse high-frequency stereo image.
- Confirm the final protection/true-peak limiter remains downstream of headphone correction by exercising deliberately hot but safe test material.

## Virtual Speakers — stereo source

- Select Virtual Speakers with the headphone endpoint also used as program source and a stereo program layout.
- Import a valid normalized two-ear HRTF/BRIR profile whose sample rate matches the headphone output.
- Confirm left/right virtual source placement is stable and not reversed.
- Confirm acoustic crossfeed controls are disabled/bypassed while Virtual Speakers is active.
- Confirm reported/observed latency includes the fixed binaural partition latency plus profile-declared/protection latency.

## Virtual Speakers — multichannel source

With a decoded multichannel Core Audio endpoint available:

- Select that endpoint as **Decoded Program Source** while retaining the stereo headphone DAC as output.
- Exercise 5.1 first, then 7.1 / 5.1.4 / 7.1.4 where the source exposes the required semantic channels.
- Confirm the program tap preserves the decoded channel count rather than receiving an upstream stereo mixdown.
- Verify each semantic source role appears from the expected virtual direction using isolated channel-identification material.
- Confirm native LFE is rendered using the profile's equal-ear LFE policy and is not treated as a physical subwoofer destination.
- Confirm the session rejects a source whose physical channel count does not match the selected program layout.
- Confirm ambiguous or unsupported multichannel channel metadata fails closed rather than guessing channel order.

## Spatial profile assets

- Import a valid Notch Sixty normalized HRTF profile and a normalized BRIR profile.
- Confirm the imported asset persists in the app sandbox and remains selectable after relaunch.
- Confirm a profile with invalid/non-finite IR data is rejected.
- Confirm a profile whose sample rate does not match the native output rate is rejected; no hidden SRC should occur.
- Confirm an ordinary `.sofa` file produces the explicit native-SOFA-parser-unavailable message rather than being mislabeled as imported.
- When native AES69/SOFA import is added later, review its parser/dependency licensing and sandbox behavior separately rather than changing the realtime renderer contract.

## Output / source lifecycle

- Disconnect the physical headphone output while running and confirm the normal selected-output recovery policy is preserved.
- Reconnect the same stable output UID and confirm recovery resumes only that device.
- For a separate multichannel program source, disconnect/reconnect that source and confirm Virtual Speakers fails closed/retries without silently switching source.
- Change the physical headphone output sample rate while idle and confirm the profile is revalidated at the new native rate.
- Create a source/output native-rate mismatch and confirm activation fails explicitly rather than inserting SRC.
- Exercise Stop/Start repeatedly, sleep/wake, normal Quit and device recovery.

## Headroom / protection / performance

- Use hot full-scale stereo and multichannel material to confirm no unexpected clipping occurs after binaural summation or headphone correction.
- Inspect limiter gain reduction and listen for pumping/instability under worst-case spatial summation.
- Test representative 44.1, 48 and 96 kHz operation, plus higher native device rates where practical.
- Test short HRTFs and long BRIRs up to the supported 8,192 taps/source/ear and note CPU usage, latency and dropout behavior.
- Verify no click/pop occurs at startup gating or normal Stop.
- Confirm long-running playback does not leak transport, renderer or asset-store resources.

## Product UX

- Confirm **Headphones** appears in the production sidebar.
- Confirm the selected Playback System owns the Headphone Device Profile; switching Content Presets must not alter headphone hardware correction or spatial source mapping.
- Confirm Apply/Revert behavior is deterministic while processing is stopped.
- Confirm the UI clearly distinguishes the physical headphone output from the optional decoded multichannel program source.
- Confirm Virtual Speakers explains the normalized HRTF/BRIR boundary and does not claim native `.sofa` support.

Hardware acceptance can be completed branch-by-branch later. PR65 should remain draft and unmerged until these checks are performed or explicitly waived for a later acceptance stage.
