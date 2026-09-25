# Master Volume and Mute Control

PR #24 independently implements playback master volume from public Core Audio HAL properties and the proprietary realtime graph. Historical GPL volume-management code is not used as an implementation reference.

The user-selected physical output remains authoritative; Notch Sixty never silently follows the default output device. A readable+writable main-output scalar volume uses device authority and HAL change listeners. Otherwise volume falls back to a separate smoothed software master-gain stage. Mute uses the device property only when readable+writable; otherwise it uses software master gain.

Master volume remains separate from input preamp, automatic headroom, DSP output gain, and transport transition gain. Global DSP Bypass and Flat bypass processing but not playback volume or software mute. External listener callbacks read state only, preventing notification feedback loops. Reconnect, sample-rate rebuild, and wake rebind to the same selected-output UID.

Before merge, PR #24 requires hardware acceptance on a real selected output to verify the reported authority mode, smooth volume/mute behavior, external device synchronization where supported, software fallback where hardware control is unavailable, and reconnect/sleep-wake behavior.


## Fixed-volume output keyboard fallback

When the selected physical output exposes no writable device volume (for example a fixed-output USB DAC), Notch Sixty keeps the physical device selected and uses the existing smoothed software master gain as the volume authority. A passive public IOKit HID listener observes Consumer Control Volume Increment/Decrement usages and maps them to 1/16-scale master-volume steps. The listener is active only in software-DSP volume mode, never seizes or suppresses keyboard events, and requires the user's macOS Input Monitoring permission. Missing permission does not invalidate the audio route; it is tracked as a separate keyboard-control capability. Native writable device volume remains preferred when available. The legacy virtual/HAL driver architecture is not reintroduced.
