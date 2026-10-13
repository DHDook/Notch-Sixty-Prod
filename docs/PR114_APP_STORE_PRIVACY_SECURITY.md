# PR114 Slice 2 — App Store, Privacy & Security Finalization

Status: **IN PROGRESS — REMOTE AUDIT**

This slice audits the actual macOS shipping target after PR113B. It does not
infer privacy posture from the old PR102 feature surface.

## Shipping sandbox posture

The production application remains App-Sandboxed and currently requests only:

- `com.apple.security.app-sandbox`;
- `com.apple.security.device.audio-input`; and
- `com.apple.security.files.user-selected.read-write`.

No network-client, network-server, location, contacts, calendar, camera,
Bluetooth, Photos, personal-information, automation, or privileged-helper
entitlement is part of the shipping target.

Production Apple team/provisioning credentials remain external to source
control.

## Permission purpose strings

### System Audio

System-audio capture is used only to process program audio through the selected
Notch Sixty output path. The existing `NSAudioCaptureUsageDescription` remains
accurate.

### Measurement Microphone

The finished product uses the selected microphone in more than Room Correction.
The microphone may participate in explicitly initiated measurement/calibration
workflows such as Speaker Calibration, Measurement Lab, Room Correction,
multichannel calibration, ambient-field measurement, or related acoustic
commissioning.

PR114 therefore broadens `NSMicrophoneUsageDescription` and the Preferences
permission explanation from the stale “Room Correction only” wording to the
actual product boundary:

- the microphone is not required for ordinary listening;
- access is requested only when the user starts a microphone-based measurement
  or calibration workflow; and
- the purpose is measurement of the speaker/room/ambient acoustic field.

## App-owned data flow

The audited product is local-first:

- system audio is processed locally by the DSP engine;
- microphone input is used locally by explicit measurement/calibration
  workflows;
- Room Correction projects, Measurement Lab sessions, profiles, recovery state,
  and other product state are stored locally;
- user-requested exports/backups are written to user-selected or app-owned
  locations;
- **Copy Diagnostics** places the diagnostic text on the local clipboard only
  after an explicit user action;
- the app-owned diagnostics path does not upload diagnostics;
- the product does not silently upload captured audio, room-measurement samples,
  profiles, backups, or recovery data.

The general backup deliberately excludes macOS permission grants, Launch at
Login registration, machine-local recovery state, and physical-acceptance
authority.

## Network / analytics / tracking audit

PR114 performs a branch-local scan of the shipping source and project for
bundled app-owned networking, analytics, advertising/tracking, crash-reporting,
or self-update frameworks.

The current target is expected to contain none of the following app-owned
capabilities unless they are deliberately introduced and separately reviewed:

- `URLSession` / Network.framework client code;
- analytics SDKs such as Firebase Analytics, Mixpanel, Amplitude, Segment,
  TelemetryDeck, PostHog, Datadog or App Center;
- bundled Sentry/Crashlytics-style automatic crash upload;
- AdSupport / AppTrackingTransparency / advertising identifiers;
- Sparkle or another self-updater in the App Store build; or
- a sandbox network-client/network-server entitlement.

The one classified bundled third-party production component remains
`libmysofa v1.3.4` under BSD-3-Clause. It is a local SOFA/HRTF file reader,
not a telemetry/networking SDK.

### User-installed Audio Units

Notch Sixty can host user-installed Audio Units. Those components are selected
from software already installed by the user and are not bundled Notch Sixty
dependencies or SDKs.

PR114 therefore does not classify an arbitrary user-installed plug-in as a
Notch Sixty production dependency. It also does not claim to control every
possible external plug-in's own privacy/network behavior. App Store privacy
answers and the public privacy policy must describe Notch Sixty's app-owned
behavior accurately and should make this plug-in boundary clear where useful.

## Privacy manifest decision

For the current **macOS-only** shipping target, PR114 does not add an empty
`PrivacyInfo.xcprivacy` merely as a release ritual.

Current Apple documentation distinguishes:

- privacy manifests as a mechanism for declaring an app/SDK's data practices;
- required-reason API declarations for the currently named iOS-family
  platforms; and
- separate App Store Connect privacy disclosures for Mac App Store listings.

The current source/dependency audit finds no bundled tracking/analytics SDK and
no classified third-party SDK that independently requires a privacy manifest.
Accordingly, the PR114 macOS RC records:

- `privacyManifestPresent=false`; and
- `privacyManifestRequiredForCurrentMacTarget=false`.

This is a dated release decision, not a permanent architectural exemption.
Re-evaluate before release if Apple changes the macOS requirement, if a
manifest-requiring third-party SDK is added, or if Notch Sixty gains another
Apple platform target.

## App Store Connect privacy gates

Repository CI cannot complete App Store Connect account metadata. PR114 keeps
these as explicit release-credential/metadata handoff items:

- configure a public privacy-policy URL;
- complete the App Privacy questionnaire against the final shipping build;
- reconcile any data collection introduced by production services added after
  this audit;
- verify the final answers after production signing/TestFlight processing.

Until owner/App Store Connect evidence exists:

- `appStorePrivacyPolicyURLConfigured=false`; and
- `appStorePrivacyResponsesComplete=false`.

These unresolved metadata items do not make the source unsafe, but they block
public App Store release.

## Security / App Store architecture

PR114 preserves the established production constraints:

- public Apple APIs only;
- no privileged installer/root helper;
- no persistent HAL plug-in installation;
- no `coreaudiod` restart dependency;
- no kernel/system extension;
- no App Store self-updater;
- no embedded production Apple credentials;
- user file access through sandbox-permitted mechanisms.

Remote CI can audit these source/configuration facts. It cannot substitute for
clean-machine App Review behavior, production signing, TestFlight or PR112
physical hardware acceptance.
