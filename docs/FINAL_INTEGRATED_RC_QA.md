# Final Integrated Release Candidate & Quality Assurance

**Status: draft, ad-hoc signed, remote software validation only.**
This is an integrated run of the complete core and optional-feature stack
following PR #129. It is not a public release, Developer-ID notarized app,
App Store submission, or authorization to merge stacked pull requests.

## What this single release-candidate workflow actually does

1. Checkout and attest one exact selected SHA on the stack after Batch 4
   and the optional acoustic research PR.
2. Run integrated Room Advisor, eight-rate acoustic numerical references,
   FIR/bass/headphone/ABX/HRTF provenance, privacy, source-license, and
   PR112 real-hardware-acceptance boundary validators.
3. Generate actual native HDF5/AES69 SOFA fixtures for the cumulative
   headphone tests.
4. Compile arm64 Debug, run focused smoke tests, compile arm64 Release,
   create an unsigned generic macOS \`.xcarchive\` and inspect its bundle
   metadata, architecture, usage strings and third-party notices.
5. Copy and ad-hoc sign the release application using its shipping sandbox
   entitlements; verify effective entitlements and the signature.
6. Build a compressed **test DMG** and SHA-256 checksum, verify the image
   and mount/read its actual installed app structure, then unmount it.
7. Run the **entire cumulative XCTest suite**, with real generated SOFA
   fixtures available to importer tests (not a source-marker-only check).
8. Rebuild the exact-head CycloneDX production SBOM, validate PR114
   commercial metadata and software-only artifact authority, then create
   the PR114 exact-head artifact manifest.
9. Create \`final-integrated-rc-qa.json\` with source/DMG/SBOM hashes,
   the exact commit/run ID and a **remaining owner hardware checklist**.
10. Compress the unsigned archive for download and publish the DMG,
    checksum, archive, SBOM, entitlement and manifests together as a
    GitHub Actions artifact named **final-integrated-remote-rc**.

An explicit \`[integration-ci]\` commit or manually applied
\`integration-ci\` PR label triggers the expensive runner once.
Ordinary draft updates run inexpensive portable guards only.
The completed status of PR #129 is inherited from its original
separate full Apple Silicon regression run; **changes to the RC branch
require the new release workflow to pass on its own exact head**.

## Controls that remain outside remote CI

- H01–H08 on a real Mac and original audio chain: selected Playback
  System, actual output and microphone, reconnect/sleep/wake, buffer
  underruns, thermal/CPU endurance and speaker-protection behavior.
- Actual 44.1/48/88.2/96/176.4/192/352.8/384 kHz device capability.
  Each nominal device/rate must be verified independently; this package
  claims tested DSP numerics, not universal DAC support.
- Measured main/sub/driver placement and correction, bass time/phase
  integration, multi-seat validation and physical output/clock routing.
- Headphone SPL, per-ear EQ, HRTF fit and low-volume listening comfort;
  optional offline research outputs remain review-only.
- Real acoustic noise cancellation hardware safety, if pursued: no
  speaker-connected feed-forward ANC is authorized by the package.
- Independent legal/IP/source-rights review. Third-party attribution
  and SBOM checks do not establish permission to redistribute a user's
  model measurements or provide definitive legal advice.
- App icon final owner approval, App Store privacy and support URLs,
  actual Apple distribution signing, notarization where used, App Store
  Connect/TestFlight/review and all production-release choices.
- Explicit approval to merge the stacked drafts, **in dependency
  order**, after hardware and owner evidence is complete.

## Your testing handoff on the Mac

Download the \`final-integrated-remote-rc\` artifact from the successful
Actions run. Check the \`.dmg.sha256\` file matches the \`.dmg\`, and retain
the manifest and handoff JSON alongside screenshots/logs. The DMG is
**ad-hoc signed, not notarized**: don't mistake it for a publicly
distributable, Gatekeeper-trusted download. Install/test it only in
your controlled owner environment with full awareness of this limit.

Start low volume and confirm device routing before playing through
amplifiers/speakers or headphones. Run the built-in Hardware Acceptance
workspace H01–H08 against that exact RC build, preserving physical
evidence identities, measurement files and failures without editing
any synthetic acceptance flag. Verify rates only if your actual device
supports them.

If a hardware issue is identified, it is a new, scoped bugfix requiring
fresh software builds and revalidation—not a reason to silently
change a hardware FAIL/PENDING into PASS. The current feature PRs
and this QA PR remain draft and unmerged until authorized.
