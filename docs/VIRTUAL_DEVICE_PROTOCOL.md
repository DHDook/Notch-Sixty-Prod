# Virtual device protocol (E36 S2)

Between the Notch Sixty app and its optional virtual audio driver (separate private repository, E36). Header:
`NotchSixty/Audio/VirtualDevice/N60VirtualDeviceProtocol.h`; the driver repository copies it. App side:
`NotchSixty/Audio/VirtualDevice/VirtualDeviceDriver.swift`. Written from Apple's AudioServerPlugIn and Audio Object
documentation; no third-party code.

## Scope

Control only. The protocol says nothing about how programme audio moves from the driver to the app: that transport
is E36 G1 and is not chosen yet. Nothing here runs on an audio thread; the sandboxed app uses only public property
calls (no mach-lookup or group entitlement).

## Discovery

The app finds the plug-in object with `kAudioHardwarePropertyTranslateBundleIDToPlugIn` and the bundle ID
`N60_VD_PLUGIN_BUNDLE_ID`. No plug-in object means "not installed". The app never installs, loads, removes or
restarts anything.

## Properties

All are custom properties on the plug-in object, scope global, element main. Selectors are four-character codes.

| Selector | Code | Direction | Value | Slice |
| --- | --- | --- | --- | --- |
| `N60_VD_PROP_PROTOCOL_VERSION` | `n6pv` | read | uint32 version the driver speaks | S2 |
| `N60_VD_PROP_LEASE` | `n6ls` | write | `N60VDLease` | S2 |
| `N60_VD_PROP_CLOCK_SCALAR` | `n6cs` | write | float64 rate scalar | S3 |
| `N60_VD_PROP_DAC_RATES` | `n6dr` | write | float64 array, the DAC's rates up to 384 kHz | S3 |
| `N60_VD_PROP_LAYOUT` | `n6ly` | write | uint32 layout code (stereo to 7.1.4) | S3 |
| `N60_VD_PROP_LATENCY` | `n6lt` | write | uint32 frames of added delay | S6 |

S3 and S6 fix the value encodings when they build them; the selectors are reserved now so a driver can publish them.

## Version gate

The app lists the versions it speaks (`VirtualDeviceProtocol.acceptedVersions`). A driver below
`minimumVersion` is "needs update"; a version the app does not list (usually newer) is "unknown version"; a plug-in
that does not answer the version read is "unknown version 0". Both are refused: the driver path is never used and
nothing falls back to the process tap silently (E36 design note 7).

## Lease

The app writes `N60VDLease` every `N60_VD_LEASE_RENEW_MS` (250 ms) from a control-plane timer. The driver publishes its
device only while a lease is valid and removes it `N60_VD_LEASE_EXPIRY_MS` (2 s) after the last write, so a crash or
force-quit leaves macOS on a real output. `sequence` rises by one per write (the driver ignores an older one);
`sessionToken` identifies one app run; `validMs` 0 releases at once. Normal Quit writes the release after the system
output is restored (S5). If the first write fails the app starts no timer and reports "lease refused".

## Status model

`not installed`, `installed (version)`, `needs update`, `unknown version`, `in use` (this run holds the lease) and
`lease refused`. S4 renders them; S5 acts on them.
