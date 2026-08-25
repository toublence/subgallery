# Firebase Analytics funnels

SubGallery custom events contain fixed product-state values, counts and booleans only. Firebase's built-in `first_open` and `session_start` are not duplicated.

## Funnel A — Activation

`first_open` (Firebase built-in) → `onboarding_start` (`context=first_run`) → `onboarding_complete` (`context=first_run`) → `first_value_reached` → `activation_complete`

Measure `first_open` → `onboarding_complete`, `onboarding_complete` → `first_value_reached`, `first_value_reached` → `activation_complete`, and median `elapsed_seconds` to first value.

Initial analysis targets (not app logic): onboarding completion → first value ≥ 70%; median time to first value ≤ 120 seconds.

`first_value_reached` means the first photo/video that reaches successful SubGallery persistence. `activation_complete` means the second successful media persistence. Their counters are independent from Review Prompt state and fire once per install.

## Funnel B — Purpose Adoption

`first_value_reached` → `template_open` → template value event:

- receipt: `receipt_analysis_complete` or `receipt_report_rendered`
- document: `document_scan_success` → `pdf_create_success`
- qr: `qr_detected` or `qr_create_success`
- travel: `travel_location_saved` → `travel_map_rendered`

Analyze open users, value users, conversion and return rate by `template`.

## Funnel C — Premium

`premium_feature_trial_used` → `premium_feature_limit_reached` → `premium_paywall_view` → `premium_plan_selected` → `premium_purchase_start` → `premium_purchase_success`

Analyze by `feature`, `entry_point` and `plan`. Existing Premium event names remain unchanged. Trial limits remain Receipt 3 / Travel 5 / Document 3 / QR 5.

## Funnel D — Retention

Create cohorts at `first_value_reached` and test whether `meaningful_action` occurs during D1, D7 and D30. Valid actions are `media_add`, `media_open`, `search`, `template_open`, `complete`, `export`, and `album_open`; `session_start` alone is not meaningful retention.

## Event inventory

- Onboarding: `onboarding_start`, `onboarding_page_view`, `onboarding_complete`
- Media add: `media_add_start`, `media_add_success`, `media_add_failed`, `first_value_reached`, `activation_complete`
- Engagement: `meaningful_action`, `template_open`, `search_performed`
- Receipt: `receipt_analysis_complete`, `receipt_report_open`, `receipt_report_rendered`
- Document: `document_scan_success`, `pdf_create_success`, `pdf_create_failed`, `pdf_open`
- QR: `qr_detected`, `qr_builder_open`, `qr_create_success`, `qr_create_failed`
- Travel: `travel_location_saved`, `travel_location_failed`, `travel_map_open`, `travel_map_rendered`
- Album: `album_created`, `album_open`, `album_automation_open`, `album_automation_changed`
- Lifecycle: `media_completed`, `media_restored`, `media_exported`
- Premium: `premium_paywall_view`, `premium_plan_selected`, `premium_paywall_dismissed`, `premium_purchase_start`, `premium_purchase_success`, `premium_restore_success`, `premium_feature_trial_used`, `premium_feature_limit_reached`

All custom events include `premium_status=free|premium`. The same value is maintained as a Firebase user property after StoreKit entitlement refresh.

## Console configuration

Recommended event-scoped custom dimensions: `source`, `destination`, `template`, `entry_point`, `plan`, `result`, `reason`, `action`, `range`, `qr_type`, `album_type`, `rule_type`, and `premium_status`.

Keep booleans and low-level counts as event parameters rather than dimensions. Register `elapsed_seconds` as a custom metric when time-to-value reporting is needed. Do not register high-cardinality values.

## Privacy and validation

Never send photos, video, paths, filenames, OCR/search text, QR payloads or URLs, Wi-Fi/contact data, phone/email/address, coordinates, merchant names, receipt amounts, album names, PINs, UUIDs or document/media IDs.

Custom product analytics is disabled under `-store-screenshot` and `-ui-testing`. For DebugView, run a normal Debug build with `-FIRDebugEnabled` and verify event order and duplicates through onboarding, two imports, each template value action, album automation, paywall and an explicit plan selection.
