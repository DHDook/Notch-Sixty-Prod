# PR102 — Physical & Release-Credential Handoff

This checklist begins **after** PR102 remote release-preparation acceptance.
Completing remote CI does not complete any item below.

## A. Physical Mac / audio-hardware acceptance

Record the exact:
- Notch Sixty commit;
- app version/build;
- Mac model and macOS version;
- output/input device names and stable UIDs;
- sample rate/buffer size;
- speaker/subwoofer topology; and
- measurement microphone/instrument identifiers where applicable.

Required physical gates:

### Device and lifecycle recovery
- cold launch on a clean account/machine;
- system-audio permission allow/deny/recovery;
- microphone permission allow/deny/recovery;
- selected DAC/interface unplug/replug;
- missing-device wait-for-same-UID behavior;
- live nominal-rate changes across the hardware-supported rate matrix;
- real sleep/wake and clock reacquisition;
- repeated Stop/Start;
- normal Quit; and
- force-quit/system-audio restoration.

### Endurance and performance
- representative long-running playback;
- worst-case DSP graph(s);
- thermal/endurance run at representative high rate;
- no sustained unexpected dropouts/overruns/non-finite output;
- UI responsiveness during sustained processing; and
- memory/resource observation on the production machine.

### Speaker/acoustic safety
- output routing/channel identity;
- mandatory active-crossover safety where used;
- no full-range leakage into protected split-driver buses;
- gain/trim/polarity/delay sanity;
- limiter/protection behavior where configured;
- emergency Stop/mute behavior; and
- final listening smoke at conservative level before higher-level tests.

### Acoustic acceptance
- Room Correction measurement with the real microphone;
- speaker/sub alignment verification;
- multi-seat correction verification;
- Room Treatment/ambient features where applicable;
- before/after acoustic measurement retention; and
- subjective listening sanity after objective verification.

### Active Acoustics / feed-forward ANC
Use the existing PR99/PR101 physical protocols. Do not connect or authorize live
speaker feed-forward output until those protocols satisfy their own physical
acceptance and independent-review requirements.

Remote PR102 acceptance leaves:
- live feed-forward ANC output unauthorized;
- speaker-connected feed-forward output false;
- physical acoustic acceptance incomplete.

## B. Production Apple release credentials

These steps require the owner's Apple Developer/App Store Connect access and
are **not** repository-CI substitutes.

- confirm/create the App Store Connect app record for the production bundle ID;
- select the production Apple Developer team;
- verify required identifiers/capabilities/profiles;
- create a production-signed Release archive;
- validate the signed archive;
- inspect effective production entitlements;
- confirm version/build uniqueness;
- upload to App Store Connect;
- resolve upload/processing validation issues;
- distribute to TestFlight;
- complete TestFlight smoke testing on a clean account/machine;
- finalize App Privacy / metadata / screenshots / support information;
- submit for App Review; and
- record App Review outcome.

If direct distribution is separately chosen:
- Developer-ID sign;
- notarize;
- staple/verify as appropriate; and
- verify Gatekeeper behavior on a clean machine.

## C. Legal/IP release review

PR102's automated provenance and dependency audit is engineering evidence, not
legal advice. Before a commercial launch, the owner may choose targeted counsel
review of:
- clean-room/provenance record;
- BSD redistribution compliance;
- trademarks/third-party names used for interoperability;
- app artwork/asset ownership; and
- final EULA/privacy/commercial terms.

This remains an `externalReview` gate rather than something CI may self-approve.

## D. Public-release authorization rule

A remote PR102 artifact may report
`remoteReleasePreparationAccepted = true`.

It must **not** report `publicReleaseAuthorized = true` unless the chosen
physical, credential, and release-policy gates have been completed by genuine
evidence outside remote CI.

The repository should preserve the exact commit/version/build and the final
signed artifact identity used for the release decision.
