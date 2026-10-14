#!/usr/bin/env python3
"""PR116: make all macOS AppIcon and runtime DockIcon assets from owner-uploaded masters.

Source images are NEVER modified. The transparent outer silhouette is derived
from the lighter housing and applied IDENTICALLY to both variants. The meter,
lettering and orange needle stay the original approved raster artwork.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
MASTERS = ROOT / "design" / "app-icons"
ASSETS = ROOT / "NotchSixty" / "Assets.xcassets"
DARK = MASTERS / "Notch-Sixty-dark-master.png"
LIGHT = MASTERS / "Notch-Sixty-light-master.png"
MANIFEST = MASTERS / "generated-icon-manifest.json"
EXPECTED_MASTER_SIZE = (1254, 1254)
PNG_OPTIONS = {"format": "PNG", "compress_level": 9, "optimize": False}


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise SystemExit("PR116 icon validation failed: " + detail)


def digest(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def read_master(path: Path) -> Image.Image:
    require(path.is_file(), f"missing uploaded source: {path}")
    with Image.open(path) as src:
        require(src.format == "PNG", f"master must be PNG: {path.name}")
        require(src.size == EXPECTED_MASTER_SIZE, f"{path.name} must be 1254x1254, got {src.size}")
        require(src.mode in ("RGB", "RGBA"), f"{path.name} has unexpected color mode {src.mode}")
        return src.convert("RGB")


def common_silhouette(light: Image.Image) -> Image.Image:
    """Find the outer body per scanline, not the internal meter's dark areas.

    Only the light housing establishes the shared outer mask. Looking for the
    illuminated housing's outermost bright pixels per row avoids internal
    gaps and never selects scale numbers, meter darkness, or a needle segment.
    """
    w, h = light.size
    pixels = light.load()
    mask = Image.new("L", (w, h), 0)
    draw = ImageDraw.Draw(mask)
    active_rows = 0
    for y in range(h):
        first = None
        last = None
        for x in range(w):
            if max(pixels[x, y]) >= 43:
                if first is None:
                    first = x
                last = x
        if first is not None and last - first >= 100:
            draw.line((first, y, last, y), fill=255, width=1)
            active_rows += 1
    require(active_rows >= 900, f"light silhouette seems incomplete ({active_rows} rows)")
    mask = mask.filter(ImageFilter.GaussianBlur(radius=0.75))
    require(mask.getpixel((0, 0)) == 0 and mask.getpixel((w-1, h-1)) == 0,
            "transparency must cover outer corners")
    require(mask.getpixel((w//2, h//2)) == 255, "center of icon must be fully opaque")
    return mask


def metadata() -> list[tuple[Path, int, str]]:
    icons = ASSETS / "AppIcon.appiconset"
    data = json.loads((icons / "Contents.json").read_text(encoding="utf-8"))
    require(len(data["images"]) == 20, "AppIcon Contents.json must retain 20 slots")
    names: set[str] = set()
    dark_count = 0
    slots: list[tuple[Path, int, str]] = []
    for entry in data["images"]:
        name = entry["filename"]
        require(name.startswith("icon") and name.endswith(".png") and "/" not in name,
                f"invalid AppIcon filename: {name!r}")
        require(name not in names, f"duplicate AppIcon filename: {name}")
        names.add(name)
        dim = entry["size"].split("x")
        require(len(dim) == 2 and dim[0] == dim[1], f"non-square AppIcon: {name}")
        scale = entry["scale"]
        require(scale in ("1x", "2x"), f"bad icon scale: {scale}")
        size = int(dim[0]) * int(scale[0])
        require(size in (16, 32, 64, 128, 256, 512, 1024),
                f"unexpected AppIcon dimensions: {name}")
        dark = entry.get("appearances") == [{"appearance": "luminosity", "value": "dark"}]
        if dark:
            dark_count += 1
        slots.append((icons / name, size, "dark" if dark else "light"))
    require(dark_count == 10, f"need ten dark AppIcon entries; saw {dark_count}")

    for variant in ("Dark", "Light"):
        directory = ASSETS / f"DockIcon{variant}.imageset"
        data = json.loads((directory / "Contents.json").read_text(encoding="utf-8"))
        require(len(data["images"]) == 2, f"DockIcon{variant} must have two slots")
        for item in data["images"]:
            require(item["filename"] == f"DockIcon{variant}" + ("@2x.png" if item["scale"] == "2x" else ".png"),
                    f"bad DockIcon{variant} filename: {item!r}")
            require(item["scale"] in ("1x", "2x"), "invalid Dock scale")
            slots.append((directory / item["filename"], 1024 if item["scale"] == "2x" else 512,
                          variant.lower()))
    require(len(slots) == 24 and len({str(s[0]) for s in slots}) == 24,
            "expected 24 distinct shipping icon files")
    return slots


def prepare() -> tuple[dict[str, Image.Image], list[tuple[Path, int, str]]]:
    light, dark = read_master(LIGHT), read_master(DARK)
    # Different meter-face luminance is an intentional, owner-approved choice.
    x, y = 500, 580
    ll = sum(light.getpixel((x, y))) / 3
    dl = sum(dark.getpixel((x, y))) / 3
    require(ll + 45 < dl,
            "approved inverse meter scheme missing: light housing must have DARK scale; "
            "dark housing must have LIGHT scale")
    mask = common_silhouette(light)
    output = {}
    for variant, original in (("light", light), ("dark", dark)):
        rgba = original.convert("RGBA")
        rgba.putalpha(mask.copy())
        output[variant] = rgba
    return output, metadata()


def render(image: Image.Image, size: int) -> Image.Image:
    return image.resize((size, size), Image.Resampling.LANCZOS)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true",
                        help="Check committed outputs byte-for-byte; do not write")
    args = parser.parse_args()
    images, slots = prepare()
    from io import BytesIO
    assets = {}
    for path, size, variant in slots:
        output = render(images[variant], size)
        corner = output.getpixel((0, 0))
        require(corner[3] == 0, f"{path.name} has an opaque corner")
        require(output.getpixel((size // 2, size // 2))[3] == 255,
                f"{path.name} center is unexpectedly transparent")
        buffer = BytesIO()
        output.save(buffer, **PNG_OPTIONS)
        assets[path] = buffer.getvalue()

    # Both variants intentionally share exactly the same alpha mask.
    for size in (16, 32, 64, 128, 256, 512, 1024):
        la = render(images["light"], size).getchannel("A")
        da = render(images["dark"], size).getchannel("A")
        require(la.tobytes() == da.tobytes(), f"{size}px light/dark alpha masks differ")

    manifest = {
        "schemaVersion": 1,
        "milestone": "PR116",
        "sourceOfTruth": "owner-uploaded original PNG masters",
        "sourceSHA256": {path.name: digest(path.read_bytes()) for path in (DARK, LIGHT)},
        "transparentOuterMaskShared": True,
        "generatedSlotCount": len(slots),
        "artworkRedesigned": False,
        "productionApprovalAndHardwareAcceptance": False,
        "outputsSHA256": {
            str(path.relative_to(ROOT)): digest(content)
            for path, content in sorted(assets.items())
        },
    }
    encoded = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if args.check:
        for path, content in assets.items():
            require(path.is_file() and path.read_bytes() == content,
                    f"shipping icon missing or stale: {path.relative_to(ROOT)}")
        require(MANIFEST.is_file() and MANIFEST.read_bytes() == encoded,
                "generated manifest missing or stale")
        print(f"PR116 PASS: {len(slots)} icons validated from exact uploaded masters")
        return

    for path, content in assets.items():
        path.write_bytes(content)
    MANIFEST.write_bytes(encoded)
    print(f"PR116 generated {len(slots)} PNGs from approved masters; "
          "shared silhouette and inverse meter contrast verified")


if __name__ == "__main__":
    main()
