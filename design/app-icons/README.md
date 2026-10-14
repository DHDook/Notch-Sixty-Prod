# Notch Sixty — Final App Icon Masters

This folder holds the two **owner-approved raster source images** used to generate the app's light and dark icon variants.

## Upload these two PNGs

- `Notch-Sixty-dark-master.png` — approved espresso/dark housing
- `Notch-Sixty-light-master.png` — approved champagne/light housing

Upload the **original full-resolution PNG images without resizing, recoloring, or modifying them**. These two images are the sole visual source of truth for the upcoming icon-generation work.

## After both master files are uploaded

The next work item will generate and verify the required PNGs for:
- `NotchSixty/Assets.xcassets/AppIcon.appiconset/` (light/default and dark at all required macOS sizes);
- `NotchSixty/Assets.xcassets/DockIconLight.imageset/`;
- `NotchSixty/Assets.xcassets/DockIconDark.imageset/`.

The generation step must preserve the approved artwork, remove the opaque black background outside the rounded-square housing, retain identical layout/alignment, and validate transparency, pixel dimensions, and the existing `Contents.json` contracts. Do not replace shipping assets before approval.

## Integration safety

This icon-only branch is stacked on `feature/pr115-volume-feedback`. Do not modify or merge PR115, PR114, other draft predecessors, or `main`. User hardware acceptance and production release authorizations remain separate.
