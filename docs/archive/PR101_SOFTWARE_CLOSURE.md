# PR101 Remote Software Closure

## Scope

This document records the remote/software closure boundary for roadmap PR101,
Full-System Reliability & Acoustic Acceptance.

PR101 may be declared **remote software complete** only when a single macOS CI
job produces the formal `PR101_REMOTE_SOFTWARE_ACCEPTANCE_CLOSURE` artifact
after all prerequisite evidence in that same job has passed.

## Remote acceptance requirements

The closure requires exactly ten remote requirements:

1. stereo transport stability;
2. semantic multichannel stability;
3. headphone/spatial runtime stability;
4. Audio Unit fault containment;
5. Room Treatment fail-closed runtime;
6. Active Acoustics fail-closed runtime;
7. lifecycle recovery;
8. cumulative DSP correctness regression;
9. resource stability; and
10. dropout/fault recovery stress.

The first six originate in deterministic campaign scenarios and are accepted
at macOS-CI authority only when those scenarios pass inside the same macOS job.
Lifecycle recovery requires the targeted PR101 runtime/lifecycle test step.
DSP correctness requires the complete XCTest regression. Resource stability and
dropout recovery require the same-process realtime soak to accept both gates
with zero unexpected dropouts, zero non-finite samples, zero unrecovered faults,
and zero retained-heap growth.

The closure also requires successful arm64 Debug and Release-performance builds.

## Evidence binding

The closure artifact records the exact GitHub commit SHA and Actions run ID.
It includes SHA-256 digests of the deterministic campaign, resource baseline,
and realtime resource/dropout soak JSON files.

Those digests establish integrity linkage between CI artifacts. They are not
instrument authentication and do not establish anything about physical
microphones, DACs, loudspeakers, rooms, reviewers, or listening conditions.

## Hardware gates that remain open

Remote closure deliberately leaves exactly five requirements unresolved:

- real input/output device unplug and replug recovery;
- real macOS sleep/wake and device-clock reacquisition;
- prolonged production-Mac thermal/endurance stability;
- speaker protection and emergency hardware mute; and
- final measured acoustic acceptance.

These remain `hardwareRequired`.

In addition, remote closure must keep:

- `physicalAcceptanceComplete = false`;
- `releaseAcceptanceComplete = false`;
- `liveFeedForwardANCOutputAuthorized = false`; and
- `speakerConnectedFeedForwardOutput = false`.

PR101 remote closure therefore does not authorize speaker-connected
feed-forward ANC and does not replace the physical PR99/PR101 verification
campaigns.

## Closure status

**REMOTE SOFTWARE COMPLETE.**

The branch-head push workflow at commit
`d394dd9dd3e91cf00555bf2c2532753c32b3f3de` completed successfully in
GitHub Actions run **38157445404** and generated the formal closure artifact.

The artifact reported:

- `remoteRequirementCount = 10`;
- `remotePassedCount = 10`;
- `remoteSoftwareAccepted = true`;
- `hardwareRequirementCount = 5`;
- every hardware-only requirement = `hardwareRequired`;
- `physicalAcceptanceComplete = false`;
- `releaseAcceptanceComplete = false`;
- `liveFeedForwardANCOutputAuthorized = false`;
- `speakerConnectedFeedForwardOutput = false`; and
- closure SHA-256
  `dcacf184d119d5d53905360f6856e866b3b4bd703264a3c39ab4055c0d8ad572`.

The same workflow completed the full application regression with **691 tests,
0 failures**.

The realtime resource/dropout evidence feeding closure retained the Slice 5
acceptance boundary: 512 injected starvation faults, 512 recoveries, zero
unexpected dropouts, zero non-finite samples, zero unrecovered faults, and zero
retained-heap growth.

This closure establishes completion of the **remote/software PR101 scope**.
Physical acceptance remains intentionally open and requires the real hardware
campaign described above.

The commit containing this status update is documentation-only. Final PR status
should additionally reference a successful exact-head workflow for the latest
branch head before merge or before stacking PR102 work.
