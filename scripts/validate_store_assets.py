#!/usr/bin/env python3
import hashlib
import json
import statistics
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "output"
RAW = ROOT / "store-assets" / "raw"
TRANSLATIONS = ROOT / "store-assets" / "translations"
QA = ROOT / "store-assets" / "qa"
LOCALES = ["ko-KR", "en-US", "de-DE", "es-ES", "ar-SA", "ja-JP", "zh-Hans", "zh-Hant", "fr-FR"]
DEVICES = {"iphone": (1242, 2688), "ipad": (2064, 2752)}
FILENAMES = [
    "01-separate.png",
    "02-templates.png",
    "03-receipts.png",
    "04-documents.png",
    "05-qr.png",
    "06-travel-map.png",
    "07-album-automation.png",
]
ROUTES = [
    "library",
    "workflows",
    "receipt-report",
    "document-pdf",
    "qr-builder",
    "travel-map",
    "album-automation",
]
FORBIDDEN = ["주차", "parking", "face id", "searchable pdf", "icloud", "encryption"]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def meaningful_pixels(image: Image.Image) -> bool:
    sample = image.convert("RGB").resize((96, 96))
    channels = list(zip(*sample.getdata()))
    deviations = [statistics.pstdev(channel) for channel in channels]
    # Native iPad forms intentionally leave substantial system-background space.
    # Keep the threshold high enough to reject a blank/loading canvas while
    # accepting text-heavy, low-chroma SwiftUI screens.
    return max(deviations) > 8 and len(set(sample.getdata())) > 240


errors: list[str] = []
expected_final: list[Path] = []
expected_raw: list[Path] = []

for locale in LOCALES:
    translation_path = TRANSLATIONS / f"{locale}.json"
    if not translation_path.exists():
        errors.append(f"missing translation: {translation_path}")
        continue
    translation = json.loads(translation_path.read_text())
    if translation["locale"] != locale:
        errors.append(f"translation locale mismatch: {translation_path}")
    if locale == "ar-SA" and translation.get("direction") != "rtl":
        errors.append("Arabic translation is not RTL")
    copy_text = json.dumps(translation, ensure_ascii=False).lower()
    for forbidden in FORBIDDEN:
        if forbidden.lower() in copy_text:
            errors.append(f"forbidden claim in {translation_path}: {forbidden}")

    for device, size in DEVICES.items():
        for filename, route in zip(FILENAMES, ROUTES):
            final_path = OUTPUT / locale / device / filename
            raw_path = RAW / locale / device / f"{route}.png"
            expected_final.append(final_path)
            expected_raw.append(raw_path)

            if not final_path.exists():
                errors.append(f"missing final: {final_path}")
            else:
                with Image.open(final_path) as image:
                    if image.format != "PNG":
                        errors.append(f"not PNG: {final_path}")
                    if image.size != size:
                        errors.append(f"wrong dimensions {image.size}: {final_path}")
                    if not meaningful_pixels(image):
                        errors.append(f"blank or low-variance final: {final_path}")

            if not raw_path.exists():
                errors.append(f"missing source capture: {raw_path}")
            else:
                with Image.open(raw_path) as raw_image:
                    if raw_image.format != "PNG":
                        errors.append(f"source is not PNG: {raw_path}")
                    if device == "ipad" and raw_image.size != (2064, 2752):
                        errors.append(f"iPad source is not native 2064x2752: {raw_path} {raw_image.size}")
                    if device == "iphone" and (raw_image.width < 1200 or raw_image.height < 2600):
                        errors.append(f"iPhone source resolution is too small: {raw_path} {raw_image.size}")
                    if not meaningful_pixels(raw_image):
                        errors.append(f"blank or loading source: {raw_path}")

actual_final = sorted(OUTPUT.glob("*/*/*.png"))
actual_raw = sorted(RAW.glob("*/*/*.png"))
if len(actual_final) != 126:
    errors.append(f"expected 126 final PNGs, found {len(actual_final)}")
if len(actual_raw) != 126:
    errors.append(f"expected 126 source PNGs, found {len(actual_raw)}")
if set(actual_final) != set(expected_final):
    extras = sorted(set(actual_final) - set(expected_final))
    if extras:
        errors.append("unexpected final PNGs: " + ", ".join(map(str, extras)))

manifest_path = OUTPUT / "manifest.json"
if not manifest_path.exists():
    errors.append("missing output/manifest.json")
    manifest = {"images": []}
else:
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("buildConfiguration") != "Release":
        errors.append("manifest does not record a Release build")
    if manifest.get("imageCount") != 126 or len(manifest.get("images", [])) != 126:
        errors.append("manifest does not contain 126 image records")
    if any(not entry.get("textFits", False) for entry in manifest.get("images", [])):
        errors.append("one or more marketing text blocks did not fit")
    for entry in manifest.get("images", []):
        if entry["locale"] == "ar-SA" and entry.get("layoutDirection") != "rtl":
            errors.append(f"Arabic manifest entry is not RTL: {entry}")

for locale in LOCALES:
    for device in DEVICES:
        hashes = [digest(RAW / locale / device / f"{route}.png") for route in ROUTES if (RAW / locale / device / f"{route}.png").exists()]
        if len(hashes) == 7 and len(set(hashes)) != 7:
            errors.append(f"duplicate source screens within {locale}/{device}")

for locale in LOCALES:
    for route in ROUTES:
        phone = RAW / locale / "iphone" / f"{route}.png"
        tablet = RAW / locale / "ipad" / f"{route}.png"
        if phone.exists() and tablet.exists() and digest(phone) == digest(tablet):
            errors.append(f"iPad source reuses iPhone source: {locale}/{route}")

QA.mkdir(parents=True, exist_ok=True)
overview_tiles = []
for locale in LOCALES:
    for device in DEVICES:
        paths = [OUTPUT / locale / device / filename for filename in FILENAMES]
        if not all(path.exists() for path in paths):
            continue
        thumbs = []
        for path in paths:
            with Image.open(path) as image:
                thumb = image.convert("RGB")
                thumb.thumbnail((210, 455))
                thumbs.append(thumb.copy())
        sheet = Image.new("RGB", (7 * 220 + 20, 495), "white")
        draw = ImageDraw.Draw(sheet)
        draw.text((12, 8), f"{locale} · {device}", fill="black")
        for index, thumb in enumerate(thumbs):
            sheet.paste(thumb, (10 + index * 220, 32))
        sheet_path = QA / f"{locale}-{device}.png"
        sheet.save(sheet_path)
        row = sheet.copy()
        row.thumbnail((1260, 405))
        overview_tiles.append(row)

if overview_tiles:
    overview = Image.new("RGB", (1260, len(overview_tiles) * 405), "white")
    for index, tile in enumerate(overview_tiles):
        overview.paste(tile, (0, index * 405))
    overview.save(QA / "all-locales-overview.png")

report = {
    "passed": not errors,
    "finalPngCount": len(actual_final),
    "sourcePngCount": len(actual_raw),
    "locales": LOCALES,
    "devices": {key: list(value) for key, value in DEVICES.items()},
    "filenames": FILENAMES,
    "checks": {
        "exactCount": len(actual_final) == 126,
        "dimensions": not any("wrong dimensions" in error for error in errors),
        "nativeIPadSources": not any("iPad source is not native" in error for error in errors),
        "distinctRoutes": not any("duplicate source screens" in error for error in errors),
        "separateDeviceCaptures": not any("reuses iPhone source" in error for error in errors),
        "marketingTextFits": not any("text blocks did not fit" in error for error in errors),
        "forbiddenClaimsAbsent": not any("forbidden claim" in error for error in errors),
        "arabicRTL": not any("Arabic" in error and "RTL" in error for error in errors),
    },
    "errors": errors,
}
(OUTPUT / "validation-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

if errors:
    for error in errors:
        print(f"ERROR: {error}")
    raise SystemExit(1)

print("Validated 126 final PNGs, 126 real app captures, dimensions, localization metadata, RTL, and source uniqueness")
