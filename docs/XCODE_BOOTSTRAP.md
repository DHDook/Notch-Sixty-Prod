# Xcode Bootstrap

Create the initial app project locally in Xcode so Xcode owns the generated project metadata.

## Create project

Use **File → New → Project → macOS → App**.

Recommended settings:
- Product Name: `Notch Sixty`
- Interface: SwiftUI
- Language: Swift
- Storage: None
- Include tests: Yes
- Deployment target: current supported macOS baseline for the commercial release

Use a new commercial bundle identifier. Do not reuse `net.knage.equaliser` or any historical identifier.

## Required target settings
- App Sandbox: ON
- Hardened Runtime: use the normal modern Xcode signing posture appropriate to the selected distribution path
- Apple Silicon is the supported architecture

Do not add:
- audio HAL driver targets
- privileged helper targets
- kernel/system extensions
- updater frameworks
- headphone/multichannel targets

## Initial source groups/directories

After the virgin app builds, organize source toward:

```text
NotchSixty/
  App/
  Audio/
    CoreAudio/
    Devices/
    Routing/
    Realtime/
  DSP/
    Core/
    EQ/
    Filters/
    Metering/
  State/
  Persistence/
  Diagnostics/
  UI/
NotchSixtyTests/
```

Do not create empty placeholder Swift files merely to force this hierarchy. Add directories as real components are introduced.

## First local commit

After Xcode generates the app and a clean build/test succeeds, commit only the virgin project/target files plus any Xcode-generated assets needed by that project. Do not import files from the historical GPL repository or the POC.

Suggested commit message:

```text
Initialize commercial macOS app project
```

Once that commit is on `main`, the next PR should implement the production AudioIO skeleton and lifecycle state machine under the rules in `AGENTS.md`.
