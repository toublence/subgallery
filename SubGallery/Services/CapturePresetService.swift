import SwiftData

@MainActor
enum CapturePresetService {
    static func seedBuiltIns(in context: ModelContext) {
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        let presets = (try? context.fetch(FetchDescriptor<CapturePreset>())) ?? []

        migrateUnusedLegacyTemplates(albums: albums, presets: presets, in: context)

        ensurePreset(named: L10n.text("일반"), purpose: .general, album: nil, retention: .forever,
                     ocrEnabled: true, savesLocation: false, autoPins: false, primaryAction: .automatic,
                     sortOrder: 0, existing: presets, context: context)
        try? context.save()
    }

    static let templatePurposes: [CapturePurpose] = [.receipt, .parking, .document, .qr, .temporary]

    @discardableResult
    static func addTemplate(_ purpose: CapturePurpose, in context: ModelContext) -> Album {
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        if let existing = albums.first(where: { $0.purpose == purpose }) { return existing }

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
        case .qr:
            (.sevenDays, true, false, false, .open)
        case .temporary:
            (.sevenDays, true, false, false, .automatic)
        default:
            (.forever, true, false, false, .automatic)
        }
    }

    private static func migrateUnusedLegacyTemplates(
        albums: [Album],
        presets: [CapturePreset],
        in context: ModelContext
    ) {
        let media = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        let usedAlbumIDs = Set(media.compactMap(\.albumID))
        let removableAlbumIDs = Set(albums.filter {
            $0.isBuiltIn && $0.purpose != .general && !usedAlbumIDs.contains($0.id)
        }.map(\.id))
        presets.filter {
            $0.isBuiltIn && $0.purpose != .general
                && ($0.albumID.map(removableAlbumIDs.contains) ?? true)
        }.forEach(context.delete)
        albums.filter { removableAlbumIDs.contains($0.id) }.forEach(context.delete)
    }

    private static func ensureAlbum(
        named name: String,
        purpose: CapturePurpose,
        retention: RetentionPolicy,
        ocrEnabled: Bool,
        savesLocation: Bool,
        autoPins: Bool,
        primaryAction: PrimaryMediaAction,
        existing: [Album],
        context: ModelContext
    ) -> Album {
        if let album = existing.first(where: { $0.purpose == purpose })
            ?? existing.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            album.isBuiltIn = true
            return album
        }
        let album = Album(name: name, sortOrder: existing.count, defaultRetention: retention)
        album.purpose = purpose
        album.ocrEnabled = ocrEnabled
        album.savesLocation = savesLocation
        album.autoPins = autoPins
        album.primaryAction = primaryAction
        album.isBuiltIn = true
        context.insert(album)
        return album
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
