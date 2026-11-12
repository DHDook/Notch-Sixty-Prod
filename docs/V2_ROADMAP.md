# Notch Sixty — v2 Roadmap (after v1)

Written 11 Nov 2026 from the roadmap review and the post-v1 notes already in the v1 plan.
**Status: not started.** Nothing here is part of the v1 completion requirement, and `/next` does
not read this file. The owner initiates it after v1 ships (see "How to start").

The v1 plan is `docs/PROGRAM_PLAN.md`. Epics here are numbered `V2-n` so they never collide with
the v1 `E<n>` numbers; each gets a real epic number and a `docs/epics/` file when it is started.

## What v1 leaves out, and why

v1 is a sandboxed Mac App Store app that processes system audio through a process tap. Four
constraints follow from that, and most of v2 is what becomes possible when one is relaxed:

| Constraint in v1 | Relaxed by |
| --- | --- |
| App Store sandbox, no audio driver | V2-1 |
| System audio is the only source | V2-2, V2-3 |
| macOS only | V2-4, V2-5, V2-14 |
| No licensed decoders or data | V2-6, V2-7, V2-8 |

The remaining epics (V2-9 to V2-13, V2-15) are features that were deferred for priority only.

## Epics at a glance

| ID | Epic | Size | Depends on | Owner decision needed before planning |
| --- | --- | --- | --- | --- |
| V2-1 | Direct-download edition with a virtual audio device | Large | v1 | Yes: changes `AGENTS.md` sections 2 and 6 (drivers, sandbox) |
| V2-2 | Input and preamp mode | Medium | v1 | No |
| V2-3 | Network endpoint | Medium to large | V2-2 | Yes for anything needing certification |
| V2-4 | iPhone and iPad companion | Large | E16 local API | No (already agreed as post-v1) |
| V2-5 | Headless endpoint on the portable core | Large | E21 | Yes: UI shell and distribution |
| V2-6 | Licensed immersive decoding | Large | E14, V2-9 | Yes: licence and product decision |
| V2-7 | Built-in headphone and speaker data | Medium | E13 | Yes: licence |
| V2-8 | Personal HRTF and hearing profile | Medium | E13, V2-4 | Yes if a partner or licence is used |
| V2-9 | Upmixer modes and tuning | Small to medium | E14 | No |
| V2-10 | Quiet Zone on any output count | Large | E26, E19 | Yes: written MIMO authorisation |
| V2-11 | Headphone listening dose | Small | E13 | No |
| V2-12 | Plug-in edition of room correction | Medium | E21, E10 | Yes: second product and price |
| V2-13 | Virtual bass for small speakers | Small to medium | E6 | Yes: is an effect in scope? |
| V2-14 | Windows edition | Very large | E21, V2-5 | Yes: driver, installer, UI shell |
| V2-15 | Community sharing | Medium | E18 iCloud sync | Yes: first network feature, moderation |

Sizes are rough: small is one or two slices, medium three to six, large more than six.

## Suggested order

Three waves. The order inside a wave is by value for effort; the owner can reorder freely because
only the listed dependencies are hard.

1. **First update (no policy change, builds on v1 directly):** V2-9, V2-11, V2-2, V2-10.
2. **Reach (new surfaces for the same engine):** V2-4, V2-1, V2-3, V2-12.
3. **Platforms and licences:** V2-5, V2-7, V2-8, V2-6, V2-13, V2-14, V2-15.

If only one item is pulled forward, V2-2 is the recommended one: it is the main thing a hardware
DSP box offers that v1 does not, and it needs no sandbox change.

## Epics

Each epic lists scope and the questions epic-planner must settle. The standing rules carry over
unchanged: realtime rules, every device rate up to 384 kHz, no GPL, clean-room, feature flag per
epic, live ANC and MIMO only through `LiveTreatmentArm` and written authorisation.

### V2-1 Direct-download edition with a virtual audio device

Notch Sixty appears as an output device. Apps play into it directly, so the source rate is known,
unprocessed audio cannot reach an active speaker when the app is the chosen device, and per-app
routing becomes simple. This is the largest single unlock.

- [ ] Owner decision first: `AGENTS.md` section 2 lists installing audio drivers as out of scope and section 6 requires the sandbox. The App Store edition stays as it is; the virtual device is an optional component of a separate direct-download build
- [ ] User-space audio driver (no kernel extension), signed and notarised, with install, update and removal paths
- [ ] Transport: the virtual device as a second input path beside the process tap, behind the same realtime bridge
- [ ] Source-rate following, building on the E15 S5 finding
- [ ] Active-speaker safety, building on the E9 S9 finding
- [ ] Direct-download licensing and updates (the App Store build keeps no self-updater)

### V2-2 Input and preamp mode

Process a physical input: a turntable through an ADC, a TV through an HDMI or optical interface.
This lets the Mac replace a hardware DSP box in a living-room system.

- [ ] Choose a physical input device and channels as the program source instead of, or mixed with, system audio
- [ ] Clock handling between input and output devices (aggregate drift correction or explicit SRC, an explicit product decision under `AGENTS.md` section 3)
- [ ] Input level, clip indication and source switching on the Dashboard and menu bar
- [ ] Low-latency path for TV use, with A/V sync
- [ ] Tests at the eight rates; bench: lip sync and long-run drift

### V2-3 Network endpoint

Receive audio from other players.

- [ ] An open UPnP/DLNA renderer first (no certification needed); licence review of any library
- [ ] Roon Ready and AirPlay receiving only after an owner decision on certification and licence
- [ ] Gapless playback, rate changes between tracks, and volume control from the sender

### V2-4 iPhone and iPad companion (owner, 11 Nov 2026)

- [ ] Remote for the Mac app using the E16 local API: profile, volume, bypass, Quiet Zone session (subject to the arm), blind comparison from the seat
- [ ] iPhone as a measurement microphone: needs its own calibration and accuracy design first (per-model microphone response, timing against the Mac's clock, and the limits under which a phone capture is trusted) before any design path uses it
- [ ] Pairing, discovery and App Store distribution for the iOS app

### V2-5 Headless endpoint on the portable core

- [ ] Run a finished configuration on a Mac mini without a display
- [ ] Linux build on PipeWire (virtual sink or filter chain, no root), using the E21 core
- [ ] Configuration by exported project file and by the local API; the UI-shell decision for non-Apple platforms is made here
- [ ] This is the route to a hardware partnership; decide the distribution model first

### V2-6 Licensed immersive decoding

- [ ] First check what the tap already receives from Apple's own Atmos rendering on a multichannel device; that may be enough
- [ ] If not: Dolby Atmos and DTS:X decoding to the user's layout, which needs a licence and a product decision (`AGENTS.md` section 2)

### V2-7 Built-in headphone and speaker data

- [ ] A licensed headphone correction database, so correction starts from the product model (v1 is bring-your-own)
- [ ] Published speaker measurements as starting points for speaker correction
- [ ] Provenance and licence entries for every data source

### V2-8 Personal HRTF and hearing profile

- [ ] A personal HRTF from a phone scan, built or through a partner
- [ ] Optional compensation from an imported audiogram, with clear limits on what it claims

### V2-9 Upmixer modes and tuning (owner, 11 Nov 2026)

v1 (E14) ships one upmix with a single strength control.

- [ ] Several upmix modes (for example music, film, wide)
- [ ] Per-layout presets
- [ ] Tuning controls: centre width, surround level, height level, decorrelation

### V2-10 Quiet Zone on any output count

The placeholder is E26 S8 `e26/multichannel-actuators` in `docs/epics/E26.md` (owner, 6 Nov 2026),
which lists the first items and says it splits into three or four slices.

- [ ] Written MIMO authorisation from the owner before any live treatment on more than two mains plus one sub
- [ ] One drive per output, with the plant conditioning and stability checks listed in E26 S8
- [ ] Closes E26 G18 (two subs, 5.1 and wider layouts keep a refusal in v1)

### V2-11 Headphone listening dose

- [ ] Estimate level at the ear from the signal and the headphone's sensitivity (entered by the user)
- [ ] Show exposure over the day and week, labelled as an estimate

### V2-12 Plug-in edition of room correction

- [ ] An Audio Unit of the correction stage for use inside players and DAWs, loading a correction designed in the app

### V2-13 Virtual bass for small speakers

- [ ] Psychoacoustic bass extension below a small speaker's range. Borderline with "effects", so the owner decides scope first

### V2-14 Windows edition

- [ ] Needs a signed virtual audio driver or an APO (loopback capture cannot intercept the default output), an installer and a UI shell
- [ ] Only after the portable core (E21) and the headless endpoint (V2-5) are complete

### V2-15 Community sharing

- [ ] Share and browse profiles, targets and speaker presets. The first network feature: needs privacy, moderation and App Review decisions

## Items that may move here from v1

- E11 S12 verification with music, if the E4 path tracking cannot be reused and the owner moves it.
- Review item E31 (signal-path and history view) and cut candidates C1–C10 are undecided; they stay
  where they are until the owner decides.

## How to start

1. The owner says which epic to start (or the whole first wave).
2. Record the decision in `docs/PROGRAM_PLAN.md` "Decisions taken", give the epic the next free
   `E<n>` number, and add it to the execution order.
3. Settle the "owner decision needed" column for that epic before planning.
4. `/next E<n>` then runs epic-planner, which writes `docs/epics/E<n>.md` for approval as usual.
