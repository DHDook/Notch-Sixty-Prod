// N60VirtualDeviceProtocol.h
// E36 S2: the one artefact shared by the app and the Notch Sixty virtual audio driver (a separate repository).
// The driver repository copies this file; keep it free of platform headers so both sides can include it.
// Spec: docs/VIRTUAL_DEVICE_PROTOCOL.md. Transport-agnostic: nothing here names how programme audio moves (E36 G1).
#ifndef N60_VIRTUAL_DEVICE_PROTOCOL_H
#define N60_VIRTUAL_DEVICE_PROTOCOL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Protocol version this app build speaks. The app accepts only the versions it lists in Swift
/// (`VirtualDeviceProtocol.acceptedVersions`); any other value reads as "unknown driver version".
#define N60_VD_PROTOCOL_VERSION 1u

/// Bundle identifier of the driver's plug-in, looked up with kAudioHardwarePropertyTranslateBundleIDToPlugIn.
#define N60_VD_PLUGIN_BUNDLE_ID "com.dhdook.NotchSixty.VirtualDriver"

/// Device UID of the virtual output device the plug-in publishes while a lease is valid (E36 S5: the app takes over
/// and restores the macOS default output by this UID). The driver (X2) must publish exactly this UID.
#define N60_VD_DEVICE_UID "com.dhdook.NotchSixty.VirtualDriver.Device"

/// Custom property selectors on the plug-in object (scope global, element main). Four-character codes.
#define N60_VD_PROP_PROTOCOL_VERSION 0x6e367076u /* 'n6pv' read: uint32 protocol version the driver speaks */
#define N60_VD_PROP_LEASE            0x6e366c73u /* 'n6ls' write: N60VDLease */
#define N60_VD_PROP_CLOCK_SCALAR     0x6e366373u /* 'n6cs' write: float64 rate scalar (S3) */
#define N60_VD_PROP_DAC_RATES        0x6e366472u /* 'n6dr' write: float64[] rates the DAC offers (S3) */
#define N60_VD_PROP_LAYOUT           0x6e366c79u /* 'n6ly' write: uint32 channel layout code (S3) */
#define N60_VD_PROP_LATENCY          0x6e366c74u /* 'n6lt' write: uint32 frames of added delay (S6) */

/// The app renews the lease this often (control-plane timer, never the audio callback) and the driver removes
/// the device this long after the last renewal.
#define N60_VD_LEASE_RENEW_MS  250u
#define N60_VD_LEASE_EXPIRY_MS 2000u

/// Lease value. `validMs` of 0 releases the lease at once (normal Quit). `sequence` rises by one per write so the
/// driver can ignore a stale or replayed write. `sessionToken` identifies one app run.
typedef struct N60VDLease {
    uint32_t protocolVersion; /* the version the app speaks */
    uint32_t sessionToken;
    uint64_t sequence;
    uint32_t validMs;
    uint32_t reserved; /* zero */
} N60VDLease;

#ifdef __cplusplus
}
#endif

#endif
