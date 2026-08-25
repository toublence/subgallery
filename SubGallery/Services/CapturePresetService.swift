import Foundation
import SwiftData

struct CaptureTemplateConfiguration {
    let retention: RetentionPolicy
    let ocrEnabled: Bool
    let savesLocation: Bool
    let autoPins: Bool
    let primaryAction: PrimaryMediaAction
}

@MainActor
enum CapturePresetService {
    static func seedBuiltIns(in context: ModelContext) {
        removeLegacyParkingTemplate(in: context)
        migrateLegacyTemplateAlbums(in: context)
        let presets = (try? context.fetch(FetchDescriptor<CapturePreset>())) ?? []

        ensurePreset(named: L10n.text("일반"), purpose: .general, album: nil, retention: .forever,
                     ocrEnabled: true, savesLocation: false, autoPins: false, primaryAction: .automatic,
                     sortOrder: 0, existing: presets, context: context)
        for (index, purpose) in allTemplatePurposes.enumerated() {
            let configuration = templateConfiguration(for: purpose)
            ensurePreset(
                named: purpose.title,
                purpose: purpose,
                album: nil,
                retention: configuration.retention,
                ocrEnabled: configuration.ocrEnabled,
                savesLocation: configuration.savesLocation,
                autoPins: configuration.autoPins,
                primaryAction: configuration.primaryAction,
                sortOrder: index + 1,
                existing: presets,
                context: context
            )
        }
        let currentPresets = (try? context.fetch(FetchDescriptor<CapturePreset>())) ?? []
        for preset in currentPresets where preset.isBuiltIn {
            if preset.purpose == .general {
                preset.sortOrder = 0
            } else if let index = allTemplatePurposes.firstIndex(of: preset.purpose) {
                preset.sortOrder = index + 1
            }
        }
        try? context.save()
    }

    static let templatePurposes: [CapturePurpose] = [.receipt, .document, .qr, .travel]
    private static let allTemplatePurposes: [CapturePurpose] = [
        .receipt, .document, .qr, .travel, .temporary
    ]

    private static let removedParkingPurposeRaw = "parking"

    static func upgradePremiumTemplates(in context: ModelContext) {
        guard PremiumAccess.isActive else { return }
        seedBuiltIns(in: context)
    }

    static func canUse(_ preset: CapturePreset, hasPremium: Bool = PremiumAccess.isActive) -> Bool {
        preset.purpose == .general || hasPremium
    }

    /// Parking was a built-in template in older releases. Remove only the
    /// system-owned records; user albums and custom presets are left intact.
    private static func removeLegacyParkingTemplate(in context: ModelContext) {
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        let legacyAlbums = albums.filter {
            $0.isBuiltIn && $0.purposeRaw == removedParkingPurposeRaw
        }
        let legacyAlbumIDs = Set(legacyAlbums.map(\.id))
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        var didChange = false
        for item in items {
            let belongsToLegacyAlbum = item.albumID.map { legacyAlbumIDs.contains($0) } == true
            guard belongsToLegacyAlbum || item.purposeRaw == removedParkingPurposeRaw else { continue }

            if belongsToLegacyAlbum {
                item.albumID = nil
            }
            item.purposeRaw = CapturePurpose.general.rawValue
            item.suggestedPurposeRaw = nil
            item.suggestedAlbumID = nil
            item.suggestedRetentionRaw = nil
            if item.albumID == nil {
                item.classificationStatusRaw = SmartClassificationStatus.none.rawValue
            }
            didChange = true
        }

        let presets = (try? context.fetch(FetchDescriptor<CapturePreset>())) ?? []
        for preset in presets where preset.isBuiltIn && preset.purposeRaw == removedParkingPurposeRaw {
            context.delete(preset)
            didChange = true
        }
        legacyAlbums.forEach(context.delete)
        if !legacyAlbums.isEmpty { didChange = true }
        if didChange {
            try? context.save()
        }
    }

    static func migrateLegacyTemplateAlbums(in context: ModelContext) {
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        let legacyAlbums = albums.filter {
            $0.isBuiltIn && allTemplatePurposes.contains($0.purpose)
        }
        guard !legacyAlbums.isEmpty else { return }

        let purposeByAlbumID = Dictionary(uniqueKeysWithValues: legacyAlbums.map { ($0.id, $0.purpose) })
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        for item in items {
            guard let albumID = item.albumID, let purpose = purposeByAlbumID[albumID] else { continue }
            item.albumID = nil
            item.templatePurpose = purpose
            item.classificationStatus = .applied
        }

        let presets = (try? context.fetch(FetchDescriptor<CapturePreset>())) ?? []
        for preset in presets {
            guard let albumID = preset.albumID, let purpose = purposeByAlbumID[albumID] else { continue }
            preset.albumID = nil
            if preset.isBuiltIn { preset.purpose = purpose }
        }
        legacyAlbums.forEach(context.delete)
        try? context.save()
    }

    static func templateConfiguration(for purpose: CapturePurpose) -> CaptureTemplateConfiguration {
        switch purpose {
        case .receipt:
            CaptureTemplateConfiguration(retention: .thirtyDays, ocrEnabled: true, savesLocation: false, autoPins: false, primaryAction: .shareAndComplete)
        case .document:
            CaptureTemplateConfiguration(retention: .forever, ocrEnabled: true, savesLocation: false, autoPins: false, primaryAction: .automatic)
        case .travel:
            CaptureTemplateConfiguration(retention: .forever, ocrEnabled: true, savesLocation: true, autoPins: false, primaryAction: .automatic)
        case .qr:
            CaptureTemplateConfiguration(retention: .sevenDays, ocrEnabled: true, savesLocation: false, autoPins: false, primaryAction: .open)
        case .temporary:
            CaptureTemplateConfiguration(retention: .sevenDays, ocrEnabled: true, savesLocation: false, autoPins: false, primaryAction: .automatic)
        default:
            CaptureTemplateConfiguration(retention: .forever, ocrEnabled: true, savesLocation: false, autoPins: false, primaryAction: .automatic)
        }
    }

    private static func ensurePreset(
        named name: String,
        purpose: CapturePurpose,
        album: Album?,
        retention: RetentionPolicy,
        ocrEnabled: Bool,
        savesLocation: Bool,
        autoPins: Bool,
        primaryAction: PrimaryMediaAction,
        sortOrder: Int,
        existing: [CapturePreset],
        context: ModelContext
    ) {
        guard !existing.contains(where: { $0.isBuiltIn && $0.purpose == purpose }) else { return }
        let preset = CapturePreset(name: name, albumID: album?.id, retention: retention)
        preset.purpose = purpose
        preset.ocrEnabled = ocrEnabled
        preset.savesLocation = savesLocation
        preset.autoPins = autoPins
        preset.primaryAction = primaryAction
        preset.sortOrder = sortOrder
        preset.isBuiltIn = true
        context.insert(preset)
    }
}

@MainActor
enum DefaultAlbumMigration {
    static let completionKey = "migration.default-user-album.v1.completed"

    static func run(in context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completionKey) else { return }
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        let userAlbums = albums.filter { !$0.isBuiltIn }

        if userAlbums.isEmpty {
            context.insert(Album(name: L10n.text("기본 앨범"), sortOrder: 0))
        }

        do {
            try context.save()
            // This marker, rather than the editable album name, prevents both
            // relaunch duplication and recreation after the user deletes it.
            defaults.set(true, forKey: completionKey)
        } catch {
            // Retry next launch if persistence was unavailable.
        }
    }
}

@MainActor
enum TemplateCapturePipeline {
    static func insert(
        _ stored: StoredMedia,
        source: MediaSource,
        purpose: CapturePurpose,
        in context: ModelContext,
        location: (latitude: Double, longitude: Double)? = nil,
        analysis: MediaAnalysisResult? = nil
    ) -> MediaItem {
        let item = MediaItem(
            kind: stored.kind, source: source, localPath: stored.relativePath,
            thumbnailPath: stored.thumbnailRelativePath, fileName: stored.fileName,
            createdAt: stored.capturedAt ?? .now, fileSize: stored.fileSize,
            width: stored.width, height: stored.height, duration: stored.duration
        )
        let configuration = CapturePresetService.templateConfiguration(for: purpose)
        item.latitude = location?.latitude ?? stored.latitude
        item.longitude = location?.longitude ?? stored.longitude
        item.albumID = nil
        item.templatePurpose = purpose
        item.analysisEnabled = configuration.ocrEnabled
        item.primaryAction = configuration.primaryAction
        item.isPinned = configuration.autoPins
        item.suggestedPurpose = nil
        item.suggestedAlbumID = nil
        item.suggestedRetention = nil
        item.classificationStatus = .applied
        RetentionService.apply(configuration.retention, to: item)
        context.insert(item)

        if let analysis {
            item.recognizedText = analysis.text
            item.detectedURLs = analysis.urls
            item.detectedPhoneNumbers = analysis.phoneNumbers
            item.detectedAddresses = analysis.addresses
            item.detectedDates = analysis.dates
            item.detectedQRCodes = analysis.qrCodes
            if purpose == .receipt { ReceiptInfoWriter.apply(analysis, to: item) }
            item.ocrStatus = .completed
        }
        try? context.save()
        if analysis == nil { OCRService.enqueue(item, in: context) }
        return item
    }
}
