#!/usr/bin/env python3
import json
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import arabic_reshaper
from bidi.algorithm import get_display

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "store-assets" / "source"
TRANSLATIONS = ROOT / "store-assets" / "translations"
OUTPUT = ROOT / "output"

SOURCE_BY_SLUG = {
    "01-separate": "library.png",
    "02-camera": "camera.png",
    "03-retention": "retention.png",
    "04-albums": "albums.png",
    "05-search": "search.png",
    "06-batch": "batch.png",
    "07-private": "security.png",
}

SPECS = {
    "iphone": {"size": (1242, 2688), "panel": (121, 570, 1000), "headline": 92, "subtitle": 42, "radius": 54},
    "ipad": {"size": (2064, 2752), "panel": (192, 565, 1680), "headline": 100, "subtitle": 46, "radius": 58},
}

FOCUS_HEIGHT = {
    "iphone": {"albums.png": 1600, "batch.png": 1800, "retention.png": 2200, "search.png": 1500},
    "ipad": {"library.png": 1550, "albums.png": 1000, "batch.png": 1000, "retention.png": 1500, "search.png": 1000},
}


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=255)
    return mask


def font_settings(locale, bold):
    if locale == "ar-SA":
        name = "Tahoma Bold.ttf" if bold else "Tahoma.ttf"
        return f"/System/Library/Fonts/Supplemental/{name}", 0
    if locale == "ja-JP":
        weight = "W6" if bold else "W3"
        return str(next(Path("/System/Library/Fonts").glob(f"*{weight}.ttc"))), 0
    if locale.startswith("zh-"):
        return "/System/Library/Fonts/Hiragino Sans GB.ttc", 0
    if locale in {"en-US", "de-DE", "es-ES", "fr-FR"}:
        return "/System/Library/Fonts/HelveticaNeue.ttc", 1 if bold else 0
    return "/System/Library/Fonts/AppleSDGothicNeo.ttc", 8 if bold else 2


def display_text(text, locale):
    if locale != "ar-SA":
        return text
    return "\n".join(get_display(arabic_reshaper.reshape(line)) for line in text.splitlines())


def fitted_font(draw, text, locale, size, bold, max_width, spacing=5):
    path, index = font_settings(locale, bold)
    while size >= 34:
        font = ImageFont.truetype(path, size, index=index)
        box = draw.multiline_textbbox((0, 0), text, font=font, spacing=spacing)
        if box[2] - box[0] <= max_width:
            return font
        size -= 2
    return ImageFont.truetype(path, size, index=index)


def compose(locale, device, slug, headline, subtitle, source_name):
    spec = SPECS[device]
    width, height = spec["size"]
    canvas = Image.new("RGB", (width, height), "#F5F7FB")
    draw = ImageDraw.Draw(canvas)

    # Restrained system-blue accent; the app UI remains the visual focus.
    is_rtl = locale == "ar-SA"
    copy_margin = spec["panel"][0]
    accent_width = 70 if device == "iphone" else 96
    accent_x = width - copy_margin - accent_width if is_rtl else copy_margin
    draw.rounded_rectangle((accent_x, 110, accent_x + accent_width, 126), radius=8, fill="#0A84FF")

    headline = display_text(headline, locale)
    subtitle = display_text(subtitle, locale)
    max_copy_width = width - copy_margin * 2
    title_font = fitted_font(draw, headline, locale, spec["headline"], True, max_copy_width)
    subtitle_font = fitted_font(draw, subtitle, locale, spec["subtitle"], False, max_copy_width)
    title_x = width - copy_margin if is_rtl else copy_margin
    title_y = 155
    anchor = "ra" if is_rtl else "la"
    align = "right" if is_rtl else "left"
    draw.multiline_text((title_x, title_y), headline, font=title_font, fill="#111318", spacing=5, anchor=anchor, align=align)
    subtitle_y = 410 if device == "iphone" else 400
    draw.multiline_text((title_x, subtitle_y), subtitle, font=subtitle_font, fill="#667085", spacing=5, anchor=anchor, align=align)

    raw = Image.open(SOURCE / locale / device / source_name).convert("RGB")
    panel_x, panel_y, panel_width = spec["panel"]
    if device == "ipad" and source_name == "security.png":
        raw = raw.crop((520, 420, 1544, 2320))
        panel_x, panel_width = 482, 1100
    focus_height = FOCUS_HEIGHT.get(device, {}).get(source_name)
    if focus_height:
        raw = raw.crop((0, 0, raw.width, min(focus_height, raw.height)))
    if device == "ipad" and source_name not in ("camera.png", "security.png"):
        panel_x, panel_width = 112, 1840
    scale = panel_width / raw.width
    panel_height = round(raw.height * scale)
    raw = raw.resize((panel_width, panel_height), Image.Resampling.LANCZOS)
    mask = rounded_mask(raw.size, spec["radius"])

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_shape = Image.new("L", raw.size, 0)
    ImageDraw.Draw(shadow_shape).rounded_rectangle((0, 0, raw.width, raw.height), radius=spec["radius"], fill=90)
    shadow_shape = shadow_shape.filter(ImageFilter.GaussianBlur(28))
    shadow.paste((20, 35, 60, 75), (panel_x, panel_y + 18), shadow_shape)
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow)
    canvas.paste(raw, (panel_x, panel_y), mask)

    out_dir = OUTPUT / locale / device
    out_dir.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(out_dir / f"{slug}.png", format="PNG", optimize=True)


def main():
    requested = set(sys.argv[1:])
    translation_files = sorted(TRANSLATIONS.glob("*.json"))
    for translation_file in translation_files:
        locale = translation_file.stem
        if requested and locale not in requested:
            continue
        copy = json.loads(translation_file.read_text(encoding="utf-8"))
        for device in SPECS:
            for slug, values in copy.items():
                compose(locale, device, slug, values[0], values[1], SOURCE_BY_SLUG[slug])


if __name__ == "__main__":
    main()
