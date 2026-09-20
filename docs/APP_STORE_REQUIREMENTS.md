# App Store Requirements

Mac App Store compatibility is an architectural constraint, not a release-time retrofit.

## Required posture
- App Sandbox enabled in the shipping target
- public Apple APIs only
- no privileged installer
- no root operations
- no installation into `/Library/Audio/Plug-Ins/HAL`
- no `coreaudiod` restart dependency
- no kernel/system extension requirement
- no self-updater in the App Store build
- user files accessed only through permitted sandbox mechanisms

## Audio architecture
Use Core Audio process/device-scoped tap APIs and private aggregate-device resources created at runtime. These resources must be torn down safely and must not depend on persistent system modification.

## Permissions UX
System-audio recording permission behavior must be handled as product UX. The app should clearly explain why permission is required, detect capture-without-signal states conservatively, and recover cleanly after OS-required relaunches.

## Signing/release
Production work must eventually validate:
- Developer ID/local development as appropriate
- Mac App Store signing entitlements
- archive/export flow
- TestFlight
- App Review behavior on a clean account/machine

POC sandbox success demonstrates feasibility only; it is not App Review approval.
