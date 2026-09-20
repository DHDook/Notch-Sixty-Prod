# Xcode Bootstrap

Create the initial app project as fresh project metadata owned by this repository. A
newly and independently generated Xcode project is permitted, including an
AI-generated `project.pbxproj`, provided that no project metadata or source is copied
from any prior repository. Validate generated metadata with Xcode and `xcodebuild` on
macOS CI.

## Create project

The project may be created with **File → New → Project → macOS → App** or generated
independently from the requirements below.

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

After Xcode or macOS CI validates the app with a clean build and test, commit only the
virgin project/target files plus newly generated assets needed by that project. Do not
import files from the historical GPL repository, BlackHole, the POC, or any other
existing application repository.

Suggested commit message:

```text
Initialize commercial macOS app project
```

After this bootstrap PR is merged, a separate PR should implement the production
AudioIO skeleton and lifecycle state machine under the rules in `AGENTS.md`.
