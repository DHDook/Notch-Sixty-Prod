# Virtual device protocol (E36 S2)

Between the Notch Sixty app and its optional virtual audio driver (separate private repository, E36). Header:
`NotchSixty/Audio/VirtualDevice/N60VirtualDeviceProtocol.h`; the driver repository copies it. App side:
`NotchSixty/Audio/VirtualDevice/VirtualDeviceDriver.swift`. Written from Apple's AudioServerPlugIn and Audio Object
documentation; no third-party code.

## Scope

The properties below are control only. Programme audio moves through a shared-memory ring (transport A, E36 G1 closed
23 Nov 2026): see "Programme ring". Nothing in the property protocol runs on an audio thread; the sandboxed app uses only
public property calls (no mach-lookup exception).

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

### Value encodings (S3)

Native-endian, one property call per value; `N60VirtualDeviceProtocol.h` has the macros.

- `n6cs` clock scalar: float64, the factor the driver multiplies its clock by. 1.0 nominal, always within 1 +- 0.001
  (`N60_VD_CLOCK_SCALAR_MAX_PPM`). The app writes it every 250 ms with the lease while the driver path is on.
- `n6dr` DAC rates: float64 array, 1 to 32 entries, ascending, Hz. The rates the driver offers; the app writes the DAC's
  rates up to 384 kHz, and a one-entry list pins the device to one rate.
- `n6ly` layout: uint32 code, `N60_VD_LAYOUT_STEREO` (1, 2 channels), `_5_1` (2, 6), `_7_1` (3, 8), `_5_1_4` (4, 10),
  `_7_1_4` (5, 12).
- `n6lt` latency (S6a): uint32 frames of added delay.

## Programme ring (S3)

Header `core/include/n60/vd_ring.h` (copied into the driver repository). The driver creates a POSIX shared-memory object
and writes interleaved float32 frames; the app maps it read-only and reads it from the DAC's callback. There is no input
stream, so macOS shows neither the orange nor the purple capture indicator and asks for no microphone permission.

- Name: `<app group id>/n60vd`, at most 31 characters in all (macOS shared-memory limit). The app group id is
  `<TeamID>.group.n60vd` (22 characters). The app needs only the app-group entitlement; no mach-lookup exception (the
  Mach handshake, A1, needs one and is not used).
- Size is fixed at 8 MiB (`N60_VD_RING_BYTES`): 384 kHz with 12 channels holds 0.45 s.
- Header, 4096 bytes, then the frames. The writer is the only writer of `writeFrames` (release); a restart bumps `epoch`.
  The reader primes to 1024 frames, drops back to that level if the ring runs half full, and re-primes after running dry.
- The driver must not advertise an input stream and must not become the default input device: the stub probe's input
  stream made macOS choose it as the default input. The device is output only.
- The app steers the driver's clock with the scalar above so the fill stays at the target; no resampling.

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

## System output (S5)

The virtual output device's UID is `N60_VD_DEVICE_UID`. When the user switches to the driver path the app stores the
current default output's UID (persisted, key `e36.previousOutputUID`), makes the virtual device the macOS default
output, then holds the lease. Switching back, or a normal Quit, restores the stored UID first and releases the lease
after. After a crash the next launch restores the stored UID if the default output is still the virtual device (or
unreadable) and always clears the record; if macOS already moved the default to a real output, that choice stands. The selected DAC stays authoritative; the app never selects the
virtual device as its own output (S3).
