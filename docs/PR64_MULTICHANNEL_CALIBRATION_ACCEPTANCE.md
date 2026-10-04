# PR64 Multichannel Calibration — Deferred Hardware Acceptance

PR64 is intentionally stackable before real-Mac hardware acceptance. Automated CI proves bounded data models, routing/calibration ownership, targeted measurement transport compilation, design/deployment wiring, and the arm64 application build. The following checks should be run on a physical Mac before this PR is merged into the release train.

## Baseline / fallback

- Confirm an existing stereo Playback System with no enabled Output Device Profile behaves exactly as before.
- Confirm an enabled semantic Output Device Profile activates the PR63 N-channel transport only when its routing is valid.
- Confirm disabling the semantic profile returns to the legacy stereo path after stop/restart.

## Speaker-identification safety

For each configured semantic speaker and physical Sub N:

- Stop normal DSP playback before beginning calibration.
- Select the measurement microphone and physical microphone input channel.
- Start the Speaker Calibration campaign.
- Confirm the UI names the expected seat and acoustic source.
- Confirm only the intended physical output emits the sweep.
- Confirm every non-target output remains silent for the full sweep, including native LFE and every other subwoofer.
- Cancel a sweep mid-pass and confirm all outputs return to silence.

## Multi-device / aggregate behavior

When the Output Device Profile spans multiple Core Audio devices:

- Confirm the profile's deterministic device order is preserved.
- Confirm the reference output remains the aggregate clock leader.
- Confirm non-reference devices and a separate microphone use drift compensation.
- Confirm temporary sample-rate changes are restored after completion, cancellation, and error paths.
- Disconnect a required device before a sweep and confirm calibration fails closed without energizing another channel.

## Source × seat campaign

- Exercise 1-seat and multi-seat projects.
- Verify include/exclude and seat-weight controls.
- Quit/relaunch mid-campaign and confirm analyzed measurements resume from the first missing target.
- Change physical routing after measurements exist and confirm the campaign is rejected as stale rather than reused against a different acoustic source.
- Confirm semantic LFE is never offered as a physical measurement target; physical Sub 1…N are measured independently.

## Design / deployment

- Generate a speaker correction design and inspect before/after error telemetry.
- With multiple subs, confirm the optimizer operates over the low-frequency measurement domain and reports an objective.
- Confirm deployed speaker trim and PEQ contain no positive digital gain.
- Confirm deployed physical-sub gain and PEQ contain no positive digital gain.
- Confirm each speaker's trim, polarity, delay, and PEQ reach only that semantic lane.
- Confirm each physical sub's gain, polarity, delay, and user EQ reach only that Sub N output.
- Confirm native LFE content remains distinct from redirected bass after deployment.

## Recovery

- Stop/start after deployment and confirm calibration persists with the Playback System.
- Change output sample rate and confirm a calibration designed at a different rate fails closed rather than silently reusing incompatible timing/EQ.
- Sleep/wake and device disconnect/reconnect should preserve the normal PR63 recovery guarantees.

Hardware acceptance can be completed branch-by-branch later. PR64 must remain a draft and must not be merged solely on the basis of automated CI.
