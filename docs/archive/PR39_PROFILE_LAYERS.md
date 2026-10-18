# PR39 Content Presets / Playback System Profiles

PR39 separates media-dependent voicing from physical playback-system calibration.

## Content Preset owns
- stereo EQ banks and phase mode
- dynamics and loudness/tonal processing
- input preamp and headroom attenuation

## Playback System owns
- optional output-device UID association
- output trim
- balance/symmetry, speaker crossfeed, crosstalk cancellation, and inter-channel alignment delay
- bass management/crossover, sub polarity, and sub phase alignment
- room-correction FIR and speaker-correction IR

## Session state stays outside both layers
- master volume and mute
- global DSP bypass
- Processed / Reference / Delta audition mode
- metering and UI state

Both models are versioned and persisted in an atomic JSON archive under Application Support. Factory Content Presets are code-owned and immutable; user Content Presets and Playback System Profiles are persisted. Applying one layer preserves the fields owned by the other layer. A System Profile may be associated with an output UID; selecting a differently-associated system requires processing to be stopped before the route is changed.
