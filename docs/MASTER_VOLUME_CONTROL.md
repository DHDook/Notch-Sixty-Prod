# Master Volume and Mute Control

PR #24 independently implements playback master volume from public Core Audio HAL properties and the proprietary realtime graph. Historical GPL volume-management code is not used as an implementation reference.

The user-selected physical output remains authoritative; Notch Sixty never silently follows the default output device. A readable+writable main-output scalar volume uses device authority and HAL change listeners. Otherwise volume falls back to a separate smoothed software master-gain stage. Mute uses the device property only when readable+writable; otherwise it uses software master gain.

Master volume remains separate from input preamp, automatic headroom, DSP output gain, and transport transition gain. Global DSP Bypass and Flat bypass processing but not playback volume or software mute. External listener callbacks read state only, preventing notification feedback loops. Reconnect, sample-rate rebuild, and wake rebind to the same selected-output UID.

Before merge, PR #24 requires hardware acceptance on a real selected output to verify the reported authority mode, smooth volume/mute behavior, external device synchronization where supported, software fallback where hardware control is unavailable, and reconnect/sleep-wake behavior.
