# PR39 App Identity / macOS 27 Status

## Shipping identity
- Uses the user-authored Notch Sixty analog-meter artwork from `DHDook/Notch-Sixty-Legacy/resources`.
- Light and dark macOS app-icon variants are installed in the production `AppIcon.appiconset`.
- The original 1024×1024 source SVGs are retained under `artwork/` for future layered-icon work.
- No Equaliser/GPL code or third-party branding asset is imported by this slice.

## macOS 27 shell
- The native `NavigationSplitView` sidebar remains the navigation foundation.
- Sidebar identity now uses the running app icon plus the `NOTCH SIXTY` / `Stereo DSP` wordmark.
- The app tint adopts the icon's amber/orange identity.
- Daily playback cards and system-profile controls use native Liquid Glass surfaces.
- The signature stereo VU instrument intentionally remains a warm, opaque analog face; Liquid Glass is applied around it, not through it.

## Icon Composer decision
Apple's current Icon Composer `.icon` format is the correct future path for a fully layered Liquid Glass app icon. PR39 does not fabricate that proprietary design artifact. The production build ships the verified owner-authored light/dark asset-catalog icon while retaining vector source artwork for a later Icon Composer pass.
