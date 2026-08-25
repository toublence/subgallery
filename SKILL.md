---
name: subgallery-appstore-screenshots
description: >-
  Create the complete App Store screenshot set for the SubGallery iOS/iPadOS app from real app UI. Use when Codex needs to plan, capture, compose, localize, validate, or regenerate SubGallery screenshots for iPhone and iPad. Produce exactly 7 frames per device for Korean, English, German, Spanish, Arabic, Japanese, Simplified Chinese, Traditional Chinese, and French using the fixed current-product storyboard of separate storage, purpose workflows, receipt report, PDF documents, QR creation, travel map, and album automation. Never fabricate app UI or advertise unverified behavior.
---

# SubGallery App Store Screenshots

Create the final App Store screenshots for the current SubGallery product. Treat this file as the source of truth for screenshot story, capture targets, copy, localization, output sizes, naming, and quality gates.

## Non-negotiable rules

- Use only real SubGallery UI from the current project. Never redraw, imitate, or generate fake app screens.
- Synthetic fixture data is allowed only to make the real shipping UI readable and deterministic.
- Keep screenshot-only routing/data behind the existing screenshot mode or `#if DEBUG`; do not change production behavior to obtain screenshots.
- Inspect the current local working tree before doing any screenshot work. The local tree is the source of truth.
- Verify every advertised feature exists and works in the current build before capturing it.
- If one of the seven required features is genuinely missing or broken, stop and report it instead of fabricating a screenshot.
- Do not advertise Face ID, encryption, secret vault behavior, fake PIN, parking workflows, watermarking, or any other feature not verified in the current build.
- Do not show debug text, permission alerts, test banners, console overlays, empty states, placeholder UI, or unrelated system screens.
- Do not add iPhone/iPad hardware mockups, 3D objects, glossy gradients, fake UI chrome, or decorative clutter.
- Preserve the real screenshot aspect ratio. Never stretch UI.
- The marketing text belongs outside the app capture. Never place marketing copy inside the captured app UI.
- Do not change the feature order between locales or devices.

## Product story

The screenshots must communicate this progression:

1. **Separate** — SubGallery keeps selected photos/videos apart from the everyday Photos library.
2. **Purpose** — different photo purposes get different workflows.
3. **Receipt** — receipt photos become a useful expense report.
4. **Document** — document photos become a multi-page PDF.
5. **QR** — users can create reusable QR codes inside SubGallery.
6. **Travel** — location-aware travel photos become a map/timeline experience.
7. **My Albums** — user-created albums gain their own management/automation rules.

This is the final 7-frame story. Do not fall back to the old sequence of camera, retention, OCR search, batch editing, and PIN unless the user explicitly asks for the old campaign.

## Required deliverables

Create all 126 final PNG files:

- 9 locales
- 2 device families
- 7 frames

Required locales:

- `ko-KR` — Korean
- `en-US` — English
- `de-DE` — German
- `es-ES` — Spanish
- `ar-SA` — Arabic
- `ja-JP` — Japanese
- `zh-Hans` — Simplified Chinese
- `zh-Hant` — Traditional Chinese
- `fr-FR` — French

Required output sizes:

- iPhone: **1242 x 2688** portrait PNG
- iPad: **2064 x 2752** portrait PNG

Create this exact structure:

```text
output/
  ko-KR/
    iphone/
      01-separate.png
      02-workflows.png
      03-receipt-report.png
      04-document-pdf.png
      05-qr-builder.png
      06-travel-map.png
      07-album-automation.png
    ipad/
      01-separate.png
      02-workflows.png
      03-receipt-report.png
      04-document-pdf.png
      05-qr-builder.png
      06-travel-map.png
      07-album-automation.png
  en-US/
    ...same structure...
  de-DE/
  es-ES/
  ar-SA/
  ja-JP/
  zh-Hans/
  zh-Hant/
  fr-FR/
```

Also create `output/manifest.json` containing locale, device, frame number, slug, dimensions, headline, supporting copy, and source capture identifier for every final image.

## Step 1 — Inspect and verify the current app

Before modifying screenshot automation:

1. Read the current screenshot mode, fixture seeding, launch arguments, localization handling, and composition/validation scripts already present in the repository.
2. Inspect the current implementations of:
   - `LibraryView`
   - Receipt template/report
   - Document template / document builder / `PDFDocumentViewer`
   - QR template / QR builder
   - Travel template / map
   - `AlbumAutomationView`
3. Confirm the seven screenshots below can be produced from real UI.
4. Reuse existing screenshot automation where possible. Extend it only where required for these seven routes.
5. Do not refactor unrelated production code while creating screenshots.

## Step 2 — Create deterministic screenshot routes

Use the existing `-store-screenshot` mechanism if present. Add only screenshot-only routes needed for the final campaign.

Preferred route identifiers:

```text
library
workflows
receipt-report
document-pdf
qr-builder
travel-map
album-automation
```

A route may seed deterministic local data, select the relevant view, scroll to the intended region, and dismiss transient UI. It must render the same real SwiftUI views used by production.

Fixture expectations:

- Use realistic but fictional data.
- Do not use personal names, phone numbers, addresses, receipts, or photos from real users.
- Use enough data to make reports/maps/documents look intentional rather than empty.
- Keep fixture data stable between runs so regenerated screenshots are deterministic.
- Screenshot fixtures must not persist into a normal app launch.

## Frame specifications

### 01 — `separate`

**Message:** SubGallery is a separate home for selected photos and videos.

**Real UI target:** `LibraryView` home.

**Fixture:** show meaningful counts/covers without clutter. Make the structure `보관함 / 내 앨범 / 템플릿` visually understandable.

**iPhone capture:**
- Start at the top of the home screen.
- Keep the main library cards visible.
- Show enough of `내 앨범` and `템플릿` to prove this is an organized separate library.
- Avoid search text and modal sheets.

**iPad capture:**
- Use the native iPad home layout.
- Show the wider library grid plus user albums/templates in the same composition when possible.
- Do not crop the iPhone screenshot for iPad.

### 02 — `workflows`

**Message:** different photo purposes get different workflows.

**Real UI target:** the `템플릿` section of the real home screen.

**Required visible templates:** Receipt, Document, QR, Travel.

**iPhone capture:**
- Scroll the real home screen until the template cards dominate the screenshot.
- Make all four template cards visible if possible.
- Keep real bottom import/camera controls only when they do not crowd the templates.

**iPad capture:**
- Use the native iPad template grid.
- Prefer a composition where all four template cards are clearly readable at once.

Do not claim every template is automatically classified. The message is purpose-specific management/workflows, not universal automatic detection.

### 03 — `receipt-report`

**Message:** receipts become an expense report.

**Real UI target:** actual Receipt Report first viewport.

**Fixture:** seed enough fictional receipts to show useful report content: total spending, count, average/largest payment, merchant insight, and compact trend/summary where the current UI supports them.

**iPhone capture:**
- Capture the report overview, not a single receipt photo.
- The first viewport must look information-dense enough to justify the feature.
- Avoid an empty chart or a report with only one receipt.

**iPad capture:**
- Use the real iPad report layout.
- Populate enough data so the wider canvas does not look sparse.

Do not claim accounting, tax filing, bank sync, or financial advice.

### 04 — `document-pdf`

**Message:** multiple document pages become one PDF.

**Real UI target:** actual `PDFDocumentViewer` displaying a generated multi-page PDF.

**Fixture:** create a fictional 3-page document through the existing document/PDF pipeline when possible.

**iPhone capture:**
- Show the dedicated PDF viewer.
- Make page count/navigation visible, such as `1 / 3` or the current equivalent.
- Show enough of the PDF page to prove it is a document viewer.

**iPad capture:**
- Use the native iPad PDF viewer.
- If the current UI has a page thumbnail sidebar/popover/strip, show it naturally.
- Never fabricate a thumbnail sidebar that the app does not have.

Do not use the phrase “searchable PDF” unless the actual exported `.pdf` contains a verified text layer. The screenshot campaign only claims PDF creation.

### 05 — `qr-builder`

**Message:** create reusable QR codes inside SubGallery.

**Real UI target:** actual QR builder with a visible generated QR preview.

**Fixture:** use a safe fictional URL, Wi-Fi configuration, or contact payload. Prefer the visually cleanest type supported by the real builder.

**iPhone capture:**
- Show the QR type/input plus large QR preview and the real save action if it fits.
- QR must be scannable and generated by the actual app code.

**iPad capture:**
- Use the native iPad builder layout.
- Take advantage of the wider canvas to show input and preview without adding a fake split view.

Do not advertise QR features that are not implemented by the current builder.

### 06 — `travel-map`

**Message:** travel photos can be revisited on a map/timeline.

**Real UI target:** actual Travel Map view.

**Fixture:** seed fictional travel photos with valid coordinates across several nearby/recognizable locations. Use generated or repository-safe fixture images only.

**iPhone capture:**
- Show map pins/regions and the current travel photo/timeline UI if visible in the first viewport.
- Prefer a visually interesting map scale; do not zoom out to an empty world map.

**iPad capture:**
- Use the native iPad map layout.
- Let the map use the width; keep enough photo/timeline context to show this is the user’s travel collection, not a generic map app.

Never overwrite imported EXIF locations merely to create screenshot fixtures in production code. Screenshot fixture coordinates must be isolated to screenshot mode.

### 07 — `album-automation`

**Message:** My Albums can manage photos with album-specific rules.

**Real UI target:** actual `AlbumAutomationView` for a fictional user album.

**Fixture:** create a user album with readable current settings. Prefer a realistic example such as `Project` / `Study` / a localized neutral album name.

**iPhone capture:**
- Show the top of Album Automation with basic rules and at least one advanced/Premium rule visible if that is how the current UI is designed.
- The screen must clearly show retention/management rules rather than a plain folder.

**iPad capture:**
- Use the native iPad automation/settings layout.
- Keep the rule hierarchy readable; do not leave a large empty right side.

Do not imply that every rule is Free. Do not add a marketing “Free/Premium” badge unless it exists in the real UI.

## Marketing composition

Use a clean editorial layer around the real capture.

### iPhone final canvas — 1242 x 2688

- Background: white or very light neutral.
- Outer horizontal margin: about 72 px.
- Headline region: top ~120–460 px.
- Headline: large, bold, system-style, ideally 2 lines, max 3.
- Supporting line: below headline with ~24–36 px gap, max 2 short lines.
- Real app capture begins around ~650–760 px and dominates the remaining canvas.
- Keep app capture width around 1080–1120 px while preserving aspect ratio.
- Rounded clipping around the app capture is allowed; subtle shadow only if already used by the current composition script.
- Center-aligned marketing copy is preferred for Korean/Japanese/Chinese. Use natural alignment for European languages when it improves line breaks.

### iPad final canvas — 2064 x 2752

- Recompose; never scale up the iPhone artwork.
- Background: same campaign background as iPhone.
- Outer horizontal margin: about 110–130 px.
- Headline region: top ~130–500 px.
- Prefer left-aligned headline/support for LTR languages to use the iPad width well.
- For Arabic, right-align the marketing copy.
- Real iPad app capture begins around ~600–700 px and should occupy most of the remaining canvas.
- Keep the real native iPad UI readable rather than excessively shrinking it to show the whole device.

Use installed system fonts only. Do not package or distribute font files.

## Fixed localized marketing copy

Use these meanings and wording as the default. You may adjust line breaks to prevent clipping, but do not change the product claim or feature order. Keep `SubGallery`, `PDF`, `QR`, and `Wi-Fi` unchanged where natural.

### `ko-KR`

1. **필요한 사진만\n따로 보관하세요** — 사진 앱과 섞지 않고 SubGallery에 따로 보관하세요.
2. **사진의 목적에 맞게\n다르게 관리** — 영수증 · 문서 · QR · 여행을 목적별 기능으로 관리하세요.
3. **영수증이\n지출 리포트로** — 승인 금액을 모아 지출 흐름과 결제 패턴을 확인하세요.
4. **사진을 모아\n하나의 PDF로** — 문서를 스캔하고 여러 페이지를 하나의 PDF로 만드세요.
5. **QR도\n직접 만들어 보세요** — 링크 · Wi-Fi · 연락처를 QR로 만들어 보관하세요.
6. **여행 사진을\n지도 위에서 다시** — 사진 위치와 여행의 흐름을 지도와 타임라인으로 확인하세요.
7. **내 앨범도\n규칙대로 관리** — 보관 기간과 자동 정리 규칙을 앨범마다 설정하세요.

### `en-US`

1. **Keep what you need,\nseparate from Photos** — Store selected photos and videos in SubGallery, away from your everyday library.
2. **Different photos,\ndifferent workflows** — Receipts, documents, QR codes, and trips each get purpose-built tools.
3. **Turn receipts into\nan expense report** — Bring payment amounts together to see spending trends and patterns.
4. **Multiple pages,\none PDF** — Scan documents and combine multiple pages into a single PDF.
5. **Create QR codes\nyou can reuse** — Turn links, Wi-Fi, and contacts into QR codes and keep them in SubGallery.
6. **Revisit your trips\non the map** — See photo locations and travel moments on a map and timeline.
7. **Your albums,\nyour rules** — Set retention and automatic cleanup rules for each album.

### `de-DE`

1. **Nur was du brauchst,\ngetrennt von Fotos** — Bewahre ausgewählte Fotos und Videos separat in SubGallery auf.
2. **Für jeden Zweck\nder passende Workflow** — Belege, Dokumente, QR-Codes und Reisen erhalten passende Werkzeuge.
3. **Aus Belegen wird\nein Ausgabenbericht** — Fasse Zahlbeträge zusammen und erkenne Ausgabenverlauf und Muster.
4. **Mehrere Seiten,\neine PDF** — Scanne Dokumente und fasse mehrere Seiten in einer PDF zusammen.
5. **Eigene QR-Codes\nerstellen** — Verwandle Links, Wi-Fi und Kontakte in QR-Codes und bewahre sie auf.
6. **Reisen auf der Karte\nneu erleben** — Sieh Fotoorte und Reisemomente auf Karte und Zeitleiste.
7. **Deine Alben,\ndeine Regeln** — Lege Aufbewahrung und automatische Bereinigung pro Album fest.

### `es-ES`

1. **Guarda solo lo necesario,\nseparado de Fotos** — Mantén las fotos y vídeos que elijas aparte en SubGallery.
2. **Cada tipo de foto,\nsu propio flujo** — Recibos, documentos, QR y viajes tienen herramientas para su propósito.
3. **Convierte recibos en\nun informe de gastos** — Reúne importes y revisa tendencias y patrones de gasto.
4. **Varias páginas,\nun solo PDF** — Escanea documentos y reúne varias páginas en un único PDF.
5. **Crea tus propios\ncódigos QR** — Convierte enlaces, Wi-Fi y contactos en QR y guárdalos en SubGallery.
6. **Revive tus viajes\nen el mapa** — Consulta lugares y momentos del viaje en el mapa y la cronología.
7. **Tus álbumes,\ntus reglas** — Define conservación y limpieza automática para cada álbum.

### `ar-SA`

1. **احتفظ بما تحتاجه فقط\nبعيدًا عن تطبيق الصور** — احفظ الصور والفيديوهات التي تختارها بشكل منفصل داخل SubGallery.
2. **لكل نوع من الصور\nطريقة إدارة مناسبة** — الإيصالات والمستندات وQR والسفر، لكل منها أدوات مخصصة.
3. **حوّل الإيصالات\nإلى تقرير مصروفات** — اجمع مبالغ الدفع وراجع اتجاهات الإنفاق وأنماطه.
4. **عدة صفحات\nفي ملف PDF واحد** — امسح المستندات واجمع صفحات متعددة في ملف PDF واحد.
5. **أنشئ رموز QR\nالخاصة بك** — حوّل الروابط وWi-Fi وجهات الاتصال إلى رموز QR واحفظها.
6. **استرجع رحلاتك\nعلى الخريطة** — شاهد مواقع الصور ولحظات السفر على الخريطة والخط الزمني.
7. **ألبوماتك أيضًا\nتعمل وفق قواعدك** — حدّد مدة الاحتفاظ والتنظيف التلقائي لكل ألبوم.

For Arabic:
- Use a real RTL app capture.
- Right-align marketing copy.
- Do not mirror an LTR app screenshot.
- Verify punctuation, digits, `PDF`, `QR`, and `Wi-Fi` remain readable in mixed-direction text.

### `ja-JP`

1. **必要な写真だけを\n写真アプリと分けて保存** — 選んだ写真や動画をSubGalleryだけにまとめて保管できます。
2. **写真の目的ごとに\n使い方を変える** — レシート・書類・QR・旅行を目的別の機能で管理できます。
3. **レシートから\n支出レポートへ** — 支払金額をまとめて、支出の流れや傾向を確認できます。
4. **複数ページを\n1つのPDFに** — 書類をスキャンして、複数ページを1つのPDFにまとめます。
5. **QRコードも\n自分で作成** — リンク・Wi-Fi・連絡先をQRコードにして保存できます。
6. **旅の写真を\n地図でもう一度** — 写真の場所と旅の流れを地図とタイムラインで振り返れます。
7. **自分のアルバムも\nルールで管理** — 保存期間と自動整理のルールをアルバムごとに設定できます。

### `zh-Hans`

1. **只把需要的照片\n单独保存** — 将选中的照片和视频与系统相册分开保存在 SubGallery 中。
2. **不同用途的照片\n用不同方式管理** — 收据、文档、QR 和旅行照片都有对应的专用功能。
3. **收据变成\n支出报告** — 汇总付款金额，查看支出趋势和消费模式。
4. **多页文档\n合成一个 PDF** — 扫描文档，并将多页内容合成为一个 PDF。
5. **创建自己的\nQR 码** — 将链接、Wi-Fi 和联系人制作成 QR 码并保存。
6. **在地图上\n重温旅行照片** — 通过地图和时间线查看照片位置与旅行轨迹。
7. **我的相册\n按规则管理** — 为每个相册设置保留期限和自动整理规则。

### `zh-Hant`

1. **只把需要的照片\n分開保存** — 將選取的照片和影片與系統相簿分開保存在 SubGallery。
2. **不同用途的照片\n用不同方式管理** — 收據、文件、QR 與旅行照片都有對應的專用功能。
3. **收據變成\n支出報告** — 彙整付款金額，查看支出趨勢與消費模式。
4. **多頁文件\n合成一個 PDF** — 掃描文件，並將多頁內容合成一個 PDF。
5. **建立自己的\nQR Code** — 將連結、Wi-Fi 與聯絡人製作成 QR Code 並保存。
6. **在地圖上\n重溫旅行照片** — 透過地圖與時間軸查看照片位置與旅行軌跡。
7. **我的相簿\n照規則管理** — 為每個相簿設定保留期限與自動整理規則。

### `fr-FR`

1. **Gardez l’essentiel,\nà part de Photos** — Conservez les photos et vidéos choisies séparément dans SubGallery.
2. **À chaque photo,\nson usage** — Reçus, documents, QR et voyages disposent d’outils adaptés à leur usage.
3. **Vos reçus deviennent\nun rapport de dépenses** — Regroupez les montants et suivez les tendances de vos dépenses.
4. **Plusieurs pages,\nun seul PDF** — Numérisez vos documents et réunissez plusieurs pages dans un PDF.
5. **Créez vos propres\ncodes QR** — Transformez liens, Wi-Fi et contacts en QR et conservez-les dans SubGallery.
6. **Retrouvez vos voyages\nsur la carte** — Revoyez les lieux et moments du voyage sur la carte et la chronologie.
7. **Vos albums,\nvos règles** — Définissez la conservation et le nettoyage automatique de chaque album.

## Localization of the app UI

For every locale, capture the app itself in that locale whenever the app supports it.

- Use the app’s current localization mechanism or deterministic launch settings.
- Do not fake translated app UI by editing screenshot pixels.
- Do not use the Korean app UI under English/German/etc. marketing copy if a real localized app UI exists.
- If a specific string is missing in the app localization, fix that localization in the project only if it is clearly an existing UI localization defect; do not redesign the feature.
- For Arabic, verify the actual app layout is RTL rather than mirroring an image.

## Composition workflow

1. Capture raw real app screenshots for every route/device/locale.
2. Keep raw captures in a separate working folder such as `store-assets/raw/{locale}/{device}/`.
3. Compose the final canvas deterministically with the fixed localized copy above.
4. Reuse the repository compositor/validator if available; update it only as needed for the new seven-frame storyboard.
5. Never bake marketing copy into the app itself merely to obtain screenshots.
6. Do not include simulator bezels or desktop backgrounds.
7. Ensure status bars, navigation titles, and content are not hidden by the marketing layer.
8. Verify that QR previews remain visually sharp after composition.
9. Verify map labels, receipt report numbers, and PDF page text remain readable at App Store preview scale.

## Quality gate

Before finishing, validate all of the following:

- Exactly **126** final PNG files exist.
- Every iPhone output is exactly **1242 x 2688**.
- Every iPad output is exactly **2064 x 2752**.
- Every locale has all seven slugs in the same order.
- No two different frame slugs accidentally use the same source screenshot.
- Every app capture is from real current SubGallery UI.
- No screenshot contains the old `주차` / `parking` marketing claim.
- No screenshot claims `searchable PDF` unless a real exported PDF text layer has been independently verified.
- No screenshot claims Face ID or encryption.
- Receipt report, QR builder, travel map, document PDF viewer, and album automation are visibly real features.
- First frame explains the separate-library value without needing the App Store description.
- First two frames explain the product model: separate storage + purpose-specific workflows.
- Frames 3–7 show concrete high-value outputs rather than generic settings.
- Headline is readable at thumbnail size.
- Supporting text is short and unclipped.
- Arabic is truly RTL-aware.
- CJK punctuation/line breaks look native.
- iPad artwork is recomposed from native iPad captures, not stretched iPhone artwork.
- No user-private data appears anywhere.
- No permission prompt appears in final screenshots.
- No debug/screenshot-mode marker appears in final screenshots.

If repository validation scripts exist, run them. If they do not cover the rules above, add a screenshot-only validation script rather than manually eyeballing all 126 files.

## Final report

After generation, report only:

1. total files generated;
2. 9 locales completed;
3. iPhone and iPad dimensions validated;
4. seven frame slugs;
5. any screenshot-mode-only code/scripts changed;
6. build/capture/validation result;
7. any feature intentionally omitted because verification failed.

Do not change production features merely to make the screenshots look better.
