# Master Volume and Mute Control

PR #24 independently implements playback master volume from public Core Audio HAL properties, a public Core Graphics event-tap fallback for fixed-volume outputs, and the proprietary realtime graph. Historical GPL volume-management code is not used as an implementation reference.

The user-selected physical output remains authoritative; Notch Sixty never silently follows the default output device. A readable+writable output scalar volume uses device authority and HAL change listeners, including supported stereo channel elements when the device has no writable main element. Otherwise volume falls back to a separate smoothed software master-gain stage. Mute uses the device property only when readable+writable; otherwise it uses software master gain.

Master volume remains separate from input preamp, automatic headroom, DSP output gain, and transport transition gain. Global DSP Bypass and Flat bypass processing but not playback volume or software mute. External HAL listener callbacks read state only, preventing notification feedback loops. Reconnect, sample-rate rebuild, and wake rebind to the same selected-output UID.

## Fixed-volume output keyboard fallback

When the selected physical output exposes no writable device volume, such as a fixed-output USB DAC, Notch Sixty keeps that physical device selected and uses the existing smoothed software master gain as the volume authority. A listen-only public Core Graphics `CGEventTap` observes system-defined auxiliary-control Volume Up and Volume Down events and maps key-down events to 1/16-scale master-volume steps. The same `MasterVolumeConfiguration.level` therefore remains authoritative for both the in-app slider and keyboard control.

The event tap is active only in software-DSP volume mode. It never seizes, suppresses, synthesizes, or reposts keyboard events. Listening requires the user's macOS Input Monitoring permission, checked/requested through `CGPreflightListenEventAccess` and `CGRequestListenEventAccess`. Missing permission does not invalidate the selected audio route, transport, recovery, or device enumeration; it is tracked as a separate keyboard-control capability. Native writable device volume remains preferred when available.

The legacy virtual/HAL driver architecture is deliberately not reintroduced. The fallback remains inside the sandboxed application and uses public platform APIs only.

## Hardware acceptance

The original PR #24 hardware pass established that the in-app master slider and mute are smooth and responsive, and that the macOS global mute key works on the test chain. It also established that the selected Schiit Modi 5 behaves as a fixed-volume system output for volume-up/down purposes, so HAL device-volume synchronization alone cannot satisfy keyboard-volume parity.

A first fixed-output fallback using `IOHIDManager` Consumer Control observation successfully prompted for Input Monitoring but did not receive Volume Up/Down events on the real macOS 26 + Modi 5 test chain. That path was removed rather than retained as a second input mechanism.

The remaining focused acceptance gate is therefore limited to the listen-only Core Graphics event tap: after granting Input Monitoring permission and relaunching if macOS requires it, Volume Up and Volume Down must change the audible software master level and the in-app master slider must follow those changes. The engineering UI explicitly reports `Keys: Active`, `Keys: Permission Required`, or `Keys: Stopped` so hardware results can distinguish permission/tap setup from event delivery. Global mute must continue to work. No repeat of already-passed PR #24 audio-control tests is required unless this new path causes an unexpected regression.
