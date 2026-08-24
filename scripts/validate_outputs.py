#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageStat

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {"iphone": (1242, 2688), "ipad": (2064, 2752)}
SLUGS = ["01-separate", "02-camera", "03-retention", "04-albums", "05-search", "06-batch", "07-private"]
LOCALES = ["ko-KR", "en-US", "de-DE", "es-ES", "ar-SA", "ja-JP", "zh-Hans", "zh-Hant", "fr-FR"]

errors = []
for locale in LOCALES:
    for device, size in EXPECTED.items():
        hashes = set()
        for slug in SLUGS:
            path = ROOT / "output" / locale / device / f"{slug}.png"
            if not path.exists():
                errors.append(f"missing: {path}")
                continue
            image = Image.open(path).convert("RGB")
            if image.size != size:
                errors.append(f"wrong size: {path} {image.size} != {size}")
            if sum(ImageStat.Stat(image).var) < 100:
                errors.append(f"low variance: {path}")
            digest = hash(image.tobytes())
            if digest in hashes:
                errors.append(f"duplicate: {path}")
            hashes.add(digest)

if errors:
    raise SystemExit("\n".join(errors))
print("OK: 9개 언어 × iPhone/iPad × 7장 규격 검증 완료")
