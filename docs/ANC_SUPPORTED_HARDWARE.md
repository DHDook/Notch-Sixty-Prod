# Speaker ANC: supported hardware

The output interfaces and reference microphones that have been bench-tested for speaker ANC
(Quiet Zone), with their measured round trip. The app carries the same table in
`NotchSixty/Audio/ANCSupportedHardware.swift`; keep the two in step.

Round-trip latency decides whether feed-forward cancellation is possible at all
(`docs/ANC_QUALIFICATION.md` §1). It depends on the output interface, the microphone interface,
the sample rate and the output buffer size. Quiet Zone switches the output to its lowest-latency
buffer while it is enabled (E4 S7), so entries record the buffer size actually used.

Hardware not in this table shows "Not yet measured" in the app. A round trip measured on the
user's own Mac (PR97 physical latency run) is shown as "measured on this Mac" and is not a
qualification.

## Tested

None yet. The E4 S8 bench campaign fills this table.

| Output interface | Reference microphone | Rate (Hz) | Buffer (frames) | Round trip (ms) | Upper bound (ms) | Measured | Notes |
|---|---|---|---|---|---|---|---|

## How to add an entry

1. Run the PR97 timing calibration on the interface (`docs/epics/E4.md`, S8 bench checks), with
   Quiet Zone enabled so the low-latency buffer is in use.
2. Record the physical latency report's nominal path and upper bound, the device UIDs, rate and
   buffer size.
3. Add a row here and the matching `ANCSupportedHardware.tested` entry in the same PR.
