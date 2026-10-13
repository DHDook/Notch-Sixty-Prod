# PR114 Slice 5 — Mac App Store metadata and support handoff

**Status: REMOTE DRAFT COMPLETE — OWNER / APP STORE CONNECT APPROVAL PENDING.**

Machine-readable source: `release/pr114-commercial-metadata.json`. Its listing
copy is draft and must not be represented as published or approved. The current
shipping identity is Notch Sixty, `com.dhdook.NotchSixty`, version 1.0.0
(build 1), macOS 27.0+, Apple Silicon arm64.

## Draft store listing

**Subtitle:** Precision audio processing for Mac

**Promotional text:** Audio processing, room measurement and speaker calibration
in one local-first Mac workspace.

**Description:** Notch Sixty is a macOS audio processing workspace with
equalization, dynamics, speaker and subwoofer management, room measurement and
correction, listening profiles, and selected binaural and multichannel tools.
Availability and safe operation of some calibration and Active Acoustics
functions depend on supported hardware and commissioning. Playback and
measurements are handled locally.

**Proposed keywords:** DSP, equalizer, room correction, speaker calibration,
audio measurement, subwoofer.

Owner approval is needed for the final wording and feature claims, primary and
secondary categories, age rating, pricing, territories and localizations.
Never advertise live speaker-connected feed-forward ANC as commissioned or
universally supported; it remains physically gated.

## Honest screenshots and commercial artwork

Use images captured from the exact production-signed or TestFlight build on a
real Apple Silicon Mac. Check version/build, selected device and data displayed
before capture. Candidate subjects: Dashboard, EQ/Dynamics, Speaker Calibration,
Measurement Lab, the in-app User Guide, and DSP Reference. Show advanced
multichannel, headphone or Active Acoustics views only when behavior and
context are accurately represented. Do not simulate successful measurements,
fabricate analysis results, or expose private device information. Verify current
App Store Connect image formats and sizes on the submission date.

The final commercial icon is intentionally awaiting owner selection. Technical
asset completeness from CI is not final owner approval.

## Draft privacy disclosures / public policy requirements

The audited application processes system audio on the Mac, uses the microphone
for user-started measurement/calibration, and stores profiles, acoustic
measurements, exports, backups and recovery data locally. Copy Diagnostics
places text on the clipboard only when the user requests it. The audited
first-party application contains no automatic diagnostics/audio upload, analytics
or tracking SDK. User-installed Audio Units are third-party software with
independent privacy practices; Notch Sixty cannot warrant their behavior.

Before public release, the owner must approve and **publish** an accurate
privacy policy explaining processing, local files, user deletion/export choices,
external plug-ins, contact and request handling, and any future changes. A
published privacy-policy URL and App Privacy questionnaire answers must be
entered and verified in App Store Connect. This document is a *draft outline*,
not a hosted policy; do not invent a URL, support email, address or retention
promise.

## Customer support and review preparation

In-app help includes searchable User Guide and DSP Reference plus a deliberate
Copy Diagnostics action. Before release: publish a working support channel,
define handling of bug reports and incidents, and document a privacy contact.
Ask for macOS/app version, equipment, repro steps and consent before requesting
diagnostics. Never require raw recordings or room measurement exports by default.

On a clean compatible Apple Silicon Mac and a real TestFlight build, check
initial permissions, first playback, denied microphone access, output-device
loss, sleep/wake, quitting, recovery, backup/restore, missing plug-ins, and
user-selected file sandbox behavior. Verify Launch at Login never silently
starts audio. Prepare App Review instructions for system-audio permission and
optional microphone measurements, without inventing test equipment or
successful acoustic results. Check current App Review and export-compliance
rules at actual submission.

Owner-required release tasks: Apple account and app record, support/privacy
URLs, final icon/screenshots, categories/rating/pricing, export compliance,
rights clearance, App Privacy answers, reviewer contact, production-signed
upload, TestFlight, App Review, and explicit authorization to publish.

## Authority

The `remoteSoftware` audit cannot satisfy `physicalHardware`,
`releaseCredential` or `externalReview`. Keep PR114 and ancestors open,
draft and unmerged; do not modify `main`.
