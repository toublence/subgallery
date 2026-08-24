---
name: subgallery-appstore-screenshots
description: Create conversion-focused App Store screenshots for the SubGallery iOS app using real app captures, exact iPhone 1242x2688 and iPad 2064x2752 canvases, and localized marketing copy for Korean, English, German, Spanish, Arabic, Japanese, Simplified Chinese, Traditional Chinese, and French. Use when asked to plan, compose, localize, validate, or export SubGallery App Store screenshots. Never fabricate app UI or advertise unverified features.
---

# SubGallery App Store Screenshots

Produce App Store screenshots that make the product understandable in the first 1–3 frames and preserve the clean native-iOS feel.

## Workflow

1. **Collect real captures.** Use only screenshots from the actual release build. Prefer localized UI captures for each locale. Do not generate or redraw app UI.
2. **Verify features before writing claims.** If a feature is not visible in the release build or cannot be verified from the project/screenshots, do not advertise it. In particular, do not claim Face ID, iCloud sync, Fake PIN, watermarking, or any other removed/incomplete feature.
3. **Choose the story.** Use the default 7-frame storyboard in `references/storyboard.md`. Replace a frame only when the release build has a stronger verified feature.
4. **Load localized copy.** Read `references/localized-copy.md` and use the matching locale. Adapt line breaks, not meaning. Do not literal-translate one locale into another when better native copy is already provided.
5. **Compose exact-size canvases.** Use `scripts/compose_store_screenshot.py` or an equivalent deterministic image compositor. Keep the real screenshot readable and undistorted.
6. **Validate.** Run `scripts/validate_outputs.py` on the export folder. Fix wrong sizes, missing files, duplicated frames, or unsupported claims before delivery.

## Required locales

Create all requested frames for these 9 locales unless the user explicitly narrows scope:

- `ko-KR` Korean
- `en-US` English
- `de-DE` German
- `es-ES` Spanish
- `ar-SA` Arabic
- `ja-JP` Japanese
- `zh-Hans` Simplified Chinese
- `zh-Hant` Traditional Chinese
- `fr-FR` French

For Arabic, use right-aligned copy and real RTL app screenshots when available. Never horizontally mirror an LTR screenshot to fake RTL.

## Required sizes

Export portrait PNGs only:

- iPhone: **1242 x 2688**
- iPad: **2064 x 2752**

Create both device sets for every locale.

## Visual rules

Follow `references/layout-spec.md`.

- Use a white or very light neutral background.
- Use large black system-style typography and one restrained app-blue accent.
- Keep one message per screenshot.
- Use the real app screenshot as the dominant visual; the marketing layer must never look like a fake app screen.
- Do not add phone/iPad hardware mockups, ornamental 3D objects, glossy gradients, heavy shadows, or decorative clutter.
- Never stretch screenshots. Preserve aspect ratio.
- Keep important UI away from crop edges.
- Headline: ideally 2 lines, max 3.
- Supporting line: max 2 short lines; omit when the headline is self-explanatory.
- The first three screenshots must communicate: **separate storage → direct capture → organized destination**.
- Product positioning: **Separate is the base value; lifecycle management is the differentiation.** SubGallery must still feel useful for permanent private storage, not only temporary photos.

## Product claims hierarchy

Prioritize these verified product ideas when available in the release build:

1. Photos/videos stored separately from the everyday Photos library.
2. Capture directly into SubGallery and choose a destination album.
3. User albums and default destinations for camera/import/share.
4. Retention rules such as keep forever, until done, or timed cleanup.
5. OCR/text search across stored images.
6. Batch select, move, export, pin, filter, sort, and delete.
7. Touch ID or PIN protection on supported devices.
8. Optional only if verified: purpose camera, share extension, “use and complete” actions, reminders, map/parking flows.

Do not make security claims stronger than the actual implementation. Do not imply encryption unless encryption is actually implemented and verified.

## Capture selection rules

Use screen content that proves the headline:

- Separate library claim → home/library with smart albums and user albums.
- Direct capture claim → live camera screen, preferably showing album destination or camera controls.
- Album organization claim → album list, destination selector, or album management screen.
- Retention claim → temporary storage/retention UI with actual status labels.
- OCR claim → real search query and matching results from text inside a photo.
- Batch claim → selection mode with multiple items selected and actions visible.
- Privacy claim → real Touch ID/PIN setting or authentication state; never fabricate a biometric dialog.

Avoid screenshots dominated by empty states, permission dialogs, debug text, App Store status bars from unrelated apps, test data, or unfinished settings.

## Localization rules

- Use native marketing language, not literal translation.
- Keep product name `SubGallery` unchanged.
- Keep `Touch ID` and `PIN` as platform/product terms where natural.
- Prefer locally familiar photo-library terms: e.g. Camera Roll/Photos library, Mediathek, fototeca, 写真, 相册/相簿, photothèque.
- If localized UI is unavailable, do not fake translated UI. Use the real UI capture and localize only the marketing text, then flag the limitation.
- Preserve correct punctuation and direction for Arabic, CJK, and European languages.

## File naming

Use this exact structure:

```text
output/
  ko-KR/
    iphone/01-separate.png ... 07-private.png
    ipad/01-separate.png ... 07-private.png
  en-US/
    ...
```

Use these frame slugs by default:

`01-separate`, `02-camera`, `03-retention`, `04-albums`, `05-search`, `06-batch`, `07-private`.

If an optional verified differentiator replaces a frame, keep the numeric order and use a descriptive slug.

## Quality gate

Before delivery, confirm:

- exact dimensions for every file;
- real release-build UI only;
- no unsupported feature claims;
- first screenshot explains the app without reading the App Store description;
- first three frames tell a coherent story;
- copy is readable at App Store thumbnail size;
- Arabic is RTL-aware;
- no text is clipped;
- screenshots remain sharp after scaling;
- iPad layouts are recomposed for iPad, not merely stretched iPhone artwork;
- every locale has the same feature order unless localization requires a deliberate change.

Return the export folder or zip plus a short manifest of frames, locales, and any features intentionally omitted because they were not verified.
