# Notch Sixty — PR116 App Icon Masters

The user-approved, **full-resolution, original** image files are the only artwork source
of truth. They are committed here unchanged:

- `Notch-Sixty-dark-master.png`: espresso housing, **light cream VU meter**, bright orange needle
- `Notch-Sixty-light-master.png`: champagne housing, **dark VU meter**, bright orange needle

The image generator `ci/pr116_generate_icon_assets.py` produces all 20 PNGs under
`NotchSixty/Assets.xcassets/AppIcon.appiconset`, and all 4 PNGs for
`DockIconDark.imageset` and `DockIconLight.imageset`. The preexisting
`Contents.json` mappings and production app code remain unchanged.

The source files have opaque black outer backgrounds. The generator derives
the outer silhouette only from the light-housing master, applies this
**identical transparent alpha mask** to both designs, and resamples the
approved raster. It never redraws the dial, text, scale, needle or lighting.
It fails closed unless the distinct light/dark meter-face colors are present.
`generated-icon-manifest.json` records original master SHA-256s and all 24
output SHA-256s. `--check` verifies exact reproducibility.

The dedicated `PR116 — Generate Approved Icons` GitHub Actions workflow
operates only on `feature/pr116-final-app-icons`: on push or manual dispatch
it generates all 24 files, commits just the shipping PNGs + manifest to the
same branch, publishes review assets, and checks an unsigned arm64 Release
build against the newly committed head. It does not merge or mark any PR ready.

The historical `ci/generate_app_icons.swift` remains intact for its earlier
PR39 raster-preserving validation contract; **PR116's generator and the uploaded
masters are authoritative for the new colors and Dock icons.** Do not run the
older generator to overwrite these PR116 assets.

## Branch / release isolation

Stack this icon-only change on `feature/pr115-volume-feedback`. Leave PR115,
PR114, all ancestors and `main` unmodified, draft/open/unmerged.
Hardware tests, final owner artwork approval in a built app, production
signing, and release authority remain pending independent gates.
