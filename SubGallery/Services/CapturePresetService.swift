import SwiftData

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
        try? context.save()
    }

    static let templatePurposes: [CapturePurpose] = [.receipt, .travel, .document, .qr]
    private static let allTemplatePurposes: [CapturePurpose] = [
        .receipt, .travel, .document, .qr, .temporary
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

    private static func templateConfiguration(for purpose: CapturePurpose) -> (
        retention: RetentionPolicy,
        ocrEnabled: Bool,
        savesLocation: Bool,
        autoPins: Bool,
        primaryAction: PrimaryMediaAction
    ) {
        switch purpose {
        case .receipt:
            (.thirtyDays, true, false, false, .shareAndComplete)
        case .document:
            (.forever, true, false, false, .automatic)
        case .travel:
            (.forever, true, true, false, .automatic)
        case .qr:
            (.sevenDays, true, false, false, .open)
        case .temporary:
            (.sevenDays, true, false, false, .automatic)
        default:
            (.forever, true, false, false, .automatic)
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
