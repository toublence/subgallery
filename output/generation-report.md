# SubGallery App Store 스크린샷 생성 보고서

## 생성 결과

- 빌드: Release (`STORE_SCREENSHOTS` 컴파일 조건으로 캡처 전용 진입점만 활성화)
- 최종 PNG: 126장
- 실제 앱 캡처 원본: 126장
- iPhone: 1242 × 2688, 로케일별 7장
- iPad: 2064 × 2752, 로케일별 7장
- 로케일: `ko-KR`, `en-US`, `de-DE`, `es-ES`, `ar-SA`, `ja-JP`, `zh-Hans`, `zh-Hant`, `fr-FR`
- 각 로케일 결과: iPhone 7장 + iPad 7장

## 실제 화면 매핑

| 번호 | 파일 | 캡처 경로 | 실제 앱 화면/구현 |
|---|---|---|---|
| 01 | `01-separate.png` | `library` | `LibraryView`의 보관함·내 앨범 구조 |
| 02 | `02-templates.png` | `workflows` | `LibraryView`의 영수증·문서·QR·여행 템플릿 |
| 03 | `03-receipts.png` | `receipt-report` | `ReceiptReportView`의 실제 지출 리포트 |
| 04 | `04-documents.png` | `document-pdf` | `DocumentBuilderService`로 생성한 3페이지 PDF를 `PDFDocumentViewer`에서 표시 |
| 05 | `05-qr.png` | `qr-builder` | `QRCodeBuilderView` / `QRCodeBuilderService`의 실제 QR 생성 결과 |
| 06 | `06-travel-map.png` | `travel-map` | `MediaMapView`의 실제 MapKit 지도와 위치 핀 |
| 07 | `07-album-automation.png` | `album-automation` | `AlbumAutomationView`의 실제 보관 기간·정리 설정 |

## 검증 결과

- 최종 PNG 126장 및 실제 앱 캡처 원본 126장 확인
- 모든 최종 이미지의 PNG 형식과 정확한 기기별 크기 확인
- iPad 원본이 네이티브 2064 × 2752 캡처이며 iPhone 원본 재사용이 아님을 확인
- 7개 경로가 서로 다른 실제 화면 원본을 사용함을 확인
- 모든 마케팅 문구가 지정 영역에 들어가며 잘리지 않음을 확인
- 아랍어 마케팅 문구와 앱 레이아웃의 RTL 방향 확인
- `주차`, `Face ID`, `searchable PDF`, `iCloud`, `encryption` 관련 문구가 없음을 확인
- 전체 콘택트 시트로 9개 로케일 × 2개 기기 × 7개 프레임을 시각 확인

세부 기계 검증 결과는 `validation-report.json`, 파일별 메타데이터와 원본 해시는 `manifest.json`에 기록되어 있다.

## 제한 사항

- 앱 자체의 현지화가 아직 완전하지 않은 일부 로케일에서는 몇몇 앱 내부 문자열이 영어로 표시된다. 실제 앱 UI는 수정하지 않고 그대로 유지했으며, 상단 마케팅 문구와 보조 문구만 각 로케일에 맞게 현지화했다.
- 요구된 7개 기능 중 실제 화면 부족으로 누락된 항목은 없다.
