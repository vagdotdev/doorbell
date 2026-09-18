# Doorbell — macOS app icon

Approved pinhole design, exported 2026-09-18.

## Files

- `Doorbell.icns`: compiled icon for a native macOS app bundle.
- `AppIcon.appiconset/`: complete Xcode app-icon set, including `Contents.json`.
- `Doorbell.iconset/`: the ten PNG representations used by Apple's `iconutil`.
- `master-1024.png`: 1024 × 1024 sRGB RGBA production master.
- `preview.png`: actual-pixel sizes on light and dark backgrounds.
- `source/approved-concept.png`: the exact original approved image, unchanged.
- `source/alpha-extraction.png`: background-extraction output used only for its alpha mask.
- `validation.json`: export checks; `sha256.json`: file checksums.
- `export.py`: reproducible export and validation script (Python 3 + Pillow; macOS/Xcode).

## Included sizes

| macOS size | 1× pixels | 2× pixels |
| --- | --- | --- |
| 16 pt | 16 × 16 | 32 × 32 |
| 32 pt | 32 × 32 | 64 × 64 |
| 128 pt | 128 × 128 | 256 × 256 |
| 256 pt | 256 × 256 | 512 × 512 |
| 512 pt | 512 × 512 | 1024 × 1024 |

These are the complete raster representations in [Apple's iconset format](https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/IconSetType.html). The Xcode metadata follows [Apple's app-icon format](https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/AppIconType.html).

## Artwork preparation

The original lens, stars, glimmer, black tile and their proportions are retained. Only the outer gray presentation backdrop is transparent. Background extraction used built-in ChatGPT image generation; the export uses only that result's alpha mask with the **original approved RGB pixels**, avoiding generated changes to the artwork. Near-transparent/opaque mask noise is normalized, and all sizes are deterministically downsampled with Lanczos from the 1024 px master. No per-size image generation or sharpening is used.

## Use

For Xcode, drag `AppIcon.appiconset` into your existing asset catalog and select `AppIcon` as the target's app-icon set. For a manually packaged app, put `Doorbell.icns` in `Contents/Resources` and set `CFBundleIconFile` to `Doorbell.icns` in the app's `Info.plist` before signing.

This folder is an asset handoff. The existing app's resources and build configuration have not been replaced. The files are the conventional flattened macOS icon format, not a layered Icon Composer document.

To rebuild on a Mac with Xcode and Pillow installed:

```sh
python3 export.py
```

The export checks every PNG's dimensions and transparency, verifies all ten `iconutil` representations preserve dimensions, alpha and opaque artwork pixels, and compiles the app-icon catalog with Xcode's `actool`. The eight modern PNG entries round-trip exactly; the native legacy 16/32 px entries re-export translucent-edge RGB differently while retaining identical alpha and opaque RGB.
