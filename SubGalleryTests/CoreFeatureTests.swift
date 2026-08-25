import CoreImage
import PDFKit
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
        XCTAssertEqual(RetentionService.statusText(for: persisted), L10n.text("완료 대기"))

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

    func testBuiltInTemplateCaptureIsFreeButCustomPresetRequiresPremium() {
        let builtIn = CapturePreset(name: "Receipt")
        builtIn.purpose = .receipt
        builtIn.isBuiltIn = true
        let custom = CapturePreset(name: "Work")
        custom.purpose = .custom

        XCTAssertTrue(CapturePresetService.canUse(builtIn, hasPremium: false))
        XCTAssertFalse(CapturePresetService.canUse(custom, hasPremium: false))
        XCTAssertTrue(CapturePresetService.canUse(custom, hasPremium: true))
    }

    func testPremiumFeatureCatalogMatchesPublishedAccessPolicy() {
        XCTAssertEqual(PremiumFeatureCatalog.trialLimit(for: .receiptReport), 3)
        XCTAssertEqual(PremiumFeatureCatalog.trialLimit(for: .travelMap), 5)
        XCTAssertEqual(PremiumFeatureCatalog.trialLimit(for: .documentBuilder), 3)
        XCTAssertEqual(PremiumFeatureCatalog.trialLimit(for: .qrBuilder), 5)
        XCTAssertEqual(
            PremiumFeatureCatalog.feature(.advancedAlbumAutomation).accessPolicy,
            .freeBasicPremiumAdvanced
        )
        XCTAssertEqual(PremiumFeatureCatalog.feature(.cleanupCenter).accessPolicy, .premium)
        XCTAssertFalse(PurchaseManager.productIDs.contains(PurchaseManager.lifetimeID))
        XCTAssertTrue(PurchaseManager.entitlementProductIDs.contains(PurchaseManager.lifetimeID))
    }

    func testMediaViewerReceiptAndQRBaselineActionsDoNotTriggerPremiumUpsell() {
        let receipt = MediaItem(kind: .photo, source: .files, localPath: "Media/receipt.jpg")
        receipt.receiptMerchant = "중부식자재마트"
        receipt.receiptAmount = "₩15,100"
        receipt.receiptDate = Date(timeIntervalSince1970: 1_787_184_000)

        XCTAssertTrue(MediaViewerContentAccessPolicy.hasReceiptDetails(receipt))
        XCTAssertFalse(MediaViewerContentAccessPolicy.hasPremiumSmartContent(receipt))

        let qr = MediaItem(kind: .photo, source: .files, localPath: "Media/qr.jpg")
        qr.detectedQRCodes = ["https://example.com"]
        XCTAssertFalse(MediaViewerContentAccessPolicy.hasPremiumSmartContent(qr))
    }

    func testMediaViewerLocksOnlyReceiptFollowUpSmartActions() {
        let receipt = MediaItem(kind: .photo, source: .files, localPath: "Media/receipt-url.jpg")
        receipt.receiptMerchant = "중부식자재마트"
        receipt.receiptAmount = "₩15,100"
        receipt.detectedURLs = ["https://example.com/receipt"]

        XCTAssertTrue(MediaViewerContentAccessPolicy.hasReceiptDetails(receipt))
        XCTAssertTrue(MediaViewerContentAccessPolicy.hasPremiumSmartContent(receipt))
    }

    func testDocumentPaywallCopyDoesNotClaimSearchablePDF() {
        let detail = PremiumFeatureCatalog.feature(.documentBuilder).detailKey
        XCTAssertFalse(detail.contains(["검색", "가능한", "PDF"].joined(separator: " ")))
        XCTAssertTrue(detail.contains("OCR"))
    }

    func testSettingsPendingPremiumActionsResumeOnlyOnNewEntitlement() {
        let actions: [SettingsPendingPremiumAction] = [
            .enableICloud, .enableMetadataRemoval, .openCapturePresets
        ]
        for action in actions {
            XCTAssertEqual(
                SettingsPremiumResumePolicy.actionToResume(
                    wasPremium: false,
                    isPremium: true,
                    pendingAction: action
                ),
                action
            )
            XCTAssertNil(SettingsPremiumResumePolicy.actionToResume(
                wasPremium: false,
                isPremium: false,
                pendingAction: action
            ))
            XCTAssertNil(SettingsPremiumResumePolicy.actionToResume(
                wasPremium: true,
                isPremium: true,
                pendingAction: action
            ))
        }
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

    func testHomeStructureDefaultAlbumMigrationCases1Through7() throws {
        XCTAssertEqual(SmartAlbum.libraryCases, [.all, .pinned, .unclassified, .temporary])
        XCTAssertEqual(CapturePresetService.templatePurposes, [.receipt, .document, .qr, .travel])

        let suiteName = "DefaultAlbumMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let emptyContainer = try makeContainer()
        let emptyContext = emptyContainer.mainContext
        for _ in 0..<5 {
            DefaultAlbumMigration.run(in: emptyContext, defaults: defaults)
        }
        var albums = try emptyContext.fetch(FetchDescriptor<Album>()).filter { !$0.isBuiltIn }
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].name, L10n.text("기본 앨범"))

        albums[0].name = "업무"
        try emptyContext.save()
        DefaultAlbumMigration.run(in: emptyContext, defaults: defaults)
        albums = try emptyContext.fetch(FetchDescriptor<Album>()).filter { !$0.isBuiltIn }
        XCTAssertEqual(albums.map(\.name), ["업무"])

        emptyContext.delete(albums[0])
        try emptyContext.save()
        DefaultAlbumMigration.run(in: emptyContext, defaults: defaults)
        XCTAssertTrue(try emptyContext.fetch(FetchDescriptor<Album>()).isEmpty)

        let existingSuiteName = "DefaultAlbumExistingUserTests-\(UUID().uuidString)"
        let existingDefaults = try XCTUnwrap(UserDefaults(suiteName: existingSuiteName))
        defer { existingDefaults.removePersistentDomain(forName: existingSuiteName) }
        let existingContainer = try makeContainer()
        let existingContext = existingContainer.mainContext
        existingContext.insert(Album(name: "업무", sortOrder: 0))
        existingContext.insert(Album(name: "가족", sortOrder: 1))
        try existingContext.save()
        DefaultAlbumMigration.run(in: existingContext, defaults: existingDefaults)
        XCTAssertEqual(
            Set(try existingContext.fetch(FetchDescriptor<Album>()).map(\.name)),
            Set(["업무", "가족"])
        )
    }

    func testExplicitCaptureContextTemplatePipelineCases1To8Rules() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let albumID = UUID()
        XCTAssertEqual(CaptureContext.general, .general)
        XCTAssertEqual(CaptureContext.userAlbum(albumID), .userAlbum(albumID))
        XCTAssertEqual(CaptureContext.template(.receipt), .template(.receipt))

        func stored(_ name: String, latitude: Double? = nil, longitude: Double? = nil) -> StoredMedia {
            StoredMedia(
                kind: .photo, relativePath: "Media/\(name).jpg", thumbnailRelativePath: nil,
                fileName: "\(name).jpg", fileSize: 100, width: 100, height: 100,
                duration: 0, capturedAt: .now, latitude: latitude, longitude: longitude
            )
        }

        let receipt = TemplateCapturePipeline.insert(
            stored("receipt"), source: .camera, purpose: .receipt,
            in: context, analysis: receiptAnalysis()
        )
        XCTAssertEqual(receipt.templatePurpose, .receipt)
        XCTAssertEqual(receipt.classificationStatus, .applied)
        XCTAssertEqual(receipt.expirationType, .thirtyDays)
        XCTAssertEqual(receipt.receiptMerchant, "Coffee Shop")

        let qrPayload = "https://example.com/template"
        let qr = TemplateCapturePipeline.insert(
            stored("qr"), source: .photos, purpose: .qr,
            in: context, analysis: qrAnalysis([qrPayload])
        )
        XCTAssertEqual(qr.templatePurpose, .qr)
        XCTAssertEqual(qr.detectedQRCodes, [qrPayload])
        XCTAssertEqual(qr.expirationType, .sevenDays)

        let travel = TemplateCapturePipeline.insert(
            stored("travel", latitude: 37.5665, longitude: 126.9780),
            source: .photos, purpose: .travel, in: context,
            analysis: ordinaryAnalysis()
        )
        XCTAssertEqual(travel.templatePurpose, .travel)
        XCTAssertEqual(travel.latitude, 37.5665)
        XCTAssertEqual(travel.longitude, 126.9780)
        XCTAssertEqual(travel.expirationType, .forever)

        let document = TemplateCapturePipeline.insert(
            stored("document"), source: .camera, purpose: .document,
            in: context, analysis: ordinaryAnalysis()
        )
        XCTAssertEqual(document.templatePurpose, .document)
        XCTAssertEqual(document.ocrStatus, .completed)
        XCTAssertEqual(document.expirationType, .forever)

        for item in [receipt, qr, travel, document] {
            XCTAssertNil(item.albumID)
            XCTAssertFalse(item.isUnclassified)
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<Album>()).isEmpty)
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

    // MARK: - Album automation

    private func makeUserAlbum(
        _ context: ModelContext,
        retention: RetentionPolicy = .forever,
        ocr: Bool = true,
        savesLocation: Bool = false,
        autoPins: Bool = false,
        autoCleanup: Bool = false
    ) -> Album {
        let album = Album(name: "내 앨범", defaultRetention: retention)
        album.purpose = .custom
        album.ocrEnabled = ocr
        album.savesLocation = savesLocation
        album.autoPins = autoPins
        album.autoCleanupEnabled = autoCleanup
        context.insert(album)
        return album
    }

    private func newItem(_ context: ModelContext, createdAt: Date = .now) -> MediaItem {
        let item = MediaItem(
            kind: .photo, source: .camera,
            localPath: "Media/\(UUID().uuidString).jpg",
            createdAt: createdAt
        )
        context.insert(item)
        return item
    }

    func testAutomationCase3RetentionAppliesToNewItems() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let album = makeUserAlbum(context, retention: .sevenDays)
        let item = newItem(context)

        AlbumAutomationService.apply(album, to: item)

        XCTAssertEqual(item.albumID, album.id)
        XCTAssertEqual(item.expirationType, .sevenDays)
        XCTAssertNotNil(item.expirationDate)
    }

    func testAutomationCase4And6OCRAndAutoPinFollowTheAlbum() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let onAlbum = makeUserAlbum(context, ocr: true, autoPins: true)
        let offAlbum = makeUserAlbum(context, ocr: false, autoPins: false)

        let pinned = newItem(context)
        AlbumAutomationService.apply(onAlbum, to: pinned)
        XCTAssertTrue(pinned.analysisEnabled)
        XCTAssertTrue(pinned.isPinned)

        let plain = newItem(context)
        AlbumAutomationService.apply(offAlbum, to: plain)
        XCTAssertFalse(plain.analysisEnabled)
        XCTAssertFalse(plain.isPinned)
    }

    func testAutomationCase7ChangingRulesLeavesExistingPhotosAlone() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let album = makeUserAlbum(context, retention: .forever)
        let existing = newItem(context)
        AlbumAutomationService.apply(album, to: existing)
        XCTAssertNil(existing.expirationDate)

        // Changing the album's rule must not touch photos already inside.
        album.defaultRetention = .sevenDays
        try context.save()

        XCTAssertNil(existing.expirationDate, "a settings change must not rewrite existing photos")
        XCTAssertEqual(existing.expirationType, .forever)
    }

    func testAutomationCase8RetroactiveApplySkipsPinnedPhotos() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let album = makeUserAlbum(context, retention: .thirtyDays)
        var items: [MediaItem] = []
        for index in 0..<5 {
            let item = newItem(context)
            item.albumID = album.id
            if index == 0 { item.isPinned = true }
            items.append(item)
        }
        let outsider = newItem(context)
        items.append(outsider)

        let targets = AlbumAutomationService.itemsEligibleForRetroactiveRetention(in: album, from: items)
        XCTAssertEqual(targets.count, 4, "pinned photo and the outsider are excluded")

        let changed = AlbumAutomationService.applyRetentionToExisting(
            in: album, media: items, context: context
        )
        XCTAssertEqual(changed, 4)
        XCTAssertNil(items[0].expirationDate, "a pinned photo keeps its own terms")
        XCTAssertEqual(items[1].expirationType, .thirtyDays)
        XCTAssertEqual(outsider.expirationType, .forever, "photos in other albums are untouched")
    }

    func testAutomationCase9AutomaticCleanupIsOptInPerAlbum() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let manual = makeUserAlbum(context, autoCleanup: false)
        let automatic = makeUserAlbum(context, autoCleanup: true)
        let albums = [manual, automatic]

        let manualItem = newItem(context)
        manualItem.albumID = manual.id
        let autoItem = newItem(context)
        autoItem.albumID = automatic.id
        let looseItem = newItem(context)

        XCTAssertFalse(AlbumAutomationService.allowsAutomaticCleanup(
            manualItem, albums: albums, isPremium: true
        ))
        XCTAssertTrue(AlbumAutomationService.allowsAutomaticCleanup(
            autoItem, albums: albums, isPremium: true
        ))
        XCTAssertFalse(AlbumAutomationService.allowsAutomaticCleanup(
            autoItem, albums: albums, isPremium: false
        ))
        XCTAssertTrue(
            AlbumAutomationService.allowsAutomaticCleanup(
                looseItem, albums: albums, isPremium: false
            ),
            "photos outside a user album keep the existing behaviour"
        )
    }

    func testAutomationCase9CleanupNeverPermanentlyDeletesOrTouchesPins() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let expired = newItem(context)
        RetentionService.apply(.today, to: expired)
        expired.expirationDate = Date(timeIntervalSinceNow: -3600)

        XCTAssertTrue(RetentionService.shouldMoveToRecentlyDeleted(expired))
        await MediaLifecycleService.moveToRecentlyDeleted(expired)
        XCTAssertNotNil(expired.deletedAt, "goes to Recently Deleted, not permanent deletion")

        let pinned = newItem(context)
        RetentionService.apply(.today, to: pinned)
        pinned.expirationDate = Date(timeIntervalSinceNow: -3600)
        pinned.isPinned = true
        XCTAssertFalse(
            RetentionService.shouldMoveToRecentlyDeleted(pinned),
            "a pinned photo is never swept, whatever the album says"
        )
    }

    func testAutomationCase10SuggestionsComeFromStoredFieldsOnly() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let album = makeUserAlbum(context)
        let now = Date()

        let old = newItem(context, createdAt: Date(timeIntervalSinceNow: -40 * 86_400))
        old.albumID = album.id

        let waiting = newItem(context)
        waiting.albumID = album.id
        waiting.waitingForCompletion = true

        let soon = newItem(context)
        soon.albumID = album.id
        soon.expirationDate = Date(timeIntervalSinceNow: 2 * 86_400)

        let pinnedOld = newItem(context, createdAt: Date(timeIntervalSinceNow: -60 * 86_400))
        pinnedOld.albumID = album.id
        pinnedOld.isPinned = true

        let media = [old, waiting, soon, pinnedOld]
        let suggestions = AlbumAutomationService.cleanupSuggestions(
            for: album,
            media: media,
            now: now,
            isPremium: true
        )

        XCTAssertEqual(suggestions.agedOut.map(\.id), [old.id])
        XCTAssertEqual(suggestions.waitingForCompletion.map(\.id), [waiting.id])
        XCTAssertEqual(suggestions.expiringSoon.map(\.id), [soon.id])
        XCTAssertEqual(suggestions.total, 3, "pinned photos are never suggested")
    }

    func testAutomationSummaryDescribesTheCurrentRules() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let album = makeUserAlbum(context, retention: .thirtyDays, ocr: true, autoCleanup: false)

        let summary = AlbumAutomationService.summary(for: album)
        XCTAssertTrue(summary.contains(RetentionPolicy.thirtyDays.title))
        XCTAssertTrue(summary.contains(L10n.text("직접 완료")))
    }

    func testAutomationCase2TemplatesKeepTheirOwnBehaviour() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let receipt = Album(name: "Receipt", defaultRetention: .thirtyDays)
        receipt.purpose = .receipt
        receipt.isBuiltIn = true
        receipt.autoCleanupEnabled = false
        context.insert(receipt)

        let item = newItem(context)
        item.albumID = receipt.id

        // A template album never opts out of the sweep, so receipt retention keeps
        // working exactly as before this feature existed.
        XCTAssertTrue(AlbumAutomationService.allowsAutomaticCleanup(item, albums: [receipt]))
    }

    // MARK: - PDF viewer

    /// Writes a real PDF into the same location the builder uses, so the viewer is
    /// exercised against a genuine file rather than a fixture.
    private func writeTestPDF(pages: Int) throws -> Document {
        let images = (0..<pages).map { index in
            solidImage(index.isMultiple(of: 2) ? .white : .lightGray)
        }
        let data = try DocumentBuilderService.pdfData(from: images, title: "뷰어 테스트")
        let directory = MediaStorage.url(for: DocumentBuilderService.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "viewer-\(UUID().uuidString).pdf"
        try data.write(to: directory.appending(path: name), options: .atomic)
        return Document(
            title: "뷰어 테스트",
            pageCount: pages,
            pdfRelativePath: "\(DocumentBuilderService.directoryName)/\(name)"
        )
    }

    func testPDFViewerCase1OpensTheRealFileAndReportsPages() throws {
        let document = try writeTestPDF(pages: 2)
        defer { DocumentBuilderService.remove(document) }

        let model = PDFViewerModel()
        model.load(url: document.pdfURL)

        XCTAssertFalse(model.failedToOpen)
        XCTAssertEqual(model.pageCount, 2)
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertNotNil(model.pdfView.document, "the viewer must hold a real PDFDocument")
        XCTAssertEqual(model.pdfView.displayMode, .singlePageContinuous)
        XCTAssertTrue(model.pdfView.pageShadowsEnabled, "page separation is what makes it read as paper")
        XCTAssertTrue(model.pdfView.autoScales)
    }

    func testPDFViewerCase4NavigatesToASelectedPage() throws {
        let document = try writeTestPDF(pages: 4)
        defer { DocumentBuilderService.remove(document) }

        let model = PDFViewerModel()
        model.load(url: document.pdfURL)
        model.go(to: 3)

        XCTAssertEqual(model.currentPage, 3)
        let current = try XCTUnwrap(model.pdfView.currentPage)
        XCTAssertEqual(model.pdfView.document?.index(for: current), 2)
    }

    func testPDFViewerCase7HandlesALongDocumentWithoutRenderingEveryPage() throws {
        let document = try writeTestPDF(pages: 24)
        defer { DocumentBuilderService.remove(document) }

        let model = PDFViewerModel()
        model.load(url: document.pdfURL)

        XCTAssertEqual(model.pageCount, 24)
        XCTAssertFalse(model.failedToOpen)
        // Only the pages PDFKit chooses to draw are realised; nothing here builds a
        // 24-image array up front.
        XCTAssertNotNil(model.pdfView.document?.page(at: 23))
        model.go(to: 24)
        XCTAssertEqual(model.currentPage, 24)
    }

    func testPDFViewerReportsFailureInsteadOfFallingBackToImages() throws {
        let directory = MediaStorage.url(for: DocumentBuilderService.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "broken-\(UUID().uuidString).pdf"
        let url = directory.appending(path: name)
        try Data("not a pdf".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = PDFViewerModel()
        model.load(url: url)

        XCTAssertTrue(model.failedToOpen)
        XCTAssertEqual(model.pageCount, 0)
        XCTAssertNil(model.pdfView.document)
    }

    func testPDFViewerCase5And6ShareTheCanonicalPDFFile() throws {
        let document = try writeTestPDF(pages: 2)
        defer { DocumentBuilderService.remove(document) }

        // Share and Files both hand over this one URL — no regenerated file, no images.
        let url = document.pdfURL
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let type = try XCTUnwrap(url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        XCTAssertTrue(type.conforms(to: .pdf), "Files must recognise it as a PDF document")
        XCTAssertNotNil(PDFDocument(url: url))
    }

    func testDeletingADocumentRemovesBothTheRecordAndTheFile() throws {
        let container = try makeContainerWithDocuments()
        let context = container.mainContext
        let document = try writeTestPDF(pages: 1)
        context.insert(document)
        try context.save()
        let url = document.pdfURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        DocumentBuilderService.delete(document, from: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Document>()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - QR builder

    /// Round-trips a generated payload back through the reader the app uses on real
    /// scans. If this passes, another device's scanner sees the same thing.
    private func roundTrip(_ input: QRBuilderInput) throws -> QRContentInfo {
        let payload = try QRCodeBuilderService.payload(for: input)
        return QRContentService.parse(payload)
    }

    func testQRBuilderCase2URLPayloadRoundTrips() throws {
        let info = try roundTrip(.url("https://example.com"))
        XCTAssertEqual(info.type, .url)
        XCTAssertEqual(info.rawValue, "https://example.com")
        XCTAssertEqual(info.primaryAction, .open)

        XCTAssertThrowsError(try QRCodeBuilderService.payload(for: .url("example.com")))
        XCTAssertThrowsError(try QRCodeBuilderService.payload(for: .url("ftp://example.com")))
    }

    func testQRBuilderCase3WiFiUsesTheStandardPayload() throws {
        let payload = try QRCodeBuilderService.payload(
            for: .wifi(ssid: "Namslab", password: "12345678", security: .wpa, isHidden: false)
        )
        XCTAssertEqual(payload, "WIFI:T:WPA;S:Namslab;P:12345678;;")

        let info = QRContentService.parse(payload)
        XCTAssertEqual(info.type, .wifi)
        XCTAssertEqual(info.fields.first { $0.label == "SSID" }?.value, "Namslab")
        XCTAssertEqual(info.fields.first { $0.isSensitive }?.value, "12345678")
    }

    func testQRBuilderWiFiEscapesSeparatorCharacters() throws {
        let payload = try QRCodeBuilderService.payload(
            for: .wifi(ssid: "Cafe;Wifi", password: "pa:ss;word", security: .wpa, isHidden: true)
        )
        // Unescaped, these characters would end the field and corrupt the network name.
        XCTAssertTrue(payload.contains(#"S:Cafe\;Wifi"#))
        XCTAssertTrue(payload.contains("H:true"))

        let info = QRContentService.parse(payload)
        XCTAssertEqual(info.fields.first { $0.label == "SSID" }?.value, "Cafe;Wifi")
        XCTAssertEqual(info.fields.first { $0.isSensitive }?.value, "pa:ss;word")
    }

    func testQRBuilderOpenNetworkOmitsThePasswordField() throws {
        let payload = try QRCodeBuilderService.payload(
            for: .wifi(ssid: "Guest", password: "ignored", security: .none, isHidden: false)
        )
        XCTAssertFalse(payload.contains("ignored"))
        XCTAssertTrue(payload.contains("T:nopass"))
    }

    func testQRBuilderRemainingKindsRoundTrip() throws {
        XCTAssertEqual(try roundTrip(.text("회의실 비밀번호 1234")).type, .text)
        XCTAssertEqual(try roundTrip(.phone("010-1234-5678")).type, .phone)
        XCTAssertEqual(try roundTrip(.email(address: "a@b.com", subject: "Hi", body: "")).type, .email)

        let location = try roundTrip(.location(latitude: 37.5665, longitude: 126.9780))
        XCTAssertEqual(location.type, .location)
        XCTAssertEqual(location.coordinate, QRCoordinate(latitude: 37.5665, longitude: 126.9780))

        let contact = try roundTrip(
            .contact(name: "홍길동", phone: "010-1111-2222", email: "hong@example.com", organization: "남슬랩")
        )
        XCTAssertEqual(contact.type, .contact)
        XCTAssertEqual(contact.title, "홍길동")
        XCTAssertEqual(contact.fields.first { $0.label == L10n.text("회사") }?.value, "남슬랩")
    }

    func testQRBuilderRejectsEmptyOrInvalidInput() {
        XCTAssertThrowsError(try QRCodeBuilderService.payload(for: .text("   ")))
        XCTAssertThrowsError(try QRCodeBuilderService.payload(for: .phone("")))
        XCTAssertThrowsError(try QRCodeBuilderService.payload(for: .email(address: "nope", subject: "", body: "")))
        XCTAssertThrowsError(try QRCodeBuilderService.payload(for: .location(latitude: 200, longitude: 0)))
        XCTAssertThrowsError(
            try QRCodeBuilderService.payload(for: .contact(name: "", phone: "", email: "", organization: ""))
        )
        XCTAssertThrowsError(
            try QRCodeBuilderService.payload(for: .wifi(ssid: " ", password: "x", security: .wpa, isHidden: false))
        )
    }

    func testQRBuilderCase10GeneratedImageIsReadableByTheScanner() throws {
        try XCTSkipUnless(
            Self.visionDetectsQRCodes,
            "Vision cannot create an inference context on this host; run on a device or macOS."
        )
        let payload = try QRCodeBuilderService.payload(
            for: .wifi(ssid: "Namslab", password: "12345678", security: .wpa, isHidden: false)
        )
        let image = try QRCodeBuilderService.image(for: payload)
        let cgImage = try XCTUnwrap(image.cgImage)

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]).perform([request])
        let decoded = (request.results ?? []).compactMap(\.payloadStringValue)

        XCTAssertEqual(decoded.first, payload, "a real scanner must read back exactly what was encoded")
    }

    func testQRBuilderCase4And5PreviewOrFailureNeverSpendsAFreeUse() {
        var policy = QRBuilderTrialPolicy(used: 0)
        // Generating a preview and cancelling never advances the policy.
        XCTAssertEqual(policy.remaining, 5)
        XCTAssertTrue(policy.canBuild(isPremium: false))
        XCTAssertEqual(policy, QRBuilderTrialPolicy(used: 0))

        policy = policy.consumingIfEligible(isPremium: false)
        XCTAssertEqual(policy.remaining, 4)
    }

    func testQRBuilderCase6And7FiveFreeSavesThenPaywall() {
        var policy = QRBuilderTrialPolicy(used: 0)
        for expected in [4, 3, 2, 1, 0] {
            XCTAssertTrue(policy.canBuild(isPremium: false))
            policy = policy.consumingIfEligible(isPremium: false)
            XCTAssertEqual(policy.remaining, expected)
        }
        XCTAssertFalse(policy.canBuild(isPremium: false), "the sixth attempt is blocked")
        XCTAssertTrue(QRBuilderTrialPolicy(used: 4).isLastFreeUse)
    }

    func testQRBuilderCase8PremiumIsUnlimitedAndNeverCounts() {
        var policy = QRBuilderTrialPolicy(used: 5)
        XCTAssertFalse(policy.canBuild(isPremium: false))
        XCTAssertTrue(policy.canBuild(isPremium: true))
        policy = policy.consumingIfEligible(isPremium: true)
        XCTAssertEqual(policy.used, 5)
    }

    func testQRBuilderCase9GeneratedItemIsStoredWithItsKnownPayload() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let payload = try QRCodeBuilderService.payload(for: .url("https://namslab.com"))

        let item = MediaItem(kind: .photo, source: .generated, localPath: "Media/qr.png")
        item.templatePurpose = .qr
        item.classificationStatus = .applied
        item.detectedQRCodes = [payload]
        context.insert(item)
        try context.save()

        XCTAssertEqual(item.source, .generated, "provenance distinguishes it from a scanned QR")
        XCTAssertEqual(item.templatePurpose, .qr)
        XCTAssertFalse(item.isUnclassified)
        XCTAssertEqual(item.primaryQRContent?.type, .url)
        XCTAssertEqual(item.primaryQRContent?.rawValue, "https://namslab.com")
    }

    // MARK: - Document builder

    private func makeContainerWithDocuments() throws -> ModelContainer {
        let schema = Schema([MediaItem.self, Album.self, CapturePreset.self, Document.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func solidImage(_ color: UIColor, size: CGSize = CGSize(width: 120, height: 160)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testDocumentCase2PDFKeepsThePageOrderItWasGiven() throws {
        let images = [solidImage(.red), solidImage(.green), solidImage(.blue), solidImage(.gray)]
        let data = try DocumentBuilderService.pdfData(from: images, title: "계약서")

        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 4)
        XCTAssertEqual(
            pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
            "계약서"
        )
    }

    func testDocumentPDFRefusesToBuildWithoutPages() {
        XCTAssertThrowsError(try DocumentBuilderService.pdfData(from: [], title: "빈 문서")) { error in
            XCTAssertEqual(error as? DocumentBuilderError, .noPages)
        }
    }

    func testDocumentCase3And4CancelOrFailureNeverSpendsAFreeUse() {
        // Opening the builder and cancelling: nothing is consumed because the policy
        // is only ever applied after a document is saved.
        var policy = DocumentTrialPolicy(used: 0)
        XCTAssertEqual(policy.remaining, 3)
        XCTAssertTrue(policy.canBuild(isPremium: false))

        // A failed build takes the same path — the policy is simply never advanced.
        XCTAssertEqual(policy, DocumentTrialPolicy(used: 0))

        policy = policy.consumingIfEligible(isPremium: false)
        XCTAssertEqual(policy.remaining, 2)
    }

    func testDocumentCase5And6ThreeFreeBuildsThenPaywall() {
        var policy = DocumentTrialPolicy(used: 0)
        for expected in [2, 1, 0] {
            XCTAssertTrue(policy.canBuild(isPremium: false))
            policy = policy.consumingIfEligible(isPremium: false)
            XCTAssertEqual(policy.remaining, expected)
        }
        // The third build completes fully; only the fourth attempt is blocked.
        XCTAssertFalse(policy.canBuild(isPremium: false))
    }

    func testDocumentThirdBuildIsFlaggedAsTheLastFreeOne() {
        XCTAssertFalse(DocumentTrialPolicy(used: 0).isLastFreeUse)
        XCTAssertFalse(DocumentTrialPolicy(used: 1).isLastFreeUse)
        XCTAssertTrue(DocumentTrialPolicy(used: 2).isLastFreeUse)
        XCTAssertFalse(DocumentTrialPolicy(used: 3).isLastFreeUse)
    }

    func testDocumentCase7PremiumIsUnlimitedAndNeverCounts() {
        var policy = DocumentTrialPolicy(used: 3)
        XCTAssertFalse(policy.canBuild(isPremium: false))
        XCTAssertTrue(policy.canBuild(isPremium: true), "premium ignores the exhausted counter")

        policy = policy.consumingIfEligible(isPremium: true)
        XCTAssertEqual(policy.used, 3, "premium builds must not advance the counter")
    }

    func testDocumentCase8RecognizedTextIsSearchable() throws {
        let container = try makeContainerWithDocuments()
        let context = container.mainContext
        let document = Document(
            title: "임대차계약서",
            pageCount: 4,
            pdfRelativePath: "Documents/a.pdf",
            recognizedText: "임대차계약 제1조 보증금"
        )
        context.insert(document)
        try context.save()

        let stored = try context.fetch(FetchDescriptor<Document>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(stored[0].searchText.contains("임대차계약"))
        XCTAssertTrue(stored[0].searchText.contains("보증금"))
        XCTAssertTrue(stored[0].searchText.localizedCaseInsensitiveContains("임대차계약"))
    }

    func testDocumentRemembersWhichPhotosItWasBuiltFrom() throws {
        let container = try makeContainerWithDocuments()
        let context = container.mainContext
        let ids = [UUID(), UUID(), UUID()]
        let document = Document(
            title: "문서",
            pageCount: 3,
            pdfRelativePath: "Documents/b.pdf",
            sourceItemIDs: ids
        )
        context.insert(document)
        try context.save()

        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<Document>()).first)
        XCTAssertEqual(stored.sourceItemIDs, ids)
        XCTAssertEqual(stored.pageCount, 3)
    }

    func testDocumentPageRotationAndRenderingProduceAnImage() {
        let page = DocumentPage(image: solidImage(.red), rotation: 90, rendering: .monochrome)
        let rendered = DocumentBuilderService.renderedImage(for: page)
        // A quarter turn swaps the dimensions; the source is 120x160.
        XCTAssertEqual(Int(rendered.size.width), 160)
        XCTAssertEqual(Int(rendered.size.height), 120)
    }

    func testDocumentDefaultTitleIsNotEmpty() {
        let title = DocumentBuilderService.defaultTitle(now: Date(timeIntervalSince1970: 1_787_000_000))
        XCTAssertFalse(title.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertTrue(title.contains(CapturePurpose.document.title))
    }

    // MARK: - Receipt amount extraction

    private func extractedAmount(_ text: String) -> Decimal? {
        ReceiptAmountExtractor.extract(from: text, locale: Locale(identifier: "ko_KR"))?.value
    }

    func testApprovalNumberIsNeverMistakenForTheApprovedAmount() {
        // The exact shape that produced ₩822,608,619: OCR merges the label and its
        // identifier onto one line together with the real amount.
        XCTAssertEqual(
            extractedAmount("중부식자재마트\n승인번호 822608619 승인금액 15,100원"),
            15_100
        )
        XCTAssertEqual(
            extractedAmount("중부식자재마트\n승인번호 822608619\n승인금액 15,100원"),
            15_100
        )
        // A membership number happens to contain the character 원.
        XCTAssertEqual(
            extractedAmount("회원번호 822608619\n승인금액 15,100원"),
            15_100
        )
    }

    /// Verbatim OCR from the 중부식자재마트 receipt that rendered as ₩15.
    private var jungbuRecognizedText: String {
        """
        2
        50
        8
        0
        대 표 자:김종민
        소: 인천 남구 주안로 221(주{
        판매일:26-08-22 13:29, 토요일 계산대
        단가 수량
        과 세 물품 :
        15,1
        카드번호 : 5188-31#*-##**-****
        숭인금액 : 15,100
        (입시불)
        승인번호 : 63166807, 전표No : 132926
        거래ND: 0822608819 계산원: 손희(013)
        5™
        B
        6
        """
    }

    func testRealWorldOCRWithMisreadLabelAndTruncatedNumber() {
        XCTAssertEqual(extractedAmount(jungbuRecognizedText), 15_100)
    }

    func testTruncatedGroupedNumberIsRejectedRatherThanClipped() {
        // `15,100` clipped by OCR to `15,1`. Reading `15` from it would be wrong by
        // three orders of magnitude — the exact shape that rendered as ₩15.
        XCTAssertNil(extractedAmount("과 세 물품 :\n15,1"))
        XCTAssertNil(extractedAmount("합계 15,1"))
        XCTAssertNil(extractedAmount("합계 1,2"))
        // `1,23` is left alone on purpose: it is a valid European decimal, and
        // rejecting it would break those receipts to guard a Korean-only case.
        XCTAssertEqual(extractedAmount("합계 1,23"), Decimal(123) / 100)
        // Correctly grouped values are unaffected.
        XCTAssertEqual(extractedAmount("합계 15,100"), 15_100)
        XCTAssertEqual(extractedAmount("합계 1,234,567원"), 1_234_567)
    }

    func testGroupedNumbersAreReadWholeInBothConventions() {
        XCTAssertEqual(extractedAmount("합계 1,234.56"), Decimal(123_456) / 100)
        XCTAssertEqual(extractedAmount("합계 1.234,56"), Decimal(123_456) / 100)
        XCTAssertEqual(extractedAmount("합계 15,100"), 15_100)
        XCTAssertEqual(extractedAmount("합계 1.500"), 1_500)
    }

    func testMisreadKoreanLabelsStillResolve() {
        // Vision reads 승 as 숭 on thermal print often enough to matter.
        XCTAssertEqual(extractedAmount("숭인금액 : 15,100"), 15_100)
        XCTAssertEqual(extractedAmount("숭인번호 : 63166807\n숭인금액 : 15,100"), 15_100)
    }

    func testReceiptAmountLabelPriority() {
        XCTAssertEqual(extractedAmount("합계 9,900원\n승인금액 15,100원"), 15_100)
        XCTAssertEqual(extractedAmount("결제금액 28,500원\n합계 9,900원"), 28_500)
        XCTAssertEqual(extractedAmount("합계 9,900원"), 9_900)
        XCTAssertEqual(extractedAmount("승인금액\n15,100원"), 15_100, "label and value on separate lines")
    }

    func testReceiptAmountAcrossCommonReceiptShapes() {
        XCTAssertEqual(extractedAmount("승인금액 15,100원"), 15_100)
        XCTAssertEqual(extractedAmount("결제금액 28,500원"), 28_500)
        XCTAssertEqual(extractedAmount("합계 9,900원"), 9_900)
        XCTAssertEqual(
            ReceiptAmountExtractor.extract(from: "TOTAL $12.50")?.value,
            Decimal(1250) / 100
        )
    }

    func testIdentifiersAndDatesAreNeverAmounts() {
        XCTAssertNil(extractedAmount("승인번호 822608619"))
        XCTAssertNil(extractedAmount("카드번호 1234-5678-9012-3456"))
        XCTAssertNil(extractedAmount("사업자등록번호 123-45-67890"))
        XCTAssertNil(extractedAmount("전화번호 02-1234-5678"))
        XCTAssertNil(extractedAmount("2026-08-22 14:18:02"))
        XCTAssertEqual(
            extractedAmount("카드번호 1234-5678-9012-3456\n승인금액 15,100원"),
            15_100
        )
    }

    func testReceiptAmountPriorityFollowsChargedAmountLabels() {
        XCTAssertEqual(
            extractedAmount("합계 70,000원\n총 결제금액 60,000원\n받을금액 50,000원\n결제금액 40,000원\n실결제금액 30,000원\n승인금액 20,000원"),
            20_000
        )
        XCTAssertEqual(
            extractedAmount("총 결제금액 60,000원\n받을금액 50,000원"),
            50_000,
            "받을금액 must outrank 총 결제금액"
        )
    }

    func testAmountIsAbsentRatherThanGuessedWhenNothingIsCredible() {
        XCTAssertNil(extractedAmount("중부식자재마트\n영수증\n감사합니다"))
        XCTAssertNil(extractedAmount(""))
        XCTAssertNil(extractedAmount("주문번호 20260822001"))
    }

    func testManualEditsSurviveReextractionButAutomaticValuesAreCorrected() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let automatic = MediaItem(kind: .photo, source: .camera, localPath: "Media/auto.jpg")
        automatic.templatePurpose = .receipt
        automatic.recognizedText = "승인번호 822608619 승인금액 15,100원"
        automatic.receiptAmount = "822608619"
        context.insert(automatic)

        let corrected = MediaItem(kind: .photo, source: .camera, localPath: "Media/manual.jpg")
        corrected.templatePurpose = .receipt
        corrected.recognizedText = "승인번호 822608619 승인금액 15,100원"
        corrected.receiptAmount = "99,000"
        corrected.receiptAmountManuallyEdited = true
        context.insert(corrected)

        let changed = ReceiptAmountMigration.run(in: context)

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(ReceiptSummaryService.amount(from: automatic.receiptAmount)?.value, 15_100)
        XCTAssertEqual(corrected.receiptAmount, "99,000", "a hand-corrected amount must never be overwritten")

        // Second run is a no-op: the version stamp makes the migration idempotent.
        XCTAssertEqual(ReceiptAmountMigration.run(in: context), 0)
    }

    func testMigrationRepairsReceiptsFiledByAnEarlierExtractorGeneration() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = MediaItem(kind: .photo, source: .camera, localPath: "Media/clipped.jpg")
        item.templatePurpose = .receipt
        item.recognizedText = jungbuRecognizedText
        item.receiptAmount = "15"
        // Stamped by the generation that produced the wrong value.
        item.receiptExtractionVersion = 2
        context.insert(item)

        XCTAssertEqual(ReceiptAmountMigration.run(in: context), 1)
        XCTAssertEqual(
            ReceiptSummaryService.amount(from: item.receiptAmount, locale: Locale(identifier: "ko_KR"))?.value,
            15_100
        )
        XCTAssertEqual(item.receiptExtractionVersion, ReceiptInfoWriter.extractionVersion)
    }

    func testTheFifteenThousandOneHundredReceiptEndToEnd() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = MediaItem(kind: .photo, source: .camera, localPath: "Media/jungbu.jpg")
        item.templatePurpose = .receipt
        item.recognizedText = """
        중부식자재마트
        사업자등록번호 123-45-67890
        2026-08-22 14:18:02
        카드번호 1234-****-****-5678
        승인번호 822608619
        승인금액 15,100원
        """
        context.insert(item)

        ReceiptAmountMigration.run(in: context)
        let parsed = ReceiptSummaryService.amount(from: item.receiptAmount, locale: Locale(identifier: "ko_KR"))

        XCTAssertEqual(parsed?.value, 15_100)
        XCTAssertEqual(parsed?.currencyCode, "KRW")
        XCTAssertEqual(
            parsed?.formatted(locale: Locale(identifier: "ko_KR")),
            "₩15,100",
            "the list, the detail and the report all render this one string"
        )
    }

    // MARK: - Receipt template

    private func makeReceipt(
        _ context: ModelContext,
        merchant: String,
        amount: String,
        date: Date,
        pinned: Bool = false
    ) -> MediaItem {
        let item = MediaItem(
            kind: .photo, source: .camera,
            localPath: "Media/receipt-\(UUID().uuidString).jpg",
            createdAt: date
        )
        item.templatePurpose = .receipt
        item.receiptMerchant = merchant
        item.receiptAmount = amount
        item.receiptDate = date
        item.isPinned = pinned
        context.insert(item)
        return item
    }

    func testReceiptCase3AmountsAreParsedAndTotalled() {
        let locale = Locale(identifier: "ko_KR")
        XCTAssertEqual(ReceiptSummaryService.amount(from: "₩8,500", locale: locale)?.value, 8500)
        XCTAssertEqual(ReceiptSummaryService.amount(from: "12,000원", locale: locale)?.value, 12000)
        // Written as integer arithmetic: a `1234.56` Decimal literal is built from a
        // Double and is not exactly 1234.56, which is the very thing being asserted.
        XCTAssertEqual(
            ReceiptSummaryService.amount(from: "TOTAL $12.34", locale: locale)?.value,
            Decimal(1234) / 100
        )
        XCTAssertEqual(
            ReceiptSummaryService.amount(from: "1.234,56 EUR", locale: locale)?.value,
            Decimal(123_456) / 100
        )
        // A bare number takes the locale's currency rather than being discarded.
        XCTAssertEqual(ReceiptSummaryService.amount(from: "8500", locale: locale)?.currencyCode, "KRW")
    }

    func testReceiptCase4UnreadableAmountIsCountedButNeverSummed() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date()
        _ = makeReceipt(context, merchant: "CU", amount: "₩8,500", date: now)
        _ = makeReceipt(context, merchant: "이마트", amount: "₩12,000", date: now)
        _ = makeReceipt(context, merchant: "", amount: "", date: now)

        let items = try context.fetch(FetchDescriptor<MediaItem>())
        let summary = ReceiptSummaryService.summary(for: items, locale: Locale(identifier: "ko_KR"))

        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.unreadableAmountCount, 1)
        XCTAssertEqual(summary.totals.count, 1)
        XCTAssertEqual(summary.totals.first?.value, 20500)
        XCTAssertFalse(summary.hasMixedCurrencies)
    }

    func testReceiptMixedCurrenciesAreNeverCollapsedIntoOneTotal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date()
        _ = makeReceipt(context, merchant: "CU", amount: "₩8,500", date: now)
        _ = makeReceipt(context, merchant: "Blue Bottle", amount: "$12.00", date: now)

        let items = try context.fetch(FetchDescriptor<MediaItem>())
        let summary = ReceiptSummaryService.summary(for: items, locale: Locale(identifier: "ko_KR"))

        XCTAssertTrue(summary.hasMixedCurrencies)
        XCTAssertEqual(summary.totals.count, 2)
        XCTAssertEqual(summary.totals.first { $0.currencyCode == "KRW" }?.value, 8500)
        XCTAssertEqual(summary.totals.first { $0.currencyCode == "USD" }?.value, 12)
    }

    func testReceiptCase5EditingRefreshesRowValuesAndSummary() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date()
        let item = makeReceipt(context, merchant: "스타박스", amount: "", date: now)

        var summary = ReceiptSummaryService.summary(for: [item], locale: Locale(identifier: "ko_KR"))
        XCTAssertEqual(summary.unreadableAmountCount, 1)
        XCTAssertTrue(summary.totals.isEmpty)

        item.receiptMerchant = "스타벅스"
        item.receiptAmount = "₩6,100"
        try context.save()

        summary = ReceiptSummaryService.summary(for: [item], locale: Locale(identifier: "ko_KR"))
        XCTAssertEqual(item.receiptMerchant, "스타벅스")
        XCTAssertEqual(summary.unreadableAmountCount, 0)
        XCTAssertEqual(summary.totals.first?.value, 6100)
    }

    func testReceiptCase6CompletionRemovesItFromTheTemplate() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = makeReceipt(context, merchant: "CU", amount: "₩8,500", date: Date())

        await MediaLifecycleService.complete(item)
        try context.save()

        let visible = try context.fetch(FetchDescriptor<MediaItem>())
            .filter { $0.deletedAt == nil && $0.templatePurpose == .receipt }
        XCTAssertTrue(visible.isEmpty)
        XCTAssertNotNil(item.deletedAt)

        MediaLifecycleService.restore(item)
        XCTAssertEqual(item.templatePurpose, .receipt)
    }

    func testReceiptCase7PinnedReceiptSurvivesExpirationSweep() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = makeReceipt(context, merchant: "보증서", amount: "₩0", date: Date(), pinned: true)
        RetentionService.apply(.today, to: item)
        item.expirationDate = Date(timeIntervalSinceNow: -86_400)

        XCTAssertTrue(item.isPinned)
        XCTAssertFalse(
            RetentionService.shouldMoveToRecentlyDeleted(item),
            "a pinned receipt must not be swept away automatically"
        )
    }

    func testReceiptStaysOutOfUnclassifiedAndCreatesNoAlbum() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = makeReceipt(context, merchant: "CU", amount: "₩8,500", date: Date())

        XCTAssertFalse(item.isUnclassified)
        XCTAssertNil(item.albumID)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Album>()).isEmpty)
    }

    func testReceiptDisplayDateFallsBackWhenOCRFoundNoDate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let captured = Date(timeIntervalSince1970: 1_780_000_000)
        let item = makeReceipt(context, merchant: "CU", amount: "₩8,500", date: captured)

        item.receiptDate = nil
        XCTAssertEqual(item.receiptDisplayDate, captured, "must fall back to the capture date")

        let detected = Date(timeIntervalSince1970: 1_781_000_000)
        item.detectedDates = [detected]
        XCTAssertEqual(item.receiptDisplayDate, detected, "a date read from the image wins over capture")

        let printed = Date(timeIntervalSince1970: 1_782_000_000)
        item.receiptDate = printed
        XCTAssertEqual(item.receiptDisplayDate, printed, "the printed receipt date wins over everything")
    }

    func testReceiptReportFreeTrialAllowsThreeRenderedSessionsAndBlocksFourth() {
        var policy = ReceiptReportTrialPolicy(used: 0)

        for expectedRemaining in stride(from: 2, through: 0, by: -1) {
            XCTAssertTrue(policy.canOpen(isPremium: false, hasReceiptData: true))
            policy = policy.consumingIfEligible(isPremium: false, didRenderReport: true)
            XCTAssertEqual(policy.remaining, expectedRemaining)
        }

        XCTAssertFalse(policy.canOpen(isPremium: false, hasReceiptData: true))
        XCTAssertTrue(policy.canOpen(isPremium: true, hasReceiptData: true))
    }

    func testReceiptReportTrialDoesNotConsumeForEmptyDataPeriodOrPremium() {
        let fresh = ReceiptReportTrialPolicy(used: 0)
        XCTAssertTrue(fresh.canOpen(isPremium: false, hasReceiptData: false))
        XCTAssertEqual(
            fresh.consumingIfEligible(isPremium: false, didRenderReport: false),
            fresh
        )
        XCTAssertEqual(
            fresh.consumingIfEligible(isPremium: true, didRenderReport: true),
            fresh
        )
    }

    func testTravelMapFreeTrialAllowsFiveOpensAndBlocksSixth() {
        var policy = TravelMapTrialPolicy(used: 0)
        for expectedRemaining in stride(from: 4, through: 0, by: -1) {
            XCTAssertTrue(policy.canOpen(isPremium: false))
            policy = policy.consumingIfEligible(isPremium: false, didRenderMap: true)
            XCTAssertEqual(policy.remaining, expectedRemaining)
        }
        XCTAssertFalse(policy.canOpen(isPremium: false))
        XCTAssertTrue(policy.canOpen(isPremium: true))
        XCTAssertEqual(policy.consumingIfEligible(isPremium: true, didRenderMap: true), policy)
    }

    func testTravelMapTrialDoesNotConsumeWithoutLocationDataOrSuccessfulRender() {
        let exhausted = TravelMapTrialPolicy(used: TravelMapTrialPolicy.freeUseLimit)
        XCTAssertTrue(exhausted.canOpen(isPremium: false, hasMapData: false))

        let fresh = TravelMapTrialPolicy(used: 0)
        XCTAssertEqual(
            fresh.consumingIfEligible(isPremium: false, didRenderMap: false),
            fresh
        )
    }

    func testReceiptReportUsesApprovalAmountAndExcludesIdentifierFromTotal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let valid = makeReceipt(
            context,
            merchant: "중부식자재마트",
            amount: "15,100",
            date: Date(timeIntervalSince1970: 1_787_184_000)
        )
        valid.recognizedText = "승인번호 822608619 승인금액 15,100원"
        let invalid = makeReceipt(
            context,
            merchant: "금액 미확인",
            amount: "822608619",
            date: Date(timeIntervalSince1970: 1_787_184_000)
        )

        let report = ReceiptReportAnalyticsService.build(
            items: [valid, invalid],
            grouping: .day,
            locale: Locale(identifier: "ko_KR")
        )

        XCTAssertEqual(ReceiptAmountExtractor.extract(from: valid.recognizedText)?.value, 15_100)
        XCTAssertNil(ReceiptSummaryService.amount(for: invalid, locale: Locale(identifier: "ko_KR")))
        XCTAssertEqual(report.currencyReports.first?.total, 15_100)
        XCTAssertEqual(report.unreadableReceipts.map(\.id), [invalid.id])
    }

    func testReceiptReportMerchantAndBiggestDayAggregation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar(identifier: .gregorian)
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let secondDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 22)))
        _ = makeReceipt(context, merchant: "CU", amount: "₩8,500", date: firstDay)
        _ = makeReceipt(context, merchant: "  cu  ", amount: "₩6,500", date: secondDay)
        _ = makeReceipt(context, merchant: "이마트", amount: "₩50,000", date: secondDay)

        let items = try context.fetch(FetchDescriptor<MediaItem>())
        let report = ReceiptReportAnalyticsService.build(
            items: items,
            grouping: .day,
            calendar: calendar,
            locale: Locale(identifier: "ko_KR")
        )
        let krw = try XCTUnwrap(report.currencyReports.first { $0.currencyCode == "KRW" })

        XCTAssertEqual(krw.total, 65_000)
        XCTAssertEqual(krw.frequentMerchants.first?.count, 2)
        XCTAssertEqual(krw.frequentMerchants.first?.total, 15_000)
        XCTAssertEqual(krw.spendingMerchants.first?.merchant, "이마트")
        XCTAssertEqual(krw.biggestDay?.total, 56_500)
        XCTAssertEqual(krw.biggestDay?.items.count, 2)
    }

    func testReceiptReportTwoReceiptCompactSummary() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let date = Date(timeIntervalSince1970: 1_787_184_000)
        _ = makeReceipt(context, merchant: "중부식자재마트", amount: "₩100", date: date)
        _ = makeReceipt(context, merchant: "DD", amount: "₩15,100", date: date)

        let report = ReceiptReportAnalyticsService.build(
            items: try context.fetch(FetchDescriptor<MediaItem>()),
            grouping: .day,
            locale: Locale(identifier: "ko_KR")
        )
        let krw = try XCTUnwrap(report.currencyReports.first { $0.currencyCode == "KRW" })

        XCTAssertEqual(report.receiptCount, 2)
        XCTAssertEqual(krw.total, 15_200)
        XCTAssertEqual(krw.average, 7_600)
        XCTAssertEqual(krw.maximum, 15_100)
        XCTAssertEqual(krw.spendingMerchants.first?.merchant, "DD")
        XCTAssertEqual(krw.frequentMerchants.first?.merchant, "DD")
        XCTAssertEqual(krw.largestReceipts.map(\.amount.value), [15_100, 100])
        XCTAssertEqual(krw.biggestDay?.total, 15_200)
    }

    func testReceiptReportTwentyReceiptDashboardSummary() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let calendar = Calendar(identifier: .gregorian)

        for index in 0..<20 {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: (index % 10) + 1
            )))
            _ = makeReceipt(
                context,
                merchant: index < 12 ? "이마트" : "CU",
                amount: "₩\((index + 1) * 1_000)",
                date: date
            )
        }

        let report = ReceiptReportAnalyticsService.build(
            items: try context.fetch(FetchDescriptor<MediaItem>()),
            grouping: .day,
            calendar: calendar,
            locale: Locale(identifier: "ko_KR")
        )
        let krw = try XCTUnwrap(report.currencyReports.first { $0.currencyCode == "KRW" })

        XCTAssertEqual(report.receiptCount, 20)
        XCTAssertEqual(krw.total, 210_000)
        XCTAssertEqual(krw.average, 10_500)
        XCTAssertEqual(krw.maximum, 20_000)
        XCTAssertEqual(krw.chartPoints.count, 10)
        XCTAssertEqual(krw.spendingMerchants.first?.merchant, "CU")
        XCTAssertEqual(krw.frequentMerchants.first?.merchant, "이마트")
        XCTAssertEqual(krw.largestReceipts.prefix(3).reduce(Decimal.zero) { $0 + $1.amount.value }, 57_000)
        XCTAssertEqual(krw.biggestDay?.total, 30_000)
    }

    func testReceiptPeriodFilterBuckets() {
        let calendar = Calendar.current
        let now = try! XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15)))
        let thisMonth = try! XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 2)))
        let lastMonth = try! XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 30)))

        XCTAssertTrue(ReceiptPeriod.thisMonth.contains(thisMonth, now: now))
        XCTAssertFalse(ReceiptPeriod.thisMonth.contains(lastMonth, now: now))
        XCTAssertTrue(ReceiptPeriod.lastMonth.contains(lastMonth, now: now))
        XCTAssertFalse(ReceiptPeriod.lastMonth.contains(thisMonth, now: now))
        XCTAssertTrue(ReceiptPeriod.all.contains(lastMonth, now: now))
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
