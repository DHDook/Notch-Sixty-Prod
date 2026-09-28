import json
from pathlib import Path
from urllib.request import urlopen

BRANCH = "main"
LEGACY_BASE = "https://raw.githubusercontent.com/DHDook/Notch-Sixty-Legacy/main/resources"
ROOT = Path(".")
APPICON = ROOT / "NotchSixty/Assets.xcassets/AppIcon.appiconset"
ARTWORK = ROOT / "artwork"

ICON_FILES = [
    "icon_16x16.png", "icon_16x16@2x.png",
    "icon_32x32.png", "icon_32x32@2x.png",
    "icon_128x128.png", "icon_128x128@2x.png",
    "icon_256x256.png", "icon_256x256@2x.png",
    "icon_512x512.png", "icon_512x512@2x.png",
    "icon_dark_16x16.png", "icon_dark_16x16@2x.png",
    "icon_dark_32x32.png", "icon_dark_32x32@2x.png",
    "icon_dark_128x128.png", "icon_dark_128x128@2x.png",
    "icon_dark_256x256.png", "icon_dark_256x256@2x.png",
    "icon_dark_512x512.png", "icon_dark_512x512@2x.png",
]


def fetch(url: str) -> bytes:
    with urlopen(url, timeout=30) as response:
        return response.read()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError(f"Expected exactly one {label} match, found {text.count(old)}")
    return text.replace(old, new, 1)


APPICON.mkdir(parents=True, exist_ok=True)
for name in ICON_FILES:
    data = fetch(f"{LEGACY_BASE}/AppIcon.xcassets/AppIcon.appiconset/{name}")
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise RuntimeError(f"Legacy icon is not PNG: {name}")
    (APPICON / name).write_bytes(data)

ARTWORK.mkdir(parents=True, exist_ok=True)
for name in ("AppIcon-light.svg", "AppIcon-dark.svg"):
    data = fetch(f"{LEGACY_BASE}/{name}")
    if b"<svg" not in data[:512]:
        raise RuntimeError(f"Legacy artwork is not SVG: {name}")
    (ARTWORK / name).write_bytes(data)

sizes = [("16x16", "16x16"), ("16x16@2x", "16x16"), ("32x32", "32x32"), ("32x32@2x", "32x32"), ("128x128", "128x128"), ("128x128@2x", "128x128"), ("256x256", "256x256"), ("256x256@2x", "256x256"), ("512x512", "512x512"), ("512x512@2x", "512x512")]
images = []
for stem, size in sizes:
    scale = "2x" if stem.endswith("@2x") else "1x"
    images.append({"filename": f"icon_{stem}.png", "idiom": "mac", "scale": scale, "size": size})
for stem, size in sizes:
    scale = "2x" if stem.endswith("@2x") else "1x"
    images.append({
        "appearances": [{"appearance": "luminosity", "value": "dark"}],
        "filename": f"icon_dark_{stem}.png", "idiom": "mac", "scale": scale, "size": size,
    })
(APPICON / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

root_path = ROOT / "NotchSixty/UI/ProductionRootView.swift"
root = root_path.read_text()
root = replace_once(root, "import Foundation\nimport SwiftUI\n", "import AppKit\nimport Foundation\nimport SwiftUI\n", "AppKit import")
root = replace_once(
    root,
    '''        NavigationSplitView {\n            List(ProductionSection.allCases, selection: $selection) { section in\n                Label(section.title, systemImage: section.systemImage).tag(section)\n            }\n            .navigationTitle("Notch Sixty")\n            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)\n        } detail: {''',
    '''        NavigationSplitView {\n            VStack(spacing: 0) {\n                ProductionSidebarBrand()\n                Divider()\n                List(ProductionSection.allCases, selection: $selection) { section in\n                    Label(section.title, systemImage: section.systemImage).tag(section)\n                }\n                .listStyle(.sidebar)\n            }\n            .navigationTitle("Notch Sixty")\n            .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 290)\n        } detail: {''',
    "production sidebar",
)
root = replace_once(
    root,
    '''        .frame(minWidth: 980, minHeight: 680)\n        .task { product.prepareForUse() }''',
    '''        .tint(Color(red: 0.91, green: 0.58, blue: 0.24))\n        .frame(minWidth: 980, minHeight: 680)\n        .task { product.prepareForUse() }''',
    "root tint",
)
brand = '''\nprivate struct ProductionSidebarBrand: View {\n    var body: some View {\n        HStack(spacing: 12) {\n            if let icon = NSApplication.shared.applicationIconImage {\n                Image(nsImage: icon)\n                    .resizable()\n                    .interpolation(.high)\n                    .frame(width: 44, height: 44)\n                    .clipShape(.rect(cornerRadius: 10))\n            }\n\n            VStack(alignment: .leading, spacing: 2) {\n                Text("NOTCH SIXTY")\n                    .font(.headline.weight(.semibold))\n                    .tracking(1.5)\n                Text("Stereo DSP")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)\n            }\n            Spacer(minLength: 0)\n        }\n        .padding(.horizontal, 14)\n        .padding(.vertical, 12)\n        .accessibilityElement(children: .combine)\n        .accessibilityLabel("Notch Sixty Stereo DSP")\n    }\n}\n\n'''
root = replace_once(root, "private struct ProductionDashboardView: View {", brand + "private struct ProductionDashboardView: View {", "sidebar brand insertion")
root = root.replace(".background(.quaternary.opacity(0.22), in: .rect(cornerRadius: 18))", ".glassEffect(.regular, in: .rect(cornerRadius: 18))")
root = root.replace(".background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 18))", ".glassEffect(.regular, in: .rect(cornerRadius: 18))")
root_path.write_text(root)

profile_path = ROOT / "NotchSixty/UI/ProductionProfileToolbar.swift"
profile = profile_path.read_text()
profile = replace_once(
    profile,
    '''        .help(\n            "Playback System: output association, crossover, alignment, output trim, room correction, and speaker correction"\n        )''',
    '''        .buttonStyle(.glass)\n        .help(\n            "Playback System: output association, crossover, alignment, output trim, room correction, and speaker correction"\n        )''',
    "system profile glass style",
)
profile_path.write_text(profile)

validator = ROOT / "ci/validate_pr39_app_identity.py"
validator.write_text('''#!/usr/bin/env python3\nimport json\nfrom pathlib import Path\n\nroot = Path(__file__).resolve().parents[1]\nmanifest = json.loads((root / "NotchSixty/Assets.xcassets/AppIcon.appiconset/Contents.json").read_text())\nimages = manifest["images"]\nassert len(images) == 20, f"expected 20 macOS app icon variants, found {len(images)}"\nlight = [image for image in images if "appearances" not in image]\ndark = [image for image in images if image.get("appearances") == [{"appearance": "luminosity", "value": "dark"}]]\nassert len(light) == 10 and len(dark) == 10\nfor image in images:\n    path = root / "NotchSixty/Assets.xcassets/AppIcon.appiconset" / image["filename"]\n    assert path.exists(), f"missing app icon: {path.name}"\n    assert path.read_bytes().startswith(b"\\x89PNG\\r\\n\\x1a\\n"), f"invalid PNG: {path.name}"\nfor source in ("AppIcon-light.svg", "AppIcon-dark.svg"):\n    path = root / "artwork" / source\n    assert path.exists() and "<svg" in path.read_text()\nui = (root / "NotchSixty/UI/ProductionRootView.swift").read_text()\nassert "import AppKit" in ui\nassert "NSApplication.shared.applicationIconImage" in ui\nassert "ProductionSidebarBrand()" in ui\nassert ".listStyle(.sidebar)" in ui\nassert ".tint(Color(red: 0.91, green: 0.58, blue: 0.24))" in ui\nassert ui.count(".glassEffect(.regular, in: .rect(cornerRadius: 18))") >= 4\nassert 'Text("NOTCH SIXTY")' in ui\nassert "Color(red: 0.94, green: 0.89, blue: 0.73)" in ui, "signature VU face must remain warm and opaque"\nprofiles = (root / "NotchSixty/UI/ProductionProfileToolbar.swift").read_text()\nassert profiles.count(".buttonStyle(.glass)") >= 3\nprint("PR39 app identity / Liquid Glass validation passed")\n''')

doc = ROOT / "docs/PR39_APP_IDENTITY_STATUS.md"
doc.write_text('''# PR39 App Identity / macOS 27 Status\n\n## Shipping identity\n- Uses the user-authored Notch Sixty analog-meter artwork from `DHDook/Notch-Sixty-Legacy/resources`.\n- Light and dark macOS app-icon variants are installed in the production `AppIcon.appiconset`.\n- The original 1024×1024 source SVGs are retained under `artwork/` for future layered-icon work.\n- No Equaliser/GPL code or third-party branding asset is imported by this slice.\n\n## macOS 27 shell\n- The native `NavigationSplitView` sidebar remains the navigation foundation.\n- Sidebar identity now uses the running app icon plus the `NOTCH SIXTY` / `Stereo DSP` wordmark.\n- The app tint adopts the icon's amber/orange identity.\n- Daily playback cards and system-profile controls use native Liquid Glass surfaces.\n- The signature stereo VU instrument intentionally remains a warm, opaque analog face; Liquid Glass is applied around it, not through it.\n\n## Icon Composer decision\nApple's current Icon Composer `.icon` format is the correct future path for a fully layered Liquid Glass app icon. PR39 does not fabricate that proprietary design artifact. The production build ships the verified owner-authored light/dark asset-catalog icon while retaining vector source artwork for a later Icon Composer pass.\n''')

print("PR39 app identity implementation generated")
