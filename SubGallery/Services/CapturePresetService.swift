import SwiftData

@MainActor
enum CapturePresetService {
    static func seedBuiltIns(in context: ModelContext) {
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        let presets = (try? context.fetch(FetchDescriptor<CapturePreset>())) ?? []

        let receipt = ensureAlbum(
            named: L10n.text("영수증"),
            purpose: .receipt,
            retention: .thirtyDays,
            ocrEnabled: true,
            savesLocation: false,
            autoPins: false,
            primaryAction: .shareAndComplete,
            existing: albums,
            context: context
        )
        let parking = ensureAlbum(
            named: L10n.text("주차"),
            purpose: .parking,
            retention: .untilComplete,
            ocrEnabled: false,
            savesLocation: true,
            autoPins: true,
            primaryAction: .findCar,
            existing: albums,
            context: context
        )
        let document = ensureAlbum(
            named: L10n.text("문서"),
            purpose: .document,
            retention: .untilComplete,
            ocrEnabled: true,
            savesLocation: false,
            autoPins: false,
            primaryAction: .automatic,
            existing: albums,
            context: context
        )
        _ = ensureAlbum(
            named: L10n.text("여행"),
            purpose: .travel,
            retention: .forever,
            ocrEnabled: true,
            savesLocation: true,
            autoPins: false,
            primaryAction: .automatic,
            existing: albums,
            context: context
        )

        ensurePreset(named: L10n.text("일반"), purpose: .general, album: nil, retention: .forever,
                     ocrEnabled: true, savesLocation: false, autoPins: false, primaryAction: .automatic,
                     sortOrder: 0, existing: presets, context: context)
        ensurePreset(named: receipt.name, purpose: .receipt, album: receipt, retention: .thirtyDays,
                     ocrEnabled: true, savesLocation: false, autoPins: false, primaryAction: .shareAndComplete,
                     sortOrder: 1, existing: presets, context: context)
        ensurePreset(named: parking.name, purpose: .parking, album: parking, retention: .untilComplete,
                     ocrEnabled: false, savesLocation: true, autoPins: true, primaryAction: .findCar,
                     sortOrder: 2, existing: presets, context: context)
        ensurePreset(named: document.name, purpose: .document, album: document, retention: .untilComplete,
                     ocrEnabled: true, savesLocation: false, autoPins: false, primaryAction: .automatic,
                     sortOrder: 3, existing: presets, context: context)
        try? context.save()
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
