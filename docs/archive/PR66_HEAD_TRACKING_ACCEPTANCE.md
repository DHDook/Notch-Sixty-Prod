# PR66 Head Tracking + Spatial Runtime Acceptance

PR66 activates the PR59 head-pose contract on top of PR65 Virtual Speakers. Automated CI proves the dual-generation renderer, control-plane integration, realtime constraints, persistence boundary, and arm64 build. The checks below require a real Mac and compatible motion-capable Apple headphones and are intentionally deferred to hands-on acceptance.

## Preconditions

- Use a clean PR66 build on Apple Silicon macOS 27 or newer.
- Keep a known-good PR65 build available for A/B regression.
- Import a normalized two-ear HRTF/BRIR profile at the active output sample rate.
- For multichannel checks, provide a decoded semantic PCM endpoint matching the selected Program Layout.
- Use supported Apple headphones that expose Core Motion headphone device motion for tracking checks.

## Static Virtual Speakers regression

1. Leave Head Tracking disabled.
2. Start Stereo Virtual Speakers and confirm playback matches PR65 behavior: stable image, no level jump, no clicks, no new underruns.
3. Repeat with 5.1, 7.1, and 7.1.4 decoded sources when available.
4. Confirm Acoustic Crossfeed remains bypassed in Virtual Speakers.
5. Confirm the final protection stage still prevents over-range output.

## Motion permission and availability

1. Enable Head Tracking and start Virtual Speakers for the first time.
2. Confirm macOS presents the Motion permission using Notch Sixty's motion-purpose string.
3. Grant permission and verify runtime status changes from Starting to Tracking after compatible headphone motion becomes available.
4. Deny permission and verify the configured default behavior is Static fallback, with uninterrupted static Virtual Speakers audio.
5. Disable static fallback, deny/unavailable motion, and confirm activation fails clearly rather than silently pretending to track.
6. Start with no compatible motion headphones connected and verify static fallback is stable.

## Recenter and pose behavior

1. Start tracking while facing the intended acoustic front.
2. Rotate yaw left/right by approximately 30–60 degrees. The virtual speaker scene should remain anchored in world space rather than following the head.
3. Exercise pitch and roll separately and confirm vertical/lateral cues change smoothly without channel swaps or discontinuities.
4. Press Recenter while facing a new forward direction. That pose should become the new neutral orientation without stopping audio.
5. Repeat recenter several times during continuous playback and verify no clicks, dropouts, or runaway gain.

## Semantic localization

1. Feed one semantic source at a time through Stereo, 5.1, 7.1, and 7.1.4 layouts as available.
2. Confirm front-left/right, center, side, rear, and height roles appear in the expected world-relative directions at the neutral pose.
3. Rotate the head and verify each active source remains world anchored.
4. Confirm LFE behavior remains consistent with the selected PR57 LFE mode and does not become an arbitrary directional speaker.

## Generation transitions

1. Use sparse impulses, pink-noise bursts, and steady music while moving the head slowly.
2. Verify HRTF generation swaps are inaudible as control events: no clicks, zipper noise, brief mute, or stereo image collapse.
3. Move the head rapidly for 20–30 seconds. Confirm rate limiting/hysteresis prevents unbounded preparation churn and audio remains continuous.
4. Verify status remains Tracking and renderer-generation telemetry advances rather than getting stuck busy.
5. Stop moving and confirm the scene settles promptly with no oscillation between neighboring HRTF measurements.

## Long BRIR / performance

1. Test representative short HRTF filters and the longest supported BRIR profile used in practice.
2. Run 7.1.4 content for at least 30 minutes with active tracking.
3. Record CPU use, capture/output callbacks, transport underruns/overruns, render failures, and output write failures.
4. Confirm no sustained memory growth and no audio-thread stalls while new generations are prepared off-thread.
5. Confirm motion updates do not cause UI lag or excessive energy impact compared with static Virtual Speakers.

## Disconnect, sleep, and recovery

1. Disconnect compatible motion headphones during active tracking. Audio should either continue through the selected headphone output with static fallback or follow the normal output-recovery path; it must not dereference a destroyed spatial runtime.
2. Reconnect the motion-capable headphones and restart processing; tracking should become available again.
3. Disconnect/reconnect the decoded program-source endpoint during active multichannel Virtual Speakers and confirm the existing recovery path behaves correctly.
4. Sleep and wake the Mac during active tracking. Confirm the tracking controller is stopped before transport teardown and rebuilt cleanly on restart.
5. Change output sample rate while stopped and verify HRTF/BRIR native-rate validation still fails closed when the asset does not match.

## Product UI / persistence

1. Save a Playback System with Head Tracking enabled, static fallback enabled, and a selected HRTF/BRIR asset.
2. Relaunch and confirm the optional tracking policy restores without changing Content Presets.
3. Load a PR65-era Playback System archive that has no head-tracking key. It must decode successfully with tracking disabled.
4. Confirm runtime status is visible in the Headphones workspace and Recenter is enabled only while actively tracking.
5. Switch to Stereo headphone mode and confirm head tracking is rejected/disabled because tracking applies only to Virtual Speakers.

## Pass criteria

- No realtime allocations, blocking locks, logging, file I/O, HRTF lookup, or kernel preparation in Core Audio callbacks.
- No audible clicks or dropouts during normal generation swaps or recentering.
- Static Virtual Speakers remains a reliable fallback.
- World-anchored localization behaves plausibly for all tested semantic roles.
- No regression to PR65 stereo-headphone or static-binaural behavior.
- No new persistent underrun/overrun or memory-growth issue under sustained tracking.
