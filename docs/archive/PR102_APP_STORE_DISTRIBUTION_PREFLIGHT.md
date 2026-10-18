# PR102 — App Store & Distribution Preflight

## Purpose

PR102 separates three different artifacts that must not be confused:

1. **CI Release build** — unsigned during compilation, then optionally ad-hoc
   signed for local structural verification.
2. **CI archive preflight** — an unsigned Xcode archive used to prove that the
   current source tree can be archived as an arm64 macOS application and that
   required product resources/metadata survive archive construction.
3. **Production distribution** — App Store Connect/TestFlight or Developer-ID
   distribution using the owner's Apple Developer credentials and Apple's
   signing/distribution services.

Only the third category is production distribution evidence.

## Current sandbox/privacy contract

The production target must retain:

- App Sandbox;
- Core Audio input access;
- user-selected read/write file access;
- a nonempty system-audio capture usage description; and
- a nonempty microphone usage description.

PR102 CI treats any entitlement expansion as a deliberate release-contract
change that must be reviewed rather than silently accepted.

## Forbidden production architecture

The production source must not introduce:

- privileged-helper installation;
- Authorization Services elevation;
- installation into `/Library/Audio/Plug-Ins/HAL`;
- `coreaudiod` restart/termination dependencies;
- root/sudo execution;
- kernel/system-extension requirements for ordinary audio processing; or
- an App-Store self-updater.

The driverless Core Audio process-tap design remains authoritative.

## CI archive preflight

The PR102 macOS job creates an archive with signing disabled:

```text
xcodebuild archive
  -project NotchSixty.xcodeproj
  -scheme NotchSixty
  -configuration Release
  -destination generic/platform=macOS
  -archivePath <temporary>/NotchSixty.xcarchive
  CODE_SIGNING_ALLOWED=NO
```

The job then verifies:

- archive structure exists;
- the archived app is present;
- the executable is arm64;
- bundle identifier/version/build are present;
- system-audio and microphone privacy strings survive into the archive;
- `ThirdPartyNotices.txt` survives into the archived product; and
- the archive is recorded only as **remote software preflight**, never as a
  signed/submittable App Store artifact.

## Credential-gated release work

The following remain `releaseCredential` gates:

- selecting/configuring the production Apple Developer team;
- production Mac App Store signing;
- archive validation using the production signing identity/profile;
- creation/verification of the App Store Connect application record;
- upload to App Store Connect;
- TestFlight processing/testing;
- App Review submission and response; and
- Developer-ID signing/notarization if direct distribution is also selected.

Those gates cannot be completed honestly in repository CI without the required
owner credentials and Apple service access.
