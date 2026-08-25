import SwiftData

@MainActor
enum CapturePresetService {
    static func seedBuiltIns(in context: ModelContext) {
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

    static let templatePurposes: [CapturePurpose] = [.receipt, .travel, .parking, .document, .qr]
    private static let allTemplatePurposes: [CapturePurpose] = [
        .receipt, .travel, .parking, .document, .qr, .temporary
    ]

    static func upgradePremiumTemplates(in context: ModelContext) {
        guard PremiumAccess.isActive else { return }
        seedBuiltIns(in: context)
    }

    static func canUse(_ preset: CapturePreset, hasPremium: Bool = PremiumAccess.isActive) -> Bool {
        preset.purpose == .general || hasPremium
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
        case .parking:
            (.untilComplete, false, true, true, .findCar)
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
