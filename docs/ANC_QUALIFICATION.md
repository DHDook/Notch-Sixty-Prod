# Speaker ANC (Quiet Zone) qualification

**Status:** proposed targets, 18 Oct 2026 (E4 S2). The owner sets the final numbers when this
document is reviewed; until then every figure here is a proposal. Live ANC stays off until a
record meets every criterion below and the owner signs it off (E4 S10).

This document defines what "qualified" means for Quiet Zone: the physical envelope it works
in, the targets it must meet at the listening position, how they are measured, and the evidence
the app requires before it will play anti-noise into the room.

## 1. Physical envelope

Quiet Zone cancels noise by playing an inverted copy of it through the speakers. What it can
cancel is set by physics, not by tuning.

- **Broadband feed-forward needs a head start.** A reference microphone near the noise source
  must hear each sound before it reaches the listener by more than the whole system's latency
  (reference input, processing, output, and the speaker-to-seat flight time). If the noise
  arrives first, the anti-noise is late and cannot cancel it. The app measures this budget
  (`QuietZonePhysicalLatencyBudget`) and refuses broadband feed-forward when the lead is too
  short.
- **Steady tones and periodic noise use the tonal canceller.** Fans, pumps, transformers and
  other stable sources in 20–150 Hz repeat, so their next cycle can be predicted and cancelled
  without a head start (up to 4 tones; `N60ActiveQuietZone`).
- **Low frequencies only.** Cancellation needs the anti-noise to match the noise in phase over
  the listener's head. Below about 150 Hz the wavelength (over 2 m) is long enough for a useful
  zone; above about 500 Hz the zone shrinks to a few centimetres and cancellation is not
  attempted.
- **Not cancelled:** speech, random nearby noises, and anything arriving at the listener before
  the reference microphone hears it.

## 2. Targets

All reductions are ANC-on versus ANC-off at the same position, same source, same rig, measured
with the independent measurement microphone (not the error microphone).

| Area | Target (proposed) |
| --- | --- |
| Primary seat, tonal | ≥ 15 dB reduction of each tracked tone, 20–150 Hz, held for 10 minutes with a person moving within the zone |
| Primary seat, broadband feed-forward | ≥ 6 dB in each third-octave band 31.5–125 Hz, when the reference leads by at least the measured latency upper bound plus 1 ms |
| Quiet-zone size | ≥ 10 dB tonal reduction at six points on a 15 cm-radius sphere around the head position (±x, ±y, ±z) |
| Other seats | No third-octave band 20–500 Hz louder by more than 1 dB at any measured seat |
| Waterbed at the primary seat | No third-octave band above 150 Hz louder by more than 0.5 dB |
| Repeatability | Primary-seat reduction repeats within 1.5 dB across the A→B→A visits; ANC-off baselines within 1.5 dB (today's PR99 limits) |
| Drift | Tonal target still met after a 3 °C room temperature change without re-measuring (needs adaptive control, E4 S5–S6) |

## 3. Safety criteria

| Check | Target (proposed) |
| --- | --- |
| Howl / instability detection | Trips within 50 ms of an injected growing loop at every standard rate (44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384 kHz), then ramps ANC output to zero within 10 ms and stays muted until re-armed |
| False trips | Zero trips in a 1-hour soak with music, programme transients and a stable tone |
| Output level | Existing caps hold: −24 dBFS per tone, −18 dBFS aggregate; feed-forward combined stereo peak ≤ 0.10 |
| Fault shutdown | Every PR99 fault probe reports shutdown within its limit |
| Emergency analog mute | Verified on the bench: the physical mute silences the amplifier path with the app running |

## 4. Measurement method

1. **Rig.** One calibrated measurement microphone (its calibration file recorded), one DAC and
   sample clock, unchanged for the whole campaign. The rig identity is part of the evidence;
   any change restarts the campaign.
2. **Timing (PR97).** Capture a qualified two-second HAL clock trace, then measure the physical
   round-trip latency at least 3 times (`QuietZonePhysicalLatencyMeasurementRun`), each no more
   than 6 minutes old when the budget is assessed. Record nominal, upper-bound and jitter.
3. **Verification campaign (PR99).** Three visits in order: primary seat (A), a neighbouring
   seat (B), primary seat again (A), within 30 minutes, with the microphone returned to the same
   point. At each visit take ANC-off and ANC-on captures of the same controlled source and run
   the fault probes.
4. **Zone and seats.** Add the six quiet-zone points and every other listening seat in the room,
   each with ANC-off and ANC-on captures.
5. **Rates.** Run steps 2–4 at 48 kHz and at the highest rate the interface offers; run the
   safety checks at all eight standard rates.
6. **Analysis.** Third-octave bands 20 Hz–1 kHz, 10-second averages per capture, tones measured
   by narrowband level at the tracked frequency. Report each target as pass or fail with the
   measured value.
7. **Publishing.** For reviewers: room dimensions, rig, positions (diagram), noise source,
   per-band results, and this method. Raw captures stay available on request.

## 5. Authorisation criteria

`LiveANCAuthorisation` (E4 S3) is the only code that can decide live ANC is qualified. It governs broadband feed-forward and adaptive output. The fixed tonal canceller stays live
within its existing level caps and error-microphone fault fade (owner, 18 Oct 2026). It
returns "authorised" only when one evidence record contains all of:

- [ ] PR97 timing qualified for this interface
- [ ] Latency budget met: conservative reserve ≥ required safety reserve, at this rate
- [ ] PR99 campaign passed, and every target in section 2 met
- [ ] Howl detector qualified (section 3) at this rate
- [ ] Emergency analog mute verified on the bench
- [ ] Owner sign-off recorded, with date

The record is bound to one output device UID, one interface (reference and error microphone
inputs) and one sample rate. A different device, interface or rate is not authorised until it
has its own record. Any rig change, or evidence older than the campaign limits, invalidates the
record.

## 6. Fallback (open question)

If qualification stalls, the proposed answer is that v1 ships Quiet Zone with live output off:
the measurement, design and shadow-mode tools stay available, and live ANC follows in an update
once a record passes. The owner decides (see "Open questions" in `docs/PROGRAM_PLAN.md`).
