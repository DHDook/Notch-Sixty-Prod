# Design language (E34)

First version: E34 S0, 17 Nov 2026. S1 adds the shared values, components, status levels and formatters, and the
gallery. The flag is `e34.design-language` (`docs/FEATURE_FLAGS.md`). The minimum macOS is 27, so macOS 27 APIs are
used directly with no availability checks.

## Sources and what was checked

The rules below come from the macOS 27.2 SDK in Xcode 27.2 (the SwiftUI, SwiftUICore and AppKit interfaces and
headers). That is the ground truth for what an app can set. Apple's human interface guidelines web pages were not read
in S0 (no verified fetch of them was possible); the rules marked "guideline" restate Apple's published Liquid Glass
guidance from macOS 26 and need the owner's screen check at both system glass settings (E34 gap G16).

What the macOS 27.2 SDK shows:

- **Glass API is unchanged from macOS 26.** `glassEffect(_:in:)`, `Glass` (`regular`, `clear`, `identity`, `tint`,
  `interactive`), `GlassEffectContainer`, `glassEffectID`, `glassEffectUnion`, `glassEffectTransition`, the `.glass` and
  `.glassProminent` button styles, `ConcentricRectangle` and `containerShape` all carry macOS 26 availability. SwiftUI
  adds nothing for glass in 27 (its macOS 27 additions are reorderable containers, a tabs picker style and navigation
  transitions).
- **The system glass setting (clear or tinted) has no app API.** The press reports of a user setting that moves glass
  between clear and tinted are consistent with that: an app cannot read or set it. Every glass surface must therefore
  look right at both settings, and the app never picks "clear" or "tinted" for the user. (Using `Glass.clear` for a
  surface is a design choice about that surface, not that setting.)
- **The window, sidebar and toolbar shapes are the system's.** SwiftUI offers `windowToolbarStyle`,
  `toolbarBackgroundVisibility`, `backgroundExtensionEffect` and `scrollEdgeEffectStyle`; there is no call that sets the
  window corner radius or the sidebar shape. The app sets none.
- **Reduce Transparency and Increase Contrast** are environment values (`accessibilityReduceTransparency`,
  `colorSchemeContrast`); S6 reads them.

## Rules

1. **Glass is for controls and navigation that float above content, never for content.** A card that holds readable
   settings, readouts or text is content: it uses a plain background (system background styles), not `glassEffect`.
   Glass is right for the floating master-volume bar, popups, the sidebar and toolbar (system), and button styles
   (guideline).
2. **Use system containers, shapes and button styles; do not hand-set a value the system supplies.** No hand-set
   toolbar, sidebar, window or title-bar appearance. Corner radii inside a window use `ConcentricRectangle` or
   `containerShape` where a shape sits inside another, so corners stay concentric with the parent. Shared radii come
   from S1's values file (three radii).
3. **Group neighbouring glass in one `GlassEffectContainer`.** Two glass shapes that touch or sit within the container
   spacing are one container, so they blend and sample the same backdrop. Never nest one glass inside another, and
   never stack glass on glass (guideline).
4. **Buttons: `.glass` for all, `.glassProminent` for the one main action on a page (owner decision 4).** The
   `.bordered` and `.borderedProminent` styles are retired as S2 and S3 move each page. `.plain`, `.borderless` and
   `.link` stay for inline text-like actions only.
5. **Tint carries meaning.** `Glass.tint` and prominent glass use the user's macOS accent (owner decision 5); no brand
   colour. Status colour comes from S1's four status levels, each with an icon.
6. **Materials.** `.regularMaterial` backgrounds on cards are content cards under rule 1 and move to the plain card
   background. Materials stay only for transient overlays (the EQ hover capsules).
7. **Every glass surface is checked at both system glass settings (clear and tinted) and with Reduce Transparency on.**
   Text on glass uses the primary or secondary label styles, never a fixed colour.

## Audit of the code against the rules (E34 S0, 17 Nov 2026)

Counts from `git grep` over `NotchSixty/`:

| Finding | Count | Rule | Owner slice |
| --- | --- | --- | --- |
| `glassEffect(.regular, in: .rect(cornerRadius: 18/16/14/12))` on content cards, in 23 files (48 single-line plus 13 multi-line calls) | 61 | 1, 2 | S1 (card component), S2, S3 |
| `glassEffect(..., in: .capsule)` status chips beside each other, not in a container | 13 | 3 | S1 (status badge), S2, S3 |
| `.background(.regularMaterial, in: ...)` content cards | 19 | 6 | S1, S2, S3 |
| `GlassEffectContainer` around one glass shape or around content cards (Settings, Dashboard master controls, Equalizer) | 4 | 3 | S1, S3 |
| `.bordered`, `.borderedProminent` buttons | 91 | 4 | S2, S3 |
| Hand-set toolbar, sidebar or window appearance | 0 (only `windowToolbarStyle(.unified)`, a system style) | 2 | none |
| The Dashboard output popup panel (`NotchSixtyApp.swift`, solid glass over an opaque base) is a floating panel | 1 | 1 | none; it is a legitimate glass use |

S0 changes no page: converting a card is the card component's job, and doing it site by site here would add a second
set of hand-set values that S1 then replaces. The sites move when each page adopts the S1 components (S2, S3), with
the flag choosing the new look.

## Shared values and components (E34 S1)

Code is in `NotchSixty/UI/Design/`. Every value exists twice: `DesignStyle.current` (today's most common value) and
`DesignStyle.redesigned` (the new value). `DesignStyle.active` reads `e34.design-language`, so the flag switches the
whole app at once; pages that adopt the parts change by a few points at most without the flag (decision 7).

- **Shapes.** Three radii: small 8 (chips, fields), medium 12 / 14 (cards), large 18 / 22 (panels, sheets).
- **Spacing.** One scale: 4, 8, 12, 16, 20 / 24. No other padding or spacing value is written by hand.
- **Type.** Page title 22, section title 15, body 12 / 13 (text meant to be read), label 11 / 12, caption 11 (secondary
  notes only). The minimum is 11 points; nothing smaller is used.
- **Colour and status.** The accent is the user's macOS accent (no brand colour). Four status levels, each with a
  colour, an icon and a word: good (green, checkmark), attention (orange, triangle), problem (red, octagon), off
  (secondary, minus). Colour is never the only signal.
- **Buttons.** `DesignButton` with three roles: primary (`.glassProminent`, one per page), secondary (`.glass`),
  destructive (`.glass` tinted red, destructive role).
- **Components.** `DesignCard` (content, plain background, no glass), `DesignPageHeader` (title, subtitle, status, main
  action trailing), `DesignStatusBadge`, `DesignStateView` (empty, busy, stopped, failed), all taking a style.
- **Value formats (`DesignFormat`).** A space before the unit; true minus sign (U+2212); no negative zero; `signed`
  adds "+" for gains and offsets. dB one decimal ("-6.0 dB"); Hz whole below 1 kHz, then kHz with up to two decimals,
  trailing zeros trimmed ("63 Hz", "1.25 kHz", "20 kHz"); ms one decimal; percent from a fraction, whole ("50 %").
- **Gallery.** Debug builds only: Window > Design Gallery shows every component in every state at both styles.
