import CoreImage
import SwiftData
import UIKit
import UserNotifications
import Vision
import XCTest
@testable import SubGallery

@MainActor
final class CoreFeatureTests: XCTestCase {
    private enum QRTestScene: Equatable {
        case large
        case busy
        case small
        case tilted
        case code128
        case ordinary
    }

    /// Vision needs an inference context that some simulator hosts cannot create.
    /// Probing the real capability keeps these tests meaningful where Vision works
    /// (device, macOS CI) instead of leaving a permanently red result where it does not.
    private static var visionDetectsQRCodes: Bool = {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data("probe".utf8), forKey: "inputMessage")
        guard let raw = filter?.outputImage,
              let cgSymbol = CIContext().createCGImage(raw, from: raw.extent) else { return false }
        // Drawn on white with a quiet zone: a bare generator bitmap is not a fair
        // probe of the detector, and a false negative here would silently skip a
        // test that the host could actually run.
        let side: CGFloat = 480
        let canvas = CGSize(width: 720, height: 720)
        let probe = UIGraphicsImageRenderer(size: canvas).image { renderer in
            renderer.cgContext.interpolationQuality = .none
            UIColor.white.setFill()
            renderer.cgContext.fill(CGRect(origin: .zero, size: canvas))
            renderer.cgContext.draw(
                cgSymbol,
                in: CGRect(x: (canvas.width - side) / 2, y: (canvas.height - side) / 2,
                           width: side, height: side)
            )
        }
        guard let cgProbe = probe.cgImage else { return false }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cgProbe, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return false }
        return (request.results ?? []).contains { $0.symbology == .qr }
    }()

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([MediaItem.self, Album.self, CapturePreset.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    override func setUp() {
        super.setUp()
        PurchaseManager.shared.configureForTesting(productIDs: [])
    }

    private func receiptAnalysis() -> MediaAnalysisResult {
        let date = Date(timeIntervalSince1970: 1_787_184_000)
        return MediaAnalysisResult(
            text: "Coffee Shop\nRECEIPT\n2026-08-20\nCARD APPROVED\nTOTAL $12.34",
            urls: [],
            phoneNumbers: [],
            addresses: [],
            dates: [date],
            hasQRCode: false,
            qrCodes: [],
            receiptMerchant: "Coffee Shop",
            receiptAmount: "$12.34",
            textLineCount: 5,
            textCoverage: 0.16
        )
    }

    private func ordinaryAnalysis() -> MediaAnalysisResult {
        MediaAnalysisResult(
            text: "Family picnic at the beach",
            urls: [],
            phoneNumbers: [],
            addresses: [],
            dates: [],
            hasQRCode: false,
            qrCodes: [],
            receiptMerchant: "Family picnic at the beach",
            receiptAmount: "",
            textLineCount: 1,
            textCoverage: 0.03
        )
    }

    private func qrAnalysis(_ qrCodes: [String], hasQRCode: Bool? = nil) -> MediaAnalysisResult {
        MediaAnalysisResult(
            text: "",
            urls: qrCodes.filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") },
            phoneNumbers: [],
            addresses: [],
            dates: [],
            hasQRCode: hasQRCode ?? !qrCodes.isEmpty,
            qrCodes: qrCodes,
            receiptMerchant: "",
            receiptAmount: "",
            textLineCount: 0,
            textCoverage: 0
        )
    }

    private func generatedSymbol(
        filterName: String,
        payload: String,
        targetLongestEdge: CGFloat
    ) throws -> UIImage {
        let filter = try XCTUnwrap(CIFilter(name: filterName))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        if filterName == "CIQRCodeGenerator" {
            filter.setValue("H", forKey: "inputCorrectionLevel")
        }
        let output = try XCTUnwrap(filter.outputImage)
        let longestEdge = max(output.extent.width, output.extent.height)
        let integerScale = max(1, floor(targetLongestEdge / longestEdge))
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: integerScale, y: integerScale)
        )
        let cgImage = try XCTUnwrap(CIContext().createCGImage(scaled, from: scaled.extent))
        return UIImage(cgImage: cgImage)
    }

    private func qrVisionTestImage(scene: QRTestScene, payload: String) throws -> UIImage {
        let size = CGSize(width: 1200, height: 900)
        let targetLongestEdge: CGFloat = switch scene {
        case .large: 650
        case .busy: 280
        case .small: 105
        case .tilted: 360
        case .code128: 860
        case .ordinary: 1
        }
        let symbol = try generatedSymbol(
            filterName: scene == .code128 ? "CICode128BarcodeGenerator" : "CIQRCodeGenerator",
            payload: payload,
            targetLongestEdge: targetLongestEdge
        )
        return UIGraphicsImageRenderer(size: size).image { renderer in
            let context = renderer.cgContext
            context.interpolationQuality = .none
            UIColor(white: 0.96, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            if scene == .busy {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: 32, weight: .medium),
                    .foregroundColor: UIColor.darkGray
                ]
                for row in 0..<18 {
                    NSString(string: "LOTTO  \(row + 1)   03  11  18  27  39  42")
                        .draw(at: CGPoint(x: 28, y: 24 + row * 46), withAttributes: attributes)
                }
            } else if scene == .ordinary {
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 80, y: 100, width: 1040, height: 520))
                NSString(string: "SubGallery Photo").draw(
                    at: CGPoint(x: 330, y: 700),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 54, weight: .bold),
                        .foregroundColor: UIColor.black
                    ]
                )
                return
            }

            if scene == .code128 {
                let rect = CGRect(
                    x: (size.width - symbol.size.width) / 2,
                    y: (size.height - symbol.size.height) / 2,
                    width: symbol.size.width,
                    height: symbol.size.height
                )
                UIColor.white.setFill()
                context.fill(rect.insetBy(dx: -30, dy: -30))
                symbol.draw(in: rect)
                return
            }

            let side = symbol.size.width
            let center = scene == .busy ? CGPoint(x: 1015, y: 690) : CGPoint(x: 600, y: 450)
            let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            let quietZone = max(16, side * 0.12)
            context.saveGState()
            if scene == .tilted {
                context.translateBy(x: center.x, y: center.y)
                context.rotate(by: .pi / 16)
                context.translateBy(x: -center.x, y: -center.y)
            }
            UIColor.white.setFill()
            context.fill(rect.insetBy(dx: -quietZone, dy: -quietZone))
            symbol.draw(in: rect)
            context.restoreGState()
        }
    }

    func testUntilCompletePersistsCompletesAndRestores() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([MediaItem.self, Album.self, CapturePreset.self])
        let configuration = ModelConfiguration(
            "RetentionTest",
            schema: schema,
            url: directory.appending(path: "library.store"),
            allowsSave: true,
            cloudKitDatabase: .none
        )

        var container: ModelContainer? = try ModelContainer(for: schema, configurations: [configuration])
        let item = MediaItem(kind: .photo, source: .camera, localPath: "Media/test.jpg")
        RetentionService.apply(.untilComplete, to: item)
        container?.mainContext.insert(item)
        try container?.mainContext.save()
        container = nil

        container = try ModelContainer(for: schema, configurations: [configuration])
        let context = try XCTUnwrap(container?.mainContext)
        let persisted = try XCTUnwrap(try context.fetch(FetchDescriptor<MediaItem>()).first)
        XCTAssertTrue(persisted.waitingForCompletion)
        XCTAssertEqual(persisted.expirationType, .untilComplete)
        XCTAssertEqual(RetentionService.statusText(for: persisted), "완료 대기")

        persisted.reminderDate = .now
        persisted.reminderIdentifier = "media.\(persisted.id.uuidString)"
        await MediaLifecycleService.complete(persisted)
        try context.save()
        XCTAssertNotNil(persisted.deletedAt)
        XCTAssertNil(persisted.reminderDate)
        XCTAssertNil(persisted.reminderIdentifier)

        MediaLifecycleService.restore(persisted)
        try context.save()
        XCTAssertNil(persisted.deletedAt)
        XCTAssertTrue(persisted.waitingForCompletion)
    }

    func testPinControlsExpirationAndSmartAlbumMembership() throws {
        let item = MediaItem(kind: .photo, source: .camera, localPath: "Media/pinned.jpg")
        RetentionService.apply(.today, to: item, now: .distantPast)
        item.isPinned = true

        XCTAssertFalse(RetentionService.shouldMoveToRecentlyDeleted(item))
        XCTAssertEqual([item].filter { $0.isPinned && $0.deletedAt == nil }.map(\.id), [item.id])

        item.isPinned = false
        XCTAssertTrue(RetentionService.shouldMoveToRecentlyDeleted(item))
    }

    func testVisionRecognizesKoreanAndEnglishText() async throws {
        let size = CGSize(width: 1600, height: 700)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 150, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            NSString(string: "B3 142\n스타벅스").draw(
                in: CGRect(x: 80, y: 80, width: 1440, height: 540),
                withAttributes: attributes
            )
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "ocr-\(UUID().uuidString).jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 0.95)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try await OCRService.shared.recognizeText(at: url)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("B3"), "Recognized text: \(text)")
        XCTAssertTrue(text.contains("스타벅스"), "Recognized text: \(text)")
    }

    func testReminderDateOptionsAreFutureDates() {
        let now = Date.now
        for option in ReminderDateOption.allCases {
            XCTAssertGreaterThan(option.date(from: now), now, option.title)
        }
    }

    func testFreeUserCannotRunPremiumBackfillOrUsePremiumPreset() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let preset = CapturePreset(name: "Receipt")
        preset.purpose = .receipt
        context.insert(preset)

        let result = await PremiumBackfillService.run(in: context)

        XCTAssertEqual(result, PremiumBackfillResult())
        XCTAssertFalse(CapturePresetService.canUse(preset))
    }

    func testPremiumBackfillUsesCompletedOCRForClassificationAndReceiptExtraction() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        PurchaseManager.shared.configureForTesting(productIDs: [PurchaseManager.yearlyID])
        let item = MediaItem(kind: .photo, source: .files, localPath: "Media/receipt.jpg")
        item.ocrStatus = .completed
        item.recognizedText = "Coffee Shop\nRECEIPT\n2026-08-20\nTOTAL $12.34"
        context.insert(item)

        let result = await PremiumBackfillService.run(in: context)

        XCTAssertEqual(result.analyzedFromStoredText, 1)
        XCTAssertEqual(result.enqueuedForOCR, 0)
        XCTAssertEqual(item.templatePurpose, .receipt)
        XCTAssertNil(item.albumID)
        XCTAssertEqual(item.classificationStatus, .applied)
        XCTAssertFalse(item.receiptMerchant.isEmpty)
        XCTAssertFalse(item.receiptAmount.isEmpty)
        XCTAssertEqual(item.premiumAnalysisVersion, PremiumBackfillService.currentVersion)
    }

    func testPremiumBackfillUpgradesTemplateAndDoesNotDuplicatePreset() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        PurchaseManager.shared.configureForTesting(productIDs: [PurchaseManager.monthlyID])
        let album = Album(name: "Receipt", defaultRetention: .thirtyDays)
        album.purpose = .receipt
        album.isBuiltIn = true
        context.insert(album)
        let item = MediaItem(
            kind: .photo,
            source: .camera,
            localPath: "Media/legacy-receipt.jpg",
            albumID: album.id
        )
        // This case covers template/preset migration, not analysis. Without this the
        // backfill force-enqueues OCR for a file that does not exist and the detached
        // task outlives the container, crashing the suite on teardown.
        item.analysisEnabled = false
        context.insert(item)

        await PremiumBackfillService.run(in: context)
        await PremiumBackfillService.run(in: context)
        let albums = try context.fetch(FetchDescriptor<Album>())
        let presets = try context.fetch(FetchDescriptor<CapturePreset>())

        XCTAssertTrue(albums.isEmpty)
        XCTAssertNil(item.albumID)
        XCTAssertEqual(item.templatePurpose, .receipt)
        XCTAssertEqual(presets.filter { $0.isBuiltIn && $0.purpose == .receipt }.count, 1)
    }

    func testLegacyTemplateMigrationPreservesSameNamedUserAlbum() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let legacy = Album(name: "Receipt", defaultRetention: .thirtyDays)
        legacy.purpose = .receipt
        legacy.isBuiltIn = true
        context.insert(legacy)
        let userAlbum = Album(name: "영수증")
        context.insert(userAlbum)
        let item = MediaItem(
            kind: .photo,
            source: .camera,
            localPath: "Media/migrated.jpg",
            albumID: legacy.id
        )
        context.insert(item)
        let preset = CapturePreset(name: "Receipt", albumID: legacy.id)
        preset.purpose = .receipt
        preset.isBuiltIn = true
        context.insert(preset)

        CapturePresetService.migrateLegacyTemplateAlbums(in: context)

        let albums = try context.fetch(FetchDescriptor<Album>())
        XCTAssertEqual(albums.map(\.id), [userAlbum.id])
        XCTAssertFalse(userAlbum.isBuiltIn)
        XCTAssertNil(item.albumID)
        XCTAssertEqual(item.templatePurpose, .receipt)
        XCTAssertEqual(item.classificationStatus, .applied)
        XCTAssertNil(preset.albumID)
    }

    func testSubscriptionExpirationPreservesButLocksPresetAndCloudSync() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let preset = CapturePreset(name: "Premium preset")
        preset.purpose = .custom
        context.insert(preset)
        PurchaseManager.shared.configureForTesting(productIDs: [PurchaseManager.monthlyID])
        XCTAssertTrue(CapturePresetService.canUse(preset))
        XCTAssertTrue(DataStoreBootstrap.shouldUseCloudKit(premiumActive: true, syncRequested: true))

        PurchaseManager.shared.configureForTesting(productIDs: [])

        XCTAssertEqual(try context.fetch(FetchDescriptor<CapturePreset>()).count, 1)
        XCTAssertFalse(CapturePresetService.canUse(preset))
        XCTAssertFalse(DataStoreBootstrap.shouldUseCloudKit(premiumActive: false, syncRequested: true))
    }

    func testLifetimeAndRestoredVerifiedProductsKeepPremiumActive() {
        PurchaseManager.shared.configureForTesting(productIDs: [PurchaseManager.lifetimeID])
        XCTAssertTrue(PurchaseManager.shared.isPremium)
        XCTAssertTrue(PremiumAccess.isActive)

        PurchaseManager.shared.configureForTesting(productIDs: [])
        XCTAssertFalse(PremiumAccess.isActive)
        PurchaseManager.shared.configureForTesting(productIDs: [PurchaseManager.yearlyID])
        XCTAssertTrue(PurchaseManager.shared.isPremium)
        XCTAssertTrue(PremiumAccess.isActive)
    }

    func testTemplateClassificationCase1AppliesReceiptWithoutCreatingAlbum() throws {
        let container = try makeContainer()
        let context = container.mainContext
        CapturePresetService.seedBuiltIns(in: context)
        let item = MediaItem(kind: .photo, source: .camera, localPath: "Media/receipt-1.jpg")
        context.insert(item)

        SmartClassificationService.evaluate(
            receiptAnalysis(),
            for: item,
            in: context,
            postsSuggestionNotification: false
        )

        let albums = try context.fetch(FetchDescriptor<Album>())
        XCTAssertFalse(PremiumAccess.isActive)
        XCTAssertTrue(albums.isEmpty)
        XCTAssertNil(item.albumID)
        XCTAssertEqual(item.templatePurpose, .receipt)
        XCTAssertFalse(item.isUnclassified)
        XCTAssertEqual(item.expirationType, .thirtyDays)
        XCTAssertEqual(item.classificationStatus, .applied)
        XCTAssertEqual(item.receiptMerchant, "Coffee Shop")
        XCTAssertEqual(item.receiptAmount, "$12.34")
        XCTAssertNotNil(item.receiptDate)
        let templateItems = try context.fetch(FetchDescriptor<MediaItem>()).filter {
            $0.templatePurpose == .receipt && $0.deletedAt == nil
        }
        XCTAssertEqual(templateItems.map(\.id), [item.id])
    }

    func testTemplateClassificationCase4UserAlbumRemainsIndependent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        CapturePresetService.seedBuiltIns(in: context)
        let album = Album(name: "업무")
        context.insert(album)
        let item = MediaItem(kind: .photo, source: .photos, localPath: "Media/work.jpg", albumID: album.id)
        item.purpose = album.purpose
        context.insert(item)

        let albums = try context.fetch(FetchDescriptor<Album>())
        XCTAssertEqual(albums.map(\.id), [album.id])
        XCTAssertFalse(album.isBuiltIn)
        XCTAssertEqual(item.albumID, album.id)
        XCTAssertNil(item.templatePurpose)
    }

    func testTemplateClassificationCase3DetectsAndAppliesActualQR() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let payload = "https://example.com/subgallery"
        let qrCodes = [try XCTUnwrap(OCRService.qrPayload(symbology: .qr, payload: payload))]
        let result = qrAnalysis(qrCodes)
        let item = MediaItem(kind: .photo, source: .camera, localPath: "Media/qr.jpg")
        item.detectedQRCodes = result.qrCodes
        item.detectedURLs = result.urls
        context.insert(item)
        SmartClassificationService.evaluate(result, for: item, in: context, postsSuggestionNotification: false)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Album>()).isEmpty)
        XCTAssertNil(item.albumID)
        XCTAssertEqual(item.templatePurpose, .qr)
        XCTAssertFalse(item.isUnclassified)
        XCTAssertEqual(item.expirationType, .sevenDays)
        XCTAssertEqual(item.classificationStatus, .applied)
        XCTAssertEqual(item.detectedQRCodes, [payload])
        XCTAssertEqual(item.detectedURLs, [payload])
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<MediaItem>()).filter { $0.templatePurpose == .qr }.count,
            1
        )
    }

    func testQRVisionPipelineCases1Through6() async throws {
        try XCTSkipUnless(
            Self.visionDetectsQRCodes,
            "Vision cannot create an inference context on this host; run on a device or macOS."
        )
        let cases: [(QRTestScene, Bool, String)] = [
            (.large, true, "CASE 1 large QR"),
            (.busy, true, "CASE 2 busy lottery-style QR"),
            (.small, true, "CASE 3 small QR"),
            (.tilted, true, "CASE 4 tilted QR"),
            (.code128, false, "CASE 5 Code128 only"),
            (.ordinary, false, "CASE 6 ordinary photo")
        ]
        let container = try makeContainer()
        let context = container.mainContext
        var newestQRItemID: UUID?

        for (index, testCase) in cases.enumerated() {
            let payload = "https://example.com/subgallery/qr/\(index + 1)"
            let image = try qrVisionTestImage(scene: testCase.0, payload: payload)
            let url = FileManager.default.temporaryDirectory
                .appending(path: "qr-vision-\(UUID().uuidString).png")
            try XCTUnwrap(image.pngData()).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let result = try await OCRService.shared.analyze(at: url)
            XCTAssertEqual(result.hasQRCode, testCase.1, testCase.2)

            let item = MediaItem(
                kind: .photo,
                source: index.isMultiple(of: 2) ? .camera : .photos,
                localPath: "Media/qr-case-\(index).png",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
            item.detectedQRCodes = result.qrCodes
            item.detectedURLs = result.urls
            context.insert(item)
            SmartClassificationService.evaluate(
                result,
                for: item,
                in: context,
                postsSuggestionNotification: false
            )

            XCTAssertNil(item.albumID, testCase.2)
            if testCase.1 {
                XCTAssertEqual(item.templatePurpose, .qr, testCase.2)
                XCTAssertEqual(item.classificationStatus, .applied, testCase.2)
                XCTAssertFalse(item.isUnclassified, testCase.2)
                XCTAssertTrue(item.detectedQRCodes.contains(payload), testCase.2)
                newestQRItemID = item.id
            } else {
                XCTAssertNil(item.templatePurpose, testCase.2)
                XCTAssertEqual(item.classificationStatus, .none, testCase.2)
                XCTAssertTrue(item.isUnclassified, testCase.2)
            }
        }

        let templateItems = try context.fetch(
            FetchDescriptor<MediaItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        ).filter { $0.deletedAt == nil && $0.templatePurpose == .qr }
        XCTAssertEqual(templateItems.count, 4)
        XCTAssertEqual(templateItems.first?.id, newestQRItemID)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Album>()).isEmpty)
    }

    func testRealtimeQRCaptureAppliesTemplateWithoutAlbumOrPremium() throws {
        PurchaseManager.shared.configureForTesting(productIDs: [])
        let container = try makeContainer()
        let context = container.mainContext
        let item = MediaItem(kind: .photo, source: .camera, localPath: "Media/live-qr.jpg")
        context.insert(item)

        let applied = SmartClassificationService.applyRealtimeQRCode(
            "https://example.com/live",
            to: item,
            in: context
        )

        XCTAssertTrue(applied)
        XCTAssertFalse(PremiumAccess.isActive)
        XCTAssertEqual(item.templatePurpose, .qr)
        XCTAssertEqual(item.classificationStatus, .applied)
        XCTAssertFalse(item.isUnclassified)
        XCTAssertNil(item.albumID)
        XCTAssertEqual(item.detectedQRCodes, ["https://example.com/live"])
        XCTAssertEqual(item.detectedURLs, ["https://example.com/live"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<Album>()).isEmpty)
    }

    func testRealtimeQRKeepsPayloadButDoesNotOverrideExplicitPreset() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = MediaItem(kind: .photo, source: .camera, localPath: "Media/live-receipt.jpg")
        item.purpose = .receipt
        context.insert(item)

        let applied = SmartClassificationService.applyRealtimeQRCode("QR-PAYLOAD", to: item, in: context)

        XCTAssertFalse(applied)
        XCTAssertEqual(item.templatePurpose, .receipt)
        XCTAssertEqual(item.detectedQRCodes, ["QR-PAYLOAD"])
    }

    func testVisionPassDoesNotErasePayloadFoundByLiveCapture() throws {
        XCTAssertEqual(OCRService.merged(["live"], []), ["live"])
        XCTAssertEqual(OCRService.merged(["live"], ["vision"]), ["live", "vision"])
        XCTAssertEqual(OCRService.merged(["live"], ["live"]), ["live"])
        XCTAssertEqual(OCRService.merged([], ["vision", "", "vision"]), ["vision"])
    }

    func testNonQRSymbologyIsNeverTreatedAsQRPayload() {
        XCTAssertNil(OCRService.qrPayload(symbology: .code128, payload: "1234567890"))
        XCTAssertNil(OCRService.qrPayload(symbology: .ean13, payload: "8801234567890"))
        XCTAssertNil(OCRService.qrPayload(symbology: .qr, payload: "   "))
        XCTAssertEqual(OCRService.qrPayload(symbology: .qr, payload: " hello "), "hello")
    }

    // MARK: - QR workflow

    func testQRWorkflowCase1URLShowsDomainAndOpens() {
        let info = QRContentService.parse("https://www.example.com/path?a=1")
        XCTAssertEqual(info.type, .url)
        XCTAssertEqual(info.title, "example.com")
        XCTAssertEqual(info.primaryAction, .open)
        XCTAssertEqual(info.actionValue, "https://www.example.com/path?a=1")
    }

    func testQRWorkflowCase2LotteryURLIsPlainURLWithoutHardcoding() {
        let info = QRContentService.parse("https://m.dhlottery.co.kr/qr.do?method=winQr&v=1234")
        XCTAssertEqual(info.type, .url)
        // Domain only — no brand lookup table.
        XCTAssertEqual(info.title, "m.dhlottery.co.kr")
        XCTAssertEqual(info.primaryAction, .open)
    }

    func testQRWorkflowCase3PlainTextCopies() {
        let info = QRContentService.parse("주문번호 A-1029 확인 바랍니다")
        XCTAssertEqual(info.type, .text)
        XCTAssertEqual(info.primaryAction, .copy)
        XCTAssertEqual(info.actionValue, "주문번호 A-1029 확인 바랍니다")
    }

    func testQRWorkflowCase4PhoneNumberCalls() {
        for payload in ["tel:+82-10-1234-5678", "010-1234-5678"] {
            let info = QRContentService.parse(payload)
            XCTAssertEqual(info.type, .phone, payload)
            XCTAssertEqual(info.primaryAction, .call, payload)
        }
        // An order number must not become a call button.
        XCTAssertEqual(QRContentService.parse("A-1029").type, .text)
    }

    func testQRWorkflowCase5WiFiHidesPasswordFromListButKeepsItCopyable() {
        let info = QRContentService.parse(#"WIFI:T:WPA;S:Namslab_5G;P:secret\;pass;H:false;;"#)
        XCTAssertEqual(info.type, .wifi)
        XCTAssertEqual(info.subtitle, "Namslab_5G · WPA")
        XCTAssertFalse(info.subtitle.contains("secret"), "password must never reach a list row")

        let password = info.fields.first { $0.isSensitive }
        XCTAssertEqual(password?.value, "secret;pass", "escaped semicolon should survive parsing")
        XCTAssertEqual(info.fields.first { $0.label == "SSID" }?.value, "Namslab_5G")
    }

    func testQRWorkflowCase6MultiplePayloadsAreAllPreserved() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = MediaItem(kind: .photo, source: .camera, localPath: "Media/multi-qr.jpg")
        item.detectedQRCodes = [
            "https://example.com",
            "WIFI:T:WPA;S:Guest;P:pw;;",
            "tel:01012345678"
        ]
        context.insert(item)

        let contents = item.qrContents
        XCTAssertEqual(contents.count, 3)
        XCTAssertEqual(contents.map(\.type), [.url, .wifi, .phone])
        XCTAssertEqual(item.primaryQRContent?.type, .url)
    }

    func testQRWorkflowCase7CompletionMovesToRecentlyDeletedAndRestores() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = MediaItem(kind: .photo, source: .camera, localPath: "Media/qr-done.jpg")
        item.detectedQRCodes = ["https://example.com"]
        item.templatePurpose = .qr
        RetentionService.apply(.sevenDays, to: item)
        context.insert(item)

        await MediaLifecycleService.complete(item)
        XCTAssertNotNil(item.deletedAt)
        XCTAssertNotNil(item.completedAt)

        MediaLifecycleService.restore(item)
        XCTAssertNil(item.deletedAt)
        XCTAssertEqual(item.templatePurpose, .qr)
    }

    func testQRParserCoversRemainingTypes() {
        XCTAssertEqual(QRContentService.parse("mailto:a@b.com?subject=Hi").type, .email)
        XCTAssertEqual(QRContentService.parse("a@b.com").type, .email)
        XCTAssertEqual(QRContentService.parse("SMSTO:01012345678:안녕").type, .sms)

        let geo = QRContentService.parse("geo:37.5665,126.9780")
        XCTAssertEqual(geo.type, .location)
        XCTAssertEqual(geo.primaryAction, .map)
        XCTAssertEqual(geo.coordinate, QRCoordinate(latitude: 37.5665, longitude: 126.9780))

        let vcard = QRContentService.parse(
            "BEGIN:VCARD\nVERSION:3.0\nFN:홍길동\nORG:남슬랩;\nTEL;TYPE=CELL:010-1111-2222\nEMAIL:hong@example.com\nEND:VCARD"
        )
        XCTAssertEqual(vcard.type, .contact)
        XCTAssertEqual(vcard.title, "홍길동")
        XCTAssertEqual(vcard.primaryAction, .call)
        XCTAssertEqual(vcard.fields.first { $0.label == L10n.text("회사") }?.value, "남슬랩")

        // A scheme we do not handle stays unknown rather than pretending to be text.
        XCTAssertEqual(QRContentService.parse("bitcoin:1A2b3C4d").type, .unknown)
    }

    func testQRSearchTermsIncludeParsedValues() {
        let terms = QRContentService.searchTerms(for: [
            "https://www.dhlottery.co.kr/x",
            "WIFI:T:WPA;S:Namslab_5G;P:secret;;"
        ])
        XCTAssertTrue(terms.contains("dhlottery.co.kr"))
        XCTAssertTrue(terms.contains("Namslab_5G"))
        XCTAssertFalse(terms.contains("secret"), "sensitive values must stay out of the search index")
    }

    func testQRUsageStateStartsUnopenedAndIsRecordedByAnAction() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = MediaItem(kind: .photo, source: .camera, localPath: "Media/qr-open.jpg")
        item.detectedQRCodes = ["https://example.com"]
        context.insert(item)

        XCTAssertFalse(item.isQRUsed)
        XCTAssertNil(item.qrOpenedAt)

        QRActionRunner.markUsed(item, in: context)
        let firstOpen = try XCTUnwrap(item.qrOpenedAt)
        XCTAssertTrue(item.isQRUsed)

        // A second action must not overwrite when it was first dealt with.
        QRActionRunner.markUsed(item, in: context)
        XCTAssertEqual(item.qrOpenedAt, firstOpen)

        QRActionRunner.clearUsed(item, in: context)
        XCTAssertFalse(item.isQRUsed)
    }

    func testDatesFollowTheSelectedAppLanguageNotTheSystemLocale() {
        let date = Date(timeIntervalSince1970: 1_787_000_000)
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: "app.language")
        defer { defaults.set(original, forKey: "app.language") }

        defaults.set("en", forKey: "app.language")
        let english = L10n.date(date, dateStyle: .long)
        defaults.set("ko", forKey: "app.language")
        let korean = L10n.date(date, dateStyle: .long)

        XCTAssertNotEqual(english, korean)
        XCTAssertFalse(english.contains("년"), "English must not fall back to Korean formatting")
        XCTAssertTrue(korean.contains("년"))
    }

    func testEveryLocaleTranslatesTheQRUsageStrings() throws {
        for locale in ["en", "ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ar"] {
            let path = try XCTUnwrap(
                Bundle.main.path(forResource: locale, ofType: "lproj"),
                locale
            )
            let bundle = try XCTUnwrap(Bundle(path: path), locale)
            for key in ["확인함", "미확인", "확인함으로 표시", "미확인으로 표시", "링크", "비밀번호"] {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertFalse(value.isEmpty, "\(locale) / \(key)")
                if locale != "ko" {
                    XCTAssertNotEqual(value, key, "\(locale) is missing a translation for \(key)")
                }
            }
        }
    }

    func testTemplateClassificationCase2LeavesOrdinaryPhotoUnclassified() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = MediaItem(kind: .photo, source: .camera, localPath: "Media/photo.jpg")
        context.insert(item)

        SmartClassificationService.evaluate(
            ordinaryAnalysis(),
            for: item,
            in: context,
            postsSuggestionNotification: false
        )

        XCTAssertNil(item.albumID)
        XCTAssertEqual(item.purpose, .general)
        XCTAssertTrue(item.isUnclassified)
        XCTAssertEqual(item.classificationStatus, .none)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Album>()).isEmpty)

        let ambiguous = MediaAnalysisResult(
            text: "Project Alpha\nQuarterly TOTAL 1200\nNotes\nAppendix",
            urls: [],
            phoneNumbers: [],
            addresses: [],
            dates: [],
            hasQRCode: false,
            qrCodes: [],
            receiptMerchant: "Project Alpha",
            receiptAmount: "1200",
            textLineCount: 4,
            textCoverage: 0.14
        )
        let ambiguousItem = MediaItem(kind: .photo, source: .photos, localPath: "Media/ambiguous.jpg")
        context.insert(ambiguousItem)
        SmartClassificationService.evaluate(
            ambiguous,
            for: ambiguousItem,
            in: context,
            postsSuggestionNotification: false
        )
        XCTAssertNil(ambiguousItem.albumID)
        XCTAssertEqual(ambiguousItem.classificationStatus, .none)
    }

    func testAutomaticClassificationCase5DoesNotTreatCode128AsQR() throws {
        let container = try makeContainer()
        let context = container.mainContext
        XCTAssertNil(OCRService.qrPayload(symbology: .code128, payload: "123456789012"))
        let result = qrAnalysis([])
        let item = MediaItem(kind: .photo, source: .camera, localPath: "Media/barcode.jpg")
        context.insert(item)
        SmartClassificationService.evaluate(result, for: item, in: context, postsSuggestionNotification: false)

        XCTAssertNil(item.albumID)
        XCTAssertEqual(item.classificationStatus, .none)
        XCTAssertFalse(try context.fetch(FetchDescriptor<Album>()).contains { $0.purpose == .qr })
    }

    func testAutomaticClassificationUndoRestoresUnclassifiedStateAndRetention() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = MediaItem(kind: .photo, source: .photos, localPath: "Media/undo.jpg")
        item.recognizedText = receiptAnalysis().text
        RetentionService.apply(.today, to: item)
        let originalExpiration = item.expirationDate
        context.insert(item)
        SmartClassificationService.evaluate(
            receiptAnalysis(),
            for: item,
            in: context,
            postsSuggestionNotification: false
        )

        XCTAssertTrue(SmartClassificationService.undoAutomaticClassification(item, in: context))
        XCTAssertNil(item.albumID)
        XCTAssertEqual(item.purpose, .general)
        XCTAssertEqual(item.expirationType, .today)
        XCTAssertEqual(item.expirationDate, originalExpiration)
        XCTAssertEqual(item.classificationStatus, .dismissed)
        XCTAssertFalse(item.recognizedText.isEmpty)
    }
}
