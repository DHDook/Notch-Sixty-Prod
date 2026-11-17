# Notch Sixty — v2 and v3 Roadmap (after v1)

Written 11 Nov 2026 from the roadmap review and the post-v1 notes already in the v1 plan.
**Status: not started.** Nothing here is part of the v1 completion requirement, and `/next` does
not read this file. The owner initiates it after v1 ships (see "How to start").

The v1 plan is `docs/PROGRAM_PLAN.md`. Epics here are numbered `V2-n` so they never collide with
the v1 `E<n>` numbers; each gets a real epic number and a `docs/epics/` file when it is started.

## Versions and pricing (owner, 17 Nov 2026)

- **v1 is the core app**, **v2 expands its functionality on the Mac**, and **v3 takes it to other
  platforms** (section "v3: other platforms" below; epics `V3-n`).
- Only platform editions are charged separately. v2 is a free update for v1 owners, and every Mac
  feature, the virtual audio driver (V2-1) included, comes with the one Mac purchase. A feature that
  carries a per-copy licence fee (for example V2-6) needs its price checked before it is planned.
- v3 starts after v2; the owner initiates it the same way (see "How to start").

## What v1 leaves out, and why

v1 is a sandboxed Mac App Store app that processes system audio through a process tap. Four
constraints follow from that, and most of v2 is what becomes possible when one is relaxed:

| Constraint in v1 | Relaxed by |
| --- | --- |
| App Store sandbox, no audio driver | V2-1 |
| System audio is the only source | V2-2, V2-3 |
| macOS only | V2-4 (iPhone and iPad companion for the Mac app); other platforms are v3 (V3-1 to V3-3) |
| No licensed decoders or data | V2-6, V2-7, V2-8 |

The other epics (V2-9 to V2-11, V2-13 and V2-15 to V2-24) are features left out of v1 for priority or scope; the last column of the table below says which need an owner decision first.

## Epics at a glance

| ID | Epic | Size | Depends on | Owner decision needed before planning |
| --- | --- | --- | --- | --- |
| V2-1 | Optional virtual audio driver add-on | Large | v1 | Yes: changes `AGENTS.md` sections 2 and 6 (drivers), and the App Store question |
| V2-2 | Input and preamp mode | Medium | v1 | No |
| V2-3 | Network endpoint | Medium to large | V2-2 | Yes for anything needing certification |
| V2-4 | iPhone and iPad companion | Large | E16 local API | No (already agreed as post-v1) |
| V2-5 | Moved to v3 as V3-2 (owner, 17 Nov 2026) | | | |
| V2-6 | Licensed immersive decoding | Large | E14, V2-9 | Yes: licence and product decision |
| V2-7 | Built-in headphone and speaker data | Medium | E13 | Yes: licence |
| V2-8 | Personal HRTF and hearing profile | Medium | E13, V2-4 | Yes if a partner or licence is used |
| V2-9 | Upmixer modes and tuning | Small to medium | E14 | No |
| V2-10 | Quiet Zone on any output count | Large | E26, E19 | Yes: written MIMO authorisation |
| V2-11 | Headphone listening dose | Small | E13 | No |
| V2-12 | Parked: see "Conditional and undecided items" (owner, 17 Nov 2026) | | | |
| V2-13 | Virtual bass for small speakers | Small to medium | E6 | Yes: is an effect in scope? |
| V2-14 | Moved to v3 as V3-1 (owner, 17 Nov 2026) | | | |
| V2-15 | Community sharing | Medium | E18 iCloud sync | Yes: first network feature, moderation |
| V2-16 | Verification with music | Small to medium | E11, E4 path tracking | No |
| V2-17 | Speaker and room health check | Small | E11, V2-16 | No |
| V2-18 | Selective restore from a backup | Small | E12 S25 | No |
| V2-19 | Rates above 384 kHz | Small to medium | E7 | Yes: changes the `AGENTS.md` section 8 rate list |
| V2-20 | Second zone | Medium to large | E8 | Yes: changes the one-selected-output rule in `AGENTS.md` section 3 |
| V2-21 | Speaker remapping and reflection control | Large | E6, E10, E14, E19 | Yes: needs a multi-capsule microphone |
| V2-22 | Dialogue separation | Medium to large | E14, E21, E33 S13 | Yes: which option after the investigation, and the training-data licence |
| V2-23 | Per-band EQ placement and linear-phase multiband | Small to medium | E33 (S5b, S20, S27) | No |
| V2-24 | Languages | Medium | v1 | Yes: which languages, and who translates |

Sizes are rough: small is one or two slices, medium three to six, large more than six.

## Suggested order

Three waves. The order inside a wave is by value for effort; the owner can reorder freely because
only the listed dependencies are hard.

1. **First update (no policy change, builds on v1 directly):** V2-9, V2-11, V2-16, V2-17, V2-18, V2-23, V2-2, V2-10.
2. **Reach (new surfaces and markets for the same engine):** V2-4, V2-1, V2-3, V2-20, V2-24.
3. **Platforms, licences and larger features:** V2-7, V2-8, V2-6, V2-13, V2-19, V2-21, V2-22, V2-15.

If only one item is pulled forward, V2-2 is the recommended one: it is the main thing a hardware
DSP box offers that v1 does not, and it needs no sandbox change.

## Epics

Each epic lists scope and the questions epic-planner must settle. The standing rules carry over
unchanged: realtime rules, every device rate up to 384 kHz, no GPL, clean-room, feature flag per
epic, live ANC and MIMO only through `LiveTreatmentArm` and written authorisation.

### V2-1 Optional virtual audio driver add-on (rescoped, owner 16 Nov 2026)

Part of v2 and free to Mac owners (owner, 17 Nov 2026): not a separately sold product. It is still
downloaded from the website with its own signed installer, because the App Store cannot carry an
audio driver (`AGENTS.md` section 2).

Notch Sixty's own virtual output device, as an optional add-on. The app installs and runs without
it and the process tap stays the default input path. With the driver, apps play into a device
named for the app: the source rate is known, surround programme can reach a stereo DAC, and a
crash gives silence instead of unprocessed audio. Sound quality with matching rates is the same
on both paths; the driver adds convenience and the cases below, not fidelity.

Owner decisions of 16 Nov 2026: write our own driver (no BlackHole or other GPL code, and not as a
coding reference); it lives in its own repository and is downloaded from there; Settings has a
sheet to enable and install it and a clean switch between tap and driver; features that need the
driver say so in the app. The App Store listing is wanted but is not a hard requirement.

**Settle before planning**

- [x] `AGENTS.md` edit (owner approved 16 Nov 2026): sections 2, 3 and 6 now allow the optional add-on. The app never depends on the driver; the driver is a separate product; the sandboxed app never installs it
- [ ] App Store question (open): App Review rules say a Mac App Store app may not download or install additional code that adds functionality. So the App Store build cannot download or run the installer. Proposed shape, to confirm with App Review before building: the App Store build only detects an installed driver and uses it; its Settings sheet explains the add-on and opens the download page in the browser; the user runs the installer themself. Fallback if App Review refuses even the link: the sheet shows status only and the website carries the instructions. A direct-download build (Developer ID) that installs from inside the app is a later option, not required
- [ ] Licence review for the starting point: Apple's sample audio driver or libASPL (MIT), recorded in `docs/PROVENANCE.md` and `THIRD_PARTY_NOTICES.md`; otherwise written from Apple's AudioServerPlugIn documentation

**Slices (epic-planner refines them)**

- [ ] D1 Input-source seam in the app: one interface with two backends (process tap, virtual device) behind the same realtime bridge. The control-plane state machine gains named states for "driver selected but missing" and "switching input"; no silent fallback. Tap stays the default. Needs-owner (Core Audio transport)
- [ ] D2 The driver (own repository, C++, user-space AudioServerPlugIn, no kernel code):
  - Loopback device, every rate the DAC offers up to 384 kHz, layouts from stereo to 7.1.4 (the tested maximum). The channel count is a build constant sized for 16 channels, so 9.1.6 can be added later without a redesign
  - Its clock follows the selected DAC, so the app needs no drift correction (the tap's one-clock advantage is kept). If that cannot be made exact, an explicit, measured asynchronous resampler is an owner decision, not a default
  - The device exists only while the app holds a heartbeat. If the app quits, crashes or is force-quit, the device disappears and macOS returns to a real output: system audio is never left silent or wedged (AGENTS.md section 5)
  - Control and handshake through versioned custom device properties only (works from the sandbox); the app refuses a driver version it does not know
  - Realtime rules apply to the driver's IO path; it documents allocation, locking, latency, rate and channel assumptions
- [ ] D3 Installer and removal: signed, notarised package published as releases of the driver repository; an uninstaller; version check and "driver update available" notice in the app; the installer is the only thing that touches the system audio folder
- [ ] D4 Settings: an "Audio input path" section with the status (not installed, installed, needs update, in use), the enable sheet, and one switch between tap and driver. Switching fades out, changes path and fades in; on switching to the driver the app makes it the system output and remembers the previous one, and puts it back on switching away or quitting
- [ ] D5 "Needs the driver" notes: each feature that depends on the driver shows a short note with a link to the Settings section, and stays visible but unavailable without it. One source of truth lists these features
- [ ] D6 What the driver unlocks:
  - Automatic rate following (failure and rate review, owner approved 15 Nov 2026): the player sets the virtual device's rate and the app sets the DAC to match (or its nearest supported multiple); off by default, with the v1 rate picker as the manual choice. Builds on the E15 S5 finding
  - Surround programme on a stereo DAC, for binaural, virtual-speaker and our own downmix
  - A multichannel DAC used for an active stereo system no longer has to be set to stereo in Audio MIDI Setup
  - Silence, not unprocessed audio, when the app stops. Builds on the E9 S9 finding
  - Players that take exclusive control can target the virtual device (E23 S8 finding)
  - Lip sync: the device reports the app's total added delay to macOS as its latency and keeps it current, so video players stay in sync by themselves (owner, 17 Nov 2026; end-state review). v1 shows the delay in the E31 signal-path view
- [ ] Tests: driver unit tests for the ring and clock; app tests with a fake device for both backends, the switch, a missing driver and an unknown driver version, at the eight rates. Bench: install, update and removal; rate changes; sleep and wake; DAC unplug; force-quit; a macOS update; the tap path unchanged with the driver installed but off

### V2-2 Input and preamp mode

Process a physical input: a turntable through an ADC, a TV through an HDMI or optical interface.
This lets the Mac replace a hardware DSP box in a living-room system.

Staged (owner, 16 Nov 2026):

- [ ] Stage 1, input on the same interface as the output: choose that device's input channels as the program source instead of, or mixed with, system audio. One clock, so no drift correction or SRC. Covers most phono setups (an interface with line in and line out)
- [ ] Input level, clip indication and source switching on the Dashboard and menu bar (with stage 1)
- [ ] Stage 2, separate input and output devices: clock handling (aggregate drift correction or explicit SRC, an explicit product decision under `AGENTS.md` section 3)
- [ ] Stage 3, low-latency path for TV use, with A/V sync

Not planned (owner, 16 Nov 2026):

- No file player in the app. Local files play through any player and system audio. What hi-res local playback misses (automatic rate following, players that take exclusive control) is V2-1 D6
- No DAW tracking or live-monitoring path through the tap (latency). A DAW's playback is processed like any other app; DAW use is served by the virtual device (V2-1) and the Audio Unit (V2-12)
- [ ] Tests at the eight rates; bench: lip sync and long-run drift

### V2-3 Network endpoint

Receive audio from other players.

- [ ] First check macOS's own AirPlay Receiver, which lets an iPhone play to the Mac (owner, 17 Nov 2026; end-state review). If the tap processes its audio (the E22 check), that may be enough, and our own AirPlay receiver and its licence are not needed
- [ ] Then an open UPnP/DLNA renderer (no certification needed); licence review of any library
- [ ] Roon Ready, and our own AirPlay receiving if macOS's receiver is not enough, only after an owner decision on certification and licence
- [ ] Gapless playback, rate changes between tracks, and volume control from the sender

### V2-4 iPhone and iPad companion (owner, 11 Nov 2026)

Free in v2: it extends the Mac app (remote and measurement microphone). Mobile editions that
process audio themselves are v3 (V3-3).

- [ ] Remote for the Mac app using the E16 local API: profile, volume, bypass, Quiet Zone session (subject to the arm), blind comparison from the seat
- [ ] iPhone as a measurement microphone: needs its own calibration and accuracy design first (per-model microphone response, timing against the Mac's clock, and the limits under which a phone capture is trusted) before any design path uses it
- [ ] Pairing, discovery and App Store distribution for the iOS app

### V2-5 Moved to v3 as V3-2 (owner, 17 Nov 2026)

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
- [ ] Speaker listening level (SPL) and noise dose at the seat, deferred from E33 D9 (owner, 15 Nov 2026); needs an output-to-seat SPL reference, which v1 does not have

### V2-12 Parked (owner, 17 Nov 2026)

See "Conditional and undecided items".

### V2-13 Virtual bass for small speakers

- [ ] Psychoacoustic bass extension below a small speaker's range. Borderline with "effects", so the owner decides scope first

### V2-14 Moved to v3 as V3-1 (owner, 17 Nov 2026)

### V2-15 Community sharing

- [ ] Share and browse profiles, targets and speaker presets. The first network feature: needs privacy, moderation and App Review decisions

### V2-16 Verification with music (owner, 11 Nov 2026; moved from E11)

- [ ] First check whether the E4 online path tracking can be reused, and size the work from that
- [ ] During normal listening, compare what the app plays with what a room microphone hears and estimate the response
- [ ] Prompt when the response has moved away from the measured one, and offer to re-measure
- [ ] The microphone is used only while the user has switched this on; state that clearly

### V2-17 Speaker and room health check (strategic review, owner approved 15 Nov 2026)

- [ ] Compare a new measurement (or the V2-16 estimate) with the stored one per speaker and flag a likely cause: a failing or disconnected driver, a moved speaker or seat, a changed room
- [ ] Keep a dated history per speaker so slow change is visible
- [ ] Offer the matching action: re-measure, re-run correction, or check the speaker

### V2-18 Selective restore from a backup (owner, 17 Nov 2026; from the Settings review, E12 G38)

- [ ] Open a backup (manual or automatic) and list what it holds: Content Presets, Playback Systems, Room Correction projects, measurement sessions, binaural profiles, settings
- [ ] Restore chosen items only; nothing else is replaced. An item with the same name is kept alongside as a copy unless the user chooses to replace it
- [ ] A restored system whose hardware is not on this Mac asks for mapping, as full restore does today; nothing is bound silently
- [ ] Works while audio runs when the restored item is not the active one

### V2-19 Rates above 384 kHz (owner, 17 Nov 2026; from the whole-app review)

- [ ] Support devices at 705.6 and 768 kHz: two more standard rates in every DSP test and reference-lab case, and a CPU budget at twice today's top rate
- v1 stops at 384 kHz and says so in the rate picker (E30)

### V2-20 Second zone (owner, 17 Nov 2026; from the whole-app review)

- [ ] Play to a second, separately processed output at the same time (another room, or headphones beside the speakers), each with its own profile and volume
- [ ] Clock handling between the two devices is an explicit product decision under `AGENTS.md` section 3
- Not this: one speaker system spread over two DACs. v1 already supports that through an aggregate output (E8); the clock warning is E8 S16

### V2-21 Speaker remapping and reflection control (owner, 17 Nov 2026; from the whole-app review)

- [ ] Find each speaker's true direction with a multi-capsule microphone and re-render a multichannel layout to its intended positions
- [ ] From measurements first, decide whether early reflections above the bass range can be treated beyond what E10 and E19 already do
- Needs a multi-capsule microphone. Builds on v1's multichannel layouts and correction (E6, E10, E14) and on E19; v1 already plays multichannel layouts (corrected 17 Nov 2026)

### V2-22 Dialogue separation (owner, 17 Nov 2026; from the end-state review)

v1 lifts dialogue only where the source has a centre channel (E33 S13). This brings clearer dialogue to stereo sources.

- [ ] Investigation first: compare a dialogue level on E14's upmixed centre channel with a trained separation model, on clarity, artefacts, added delay and CPU, including how a model trained at one rate serves every device rate up to 384 kHz; the owner chooses before planning
- [ ] A trained model trains only on data we own or license (MUSDB18 and similar datasets are non-commercial); provenance and licence entries for every dataset and for the model
- [ ] The model sits behind a core interface with a Core ML backend in `core/platform/macos`. It runs on its own thread with a fixed, reported delay, never in the audio callback
- [ ] Tests at the eight rates; bench: dialogue clarity by ear on film and TV sources

### V2-23 Per-band EQ placement and linear-phase multiband (owner, 17 Nov 2026; from the end-state review)

- [ ] Per-band placement: each band works on both channels, left, right, mid or side, all within one EQ (today each lane of the linked, independent or mid/side mode has its own band list). Old profiles load unchanged
- [ ] Then a linear-phase mode for the multiband compressor, built on the E33 S27 linear-phase design, with its added delay shown in the E31 signal-path view
- [ ] Settle in planning: how placement combines with the E33 S20 speaker groups on wide sessions
- [ ] Tests at the eight rates

### V2-24 Languages (owner, 17 Nov 2026; from the end-state review)

v1 ships in English only (E18).

- [ ] Move all the app's text into a string catalogue, including text the code builds with `String(format:)`, and show and accept numbers and units in the user's format
- [ ] Then add translations, with screen checks of every page in each language
- [ ] Settle before planning: which languages, and who translates

## v3: other platforms (owner, 17 Nov 2026)

Status: not started; after v2. Each edition is sold separately and runs the E21 portable core
behind its own platform backend and UI shell.

| ID | Epic | Size | Depends on | Owner decision needed before planning |
| --- | --- | --- | --- | --- |
| V3-1 | Windows edition (was V2-14) | Very large | E21, V3-2 | Yes: driver, installer, UI shell, price |
| V3-2 | Headless endpoint and Linux (was V2-5) | Large | E21 | Yes: UI shell, distribution, price |
| V3-3 | Mobile editions (exploration first) | Medium to large | E21, V2-4 | Yes: which platforms and options, after the investigation |

### V3-1 Windows edition (was V2-14)

- [ ] Needs a signed virtual audio driver or an APO (loopback capture cannot intercept the default output), an installer and a UI shell
- [ ] Only after the portable core (E21) and the headless endpoint (V3-2) are complete

### V3-2 Headless endpoint and Linux (was V2-5)

- [ ] Run a finished configuration on a Mac mini without a display
- [ ] Linux build on PipeWire (virtual sink or filter chain, no root), using the E21 core
- [ ] Configuration by exported project file and by the local API; the UI-shell decision for non-Apple platforms is made here
- [ ] This is the route to a hardware partnership; decide the distribution model first

### V3-3 Mobile editions (exploration first)

- [ ] Investigation before any plan: what each platform allows, checked against current platform documentation. Working assumptions to verify: iOS does not let an app process other apps' audio, so options there are a player that corrects its own playback, an AUv3 extension inside host apps, or correction profiles used by partner apps; Android has allowed system-wide equaliser apps, so system-wide headphone correction may be possible there
- [ ] Choose which editions to build from the investigation. Headphone correction is the likely core, since phones mostly play through headphones; room correction matters when a phone or tablet drives a speaker system
- [ ] Kept apart from V2-4, which stays a free companion to the Mac app

## Conditional and undecided items

- Plug-in edition of room correction (was V2-12; parked, owner 17 Nov 2026): an Audio Unit (and
  possibly VST3 or AAX) of the correction stage for players and DAWs. Parked because it serves the
  studio market rather than listeners, carries only plain room correction (Quiet Zone, MIMO, bass
  management, upmixing and 3D sound need the whole playback system), and adds per-host support;
  v1 and V2-1 already process DAW playback. Revisit only if buyers after launch ask for it; the
  E21 core makes it fairly cheap to add then.

- E20 multirate (decimated low-frequency regions) leaves v1 if the E20 S8 re-measurement shows no
  need (owner, 11 Nov 2026). It gets an epic here only if a later measurement shows a need.
- Cut candidates C1, C2, C4, C5, C7 and C8 from the review are undecided; they stay in v1 until the
  owner decides. The signal-path and history view is in v1 as E31.
- Not planned (owner, 17 Nov 2026): DSD output (system audio from macOS is PCM, and every correction stage needs PCM), and
  MIDI or OSC control (the E16 local API covers integrations).
- E35's filter method (owner, 17 Nov 2026; end-state review): look again at the regularisation calculated per frequency that E35 avoids (`docs/epics/E35.md` decision 3) once US 9,167,344 ends on 18 Apr 2032, with a patent attorney's check first, because Google's US 11,589,162 runs to about November 2039.

## How to start

1. The owner says which epic to start (or the whole first wave).
2. Record the decision in `docs/PROGRAM_PLAN.md` "Decisions taken", give the epic the next free
   `E<n>` number, and add it to the execution order.
3. Settle the "owner decision needed" column for that epic before planning.
4. `/next E<n>` then runs epic-planner, which writes `docs/epics/E<n>.md` for approval as usual.
