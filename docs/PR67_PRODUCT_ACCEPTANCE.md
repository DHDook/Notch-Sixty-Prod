# PR67 Product Hardening Acceptance

PR67 closes the integration train with product-facing diagnostics, persistence hardening, and explicit end-to-end acceptance gates. Automated CI validates structure, realtime safety, portable metering primitives, inherited spatial behavior, and an arm64 macOS build. The checks below remain hands-on acceptance on representative hardware.

## 1. Legacy stereo regression

- Start with no enabled Output Device Profile and no enabled Headphone Device Profile.
- Confirm the shipping stereo path starts, stops, fades, changes gain, and survives repeated processing restarts exactly as before.
- Open Levels and verify the existing stereo input/output meters update normally.
- Leave Levels and verify detailed meter demand parks again; compare CPU with the page visible and hidden.
- Confirm EQ, room correction, FIR, dynamics, protection, analysis, presets, and master-volume behavior remain unchanged.

## 2. Semantic speaker layouts

Repeat with representative Output Device Profiles for 5.1, 7.1, and 7.1.4.

- Confirm Start activates the semantic N-channel path only when the selected hardware/profile mapping is valid.
- Verify every semantic Program Channel meter has the expected role and follows only that source channel.
- Verify Physical Outputs match the configured hardware channel numbers.
- Verify disabled/unmapped hardware channels remain silent.
- Confirm per-channel gain, mute, polarity, delay, PEQ, FIR, group edits, and latency alignment remain isolated to the intended channels.
- Confirm startup gate/fade is click-free and the Transport page reports the active semantic path.

## 3. Bass management and physical subs

- Exercise redirected low-frequency content from at least Front Left and Center.
- Exercise native LFE independently.
- Verify redirected bass and native LFE remain distinct upstream of the physical sub route.
- Verify Physical Outputs identifies each configured sub as `Sub N`; do not treat a physical subwoofer output as the semantic LFE program lane.
- Verify per-sub gain, polarity, delay, EQ, subsonic/phase treatment, and protection still operate.
- With multiple subs, verify each Sub N meter follows its configured physical output independently.

## 4. Headphone stereo and Virtual Speakers

- With Stereo headphone mode, verify PR56 correction/crossfeed remains unchanged.
- With Virtual Speakers, test stereo, 5.1, 7.1, and 7.1.4 decoded program layouts.
- Verify the Levels page reports final Left/Right headphone output and the spatial protection input/output true-peak values.
- Verify reported latency is stable and includes binaural rendering, configured L/R correction delay, and protection look-ahead.
- Run the PR66 head-tracking checklist for supported Apple motion-capable headphones, including Recenter and static-spatial fallback.
- Confirm switching between speaker and headphone Playback Systems never carries physical speaker calibration into the headphone device domain or vice versa.

## 5. Meter demand and realtime behavior

For stereo, semantic speakers, and Virtual Speakers:

- Compare CPU with Levels hidden versus visible; detailed meter arithmetic should be absent when hidden.
- Run sustained playback while opening/closing Levels repeatedly. There must be no click, dropout, graph rebuild, or transport restart solely because metering demand changed.
- Confirm meter values remain finite and return to zero after disabling demand/reset.
- Drive a controlled over-range test and verify over-range counters advance only on the affected channels.
- Confirm no callback allocation, blocking lock, logging, file I/O, HRTF lookup, or graph construction appears in Instruments/Time Profiler traces.

## 6. Transport, latency, and failure telemetry

- Confirm the Transport page identifies the current Stereo, Semantic Speakers, or Virtual Speakers path correctly.
- Verify displayed sample rate matches Audio MIDI / the active native-rate transport.
- Verify published latency changes when known delay/look-ahead settings change and remains stable during steady-state playback.
- Verify buffered-frame, underrun, overrun, render-failure, output-write-failure, and startup-gate state are plausible under normal playback.
- Intentionally force a recoverable output interruption and verify diagnostics surface the event without replacing the chosen hardware silently.

## 7. Selected-device recovery

- Start processing on a specifically selected device by stable UID.
- Disconnect that device while another macOS output is available.
- Confirm Notch Sixty enters recovery/failure handling rather than silently following the macOS default device.
- Reconnect the same selected device and verify recovery attempts/success telemetry and normal audio restoration.
- Repeat through sample-rate change, sleep/wake, and rapid stop/start sequences.
- Confirm speaker and Virtual Speakers source/output device disappearance is handled without dereferencing a destroyed transport or head-tracking controller.

## 8. Playback System persistence and migration

- Save and reload representative stereo, 7.1.4 speaker, headphone-stereo, and Virtual Speakers Playback Systems.
- Quit/relaunch and verify selected device UID, semantic layout, physical mapping, per-speaker calibration, bass-management/sub routing, headphone correction, spatial asset reference, and head-tracking policy restore correctly.
- Confirm valid PR65/PR66-era archives load without a schema migration or destructive rewrite.
- Construct test archives with contradictory enabled hardware domains (legacy multi-output + semantic speakers, legacy multi-output + headphones, or semantic speakers + headphones) and verify they are rejected rather than becoming selectable broken systems.
- Verify an enabled Virtual Speakers profile without a valid spatial asset reference is rejected.
- Verify enabled head tracking on a non-Virtual-Speakers profile is rejected.
- Verify user Content Presets remain independent of Playback System hardware/calibration state.

## 9. Long-run stability

Run at least one extended session for stereo, a representative multichannel speaker profile, and Virtual Speakers.

- Observe CPU, memory, underrun/overrun counters, render/output failures, and latency.
- Exercise long BRIR/FIR material at the highest intended sample rate.
- Open/close metering and analysis views periodically.
- Switch Content Presets without altering Device Profile routing/calibration.
- There must be no progressive memory growth, callback starvation, meter-induced instability, or loss of selected-device recovery.

## 10. App sandbox / release behavior

- Verify normalized HRTF/BRIR and other sandbox-owned assets persist and reload under the release sandbox.
- Verify import/export paths still use user-authorized file access.
- Confirm no new hidden dependency, helper process, or network requirement was introduced by PR67.
- Confirm the generated app still carries the PR66 motion privacy description where Core Motion head tracking is available.

## Explicitly deferred

- MIMO correction remains experimental and is not enabled by PR67.
- Native AES69 SOFA/HDF5 parsing remains deferred; the normalized two-ear asset boundary remains the supported renderer input.
- Proprietary Dolby Atmos decoding is not introduced; multichannel rendering consumes already-decoded PCM.
