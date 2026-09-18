#!/usr/bin/env python3
"""Export the approved Doorbell art as macOS icons. Requires Pillow and macOS."""
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageCms, ImageDraw

ROOT = Path(__file__).resolve().parent
BASE_SIZES = (16, 32, 128, 256, 512)
PROFILE = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def save_png(image, path):
    image.save(path, format="PNG", icc_profile=PROFILE, optimize=True)


def main():
    approved = Image.open(ROOT / "source/approved-concept.png").convert("RGBA")
    extraction = Image.open(ROOT / "source/alpha-extraction.png").convert("RGBA")
    assert approved.size == extraction.size

    # Use only the extracted alpha: the artwork's RGB pixels remain the approved
    # source. Normalize extraction noise to a fully opaque tile / clear margin.
    alpha = extraction.getchannel("A").point(
        [0 if v <= 16 else 255 if v >= 240 else round((v - 16) * 255 / 224)
         for v in range(256)]
    )
    approved.putalpha(alpha)
    assert alpha.getpixel((0, 0)) == 0
    assert alpha.getpixel((approved.width // 2, approved.height // 2)) == 255
    master = approved.resize((1024, 1024), Image.Resampling.LANCZOS)
    save_png(master, ROOT / "master-1024.png")

    iconset = ROOT / "Doorbell.iconset"
    appiconset = ROOT / "AppIcon.appiconset"
    iconset.mkdir(exist_ok=True)
    appiconset.mkdir(exist_ok=True)
    images, checks = [], []
    for base in BASE_SIZES:
        for scale in (1, 2):
            pixels = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            image = master.resize((pixels, pixels), Image.Resampling.LANCZOS)
            save_png(image, iconset / name)
            shutil.copy2(iconset / name, appiconset / name)
            images.append({"filename": name, "idiom": "mac", "size": f"{base}x{base}", "scale": f"{scale}x"})
            with Image.open(iconset / name) as check:
                assert check.size == (pixels, pixels) and check.mode == "RGBA"
                assert check.getpixel((0, 0))[3] == 0
                assert check.getpixel((pixels // 2, pixels // 2))[3] == 255
            checks.append({"filename": name, "pixels": pixels, "scale": scale, "transparent_corners": True})
    (appiconset / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "Doorbell.icns")], check=True)

    with tempfile.TemporaryDirectory(prefix="doorbell-icon-verify-") as temp:
        temp = Path(temp)
        restored = temp / "roundtrip.iconset"
        subprocess.run(["/usr/bin/iconutil", "-c", "iconset", str(ROOT / "Doorbell.icns"), "-o", str(restored)], check=True)
        for check in checks:
            with Image.open(restored / check["filename"]) as image:
                expected = Image.open(iconset / check["filename"]).convert("RGBA")
                assert image.size == expected.size
                actual = image.convert("RGBA")
                assert actual.getchannel("A").tobytes() == expected.getchannel("A").tobytes()
                assert all(a[:3] == e[:3] for a, e in zip(actual.get_flattened_data(), expected.get_flattened_data()) if e[3] == 255)
                # iconutil's legacy 16/32px RGB+mask representations unpremultiply
                # translucent edges on PNG re-export. Modern PNG entries are exact.
                if check["filename"] not in ("icon_16x16.png", "icon_32x32.png"):
                    assert actual.tobytes() == expected.tobytes()
        catalog = temp / "Assets.xcassets"
        catalog.mkdir()
        (catalog / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}\n')
        shutil.copytree(appiconset, catalog / "AppIcon.appiconset")
        compiled = temp / "compiled"
        compiled.mkdir()
        process = subprocess.run([
            "xcrun", "actool", str(catalog), "--compile", str(compiled),
            "--platform", "macosx", "--minimum-deployment-target", "14.0",
            "--app-icon", "AppIcon", "--output-partial-info-plist", str(temp / "icons.plist"),
            "--output-format", "human-readable-text"
        ], check=True, capture_output=True, text=True)
        assert (compiled / "AppIcon.icns").exists(), process.stdout

    # Actual-pixel previews on light and dark backgrounds for edge / small-size QA.
    preview = Image.new("RGB", (1100, 650), "#eeeeee")
    draw = ImageDraw.Draw(preview)
    positions = [(16, 35), (32, 100), (64, 180), (128, 285), (256, 460)]
    for top, color, text_color in [(0, "#eeeeee", "#222222"), (325, "#22252b", "#eeeeee")]:
        draw.rectangle((0, top, 1100, top + 324), fill=color)
        draw.text((24, top + 16), "DOORBELL / APPROVED PINHOLE / NATIVE PIXEL SIZES", fill=text_color)
        for pixels, left in positions:
            icon = master.resize((pixels, pixels), Image.Resampling.LANCZOS)
            preview.paste(icon, (left, top + 48), icon)
            draw.text((left, top + 54 + pixels), f"{pixels}px", fill=text_color)
        icon = master.resize((256, 256), Image.Resampling.LANCZOS)
        preview.paste(icon, (780, top + 48), icon)
        draw.text((780, top + 310), "128pt @2x (256px)", fill=text_color)
    save_png(preview, ROOT / "preview.png")

    validation = {
        "png_variants": checks,
        "icns_roundtrip": "10 representations: correct dimensions, identical alpha and opaque RGB; 8 modern PNG entries match all RGBA pixels",
        "legacy_encoding": "Native iconutil 16px/32px RGB+mask entries differ only in translucent-edge RGB after PNG re-export.",
        "xcode_actool": "compiled successfully for macOS",
        "color_profile": "sRGB",
        "master_pixels": 1024,
        "artwork": "Original approved RGB; extracted and normalized outer alpha only."
    }
    (ROOT / "validation.json").write_text(json.dumps(validation, indent=2) + "\n")
    manifest = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(ROOT.rglob("*")) if p.is_file() and p.name != "sha256.json"}
    (ROOT / "sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Exported and validated 10 macOS sizes, ICNS, Xcode appiconset and preview in {ROOT}")


if __name__ == "__main__":
    main()
