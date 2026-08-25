import SwiftData
import UIKit
import UserNotifications
import XCTest
@testable import SubGallery

@MainActor
final class CoreFeatureTests: XCTestCase {
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
        let album = Album(name: "Receipt", defaultRetention: .thirtyDays)
        album.purpose = .receipt
        album.isBuiltIn = true
        context.insert(album)
        let preset = CapturePreset(name: "Receipt", albumID: album.id)
        preset.purpose = .receipt
        context.insert(preset)

        let result = await PremiumBackfillService.run(in: context)

        XCTAssertEqual(result, PremiumBackfillResult())
        XCTAssertFalse(album.smartRuleEnabled)
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
        XCTAssertEqual(item.suggestedPurpose, .receipt)
        XCTAssertEqual(item.classificationStatus, .suggested)
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

        await PremiumBackfillService.run(in: context)
        await PremiumBackfillService.run(in: context)
        let presets = try context.fetch(FetchDescriptor<CapturePreset>())

        XCTAssertTrue(album.smartRuleEnabled)
        XCTAssertEqual(presets.filter { $0.isBuiltIn && $0.purpose == .receipt }.count, 1)
    }

    func testExistingTemplateGetsMissingPresetWhenAddedAgain() throws {
        let container = try makeContainer()
        let context = container.mainContext
        PurchaseManager.shared.configureForTesting(productIDs: [PurchaseManager.yearlyID])
        let album = Album(name: "Document")
        album.purpose = .document
        album.isBuiltIn = true
        context.insert(album)

        let returned = CapturePresetService.addTemplate(.document, in: context)
        let presets = try context.fetch(FetchDescriptor<CapturePreset>())

        XCTAssertEqual(returned.id, album.id)
        XCTAssertTrue(album.smartRuleEnabled)
        XCTAssertEqual(presets.filter { $0.purpose == .document }.count, 1)
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
}
