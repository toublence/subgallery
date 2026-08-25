import SwiftData

@MainActor
enum CapturePresetService {
    static func seedBuiltIns(in context: ModelContext) {
        let presets = (try? context.fetch(FetchDescriptor<CapturePreset>())) ?? []

        ensurePreset(named: L10n.text("일반"), purpose: .general, album: nil, retention: .forever,
                     ocrEnabled: true, savesLocation: false, autoPins: false, primaryAction: .automatic,
                     sortOrder: 0, existing: presets, context: context)
        try? context.save()
    }

    static let templatePurposes: [CapturePurpose] = [.receipt, .travel, .parking, .document]
    private static let premiumTemplatePurposes: [CapturePurpose] = [
        .receipt, .travel, .parking, .document, .qr, .temporary
    ]

    @discardableResult
    static func addTemplate(_ purpose: CapturePurpose, in context: ModelContext) -> Album {
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        if let existing = albums.first(where: { $0.purpose == purpose }) {
            if PremiumAccess.isActive, existing.isBuiltIn {
                enablePremiumFeatures(for: existing, in: context)
                try? context.save()
            }
            return existing
        }

        let configuration = templateConfiguration(for: purpose)
        let album = Album(
            name: purpose.title,
            sortOrder: albums.count,
            defaultRetention: configuration.retention
        )
        album.purpose = purpose
        album.ocrEnabled = configuration.ocrEnabled
        album.savesLocation = configuration.savesLocation
        album.autoPins = configuration.autoPins
        album.primaryAction = configuration.primaryAction
        album.isBuiltIn = true
        album.smartRuleEnabled = PremiumAccess.isActive
        context.insert(album)

        if PremiumAccess.isActive {
            let presets = (try? context.fetch(FetchDescriptor<CapturePreset>())) ?? []
            ensurePreset(
                named: purpose.title,
                purpose: purpose,
                album: album,
                retention: configuration.retention,
                ocrEnabled: configuration.ocrEnabled,
                savesLocation: configuration.savesLocation,
                autoPins: configuration.autoPins,
                primaryAction: configuration.primaryAction,
                sortOrder: presets.count,
                existing: presets,
                context: context
            )
        }
        try? context.save()
        return album
    }

    static func upgradePremiumTemplates(in context: ModelContext) {
        guard PremiumAccess.isActive else { return }
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        for album in albums where album.isBuiltIn && premiumTemplatePurposes.contains(album.purpose) {
            enablePremiumFeatures(for: album, in: context)
        }
        try? context.save()
    }

    static func canUse(_ preset: CapturePreset, hasPremium: Bool = PremiumAccess.isActive) -> Bool {
        preset.purpose == .general || hasPremium
    }

    private static func enablePremiumFeatures(for album: Album, in context: ModelContext) {
        album.smartRuleEnabled = true
        let configuration = templateConfiguration(for: album.purpose)
        let presets = (try? context.fetch(FetchDescriptor<CapturePreset>())) ?? []
        ensurePreset(
            named: album.purpose.title,
            purpose: album.purpose,
            album: album,
            retention: configuration.retention,
            ocrEnabled: configuration.ocrEnabled,
            savesLocation: configuration.savesLocation,
            autoPins: configuration.autoPins,
            primaryAction: configuration.primaryAction,
            sortOrder: presets.count,
            existing: presets,
            context: context
        )
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
