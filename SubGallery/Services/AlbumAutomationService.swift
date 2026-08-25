import Foundation
import SwiftData

/// What a user album does to the photos that land in it. Every entry path — camera,
/// import, share extension, smart classification — routes through here so the rules
/// cannot drift between them.
@MainActor
enum AlbumAutomationService {
    /// Stamps an album's rules onto a freshly created item. Callers still decide the
    /// album; this decides what the album means.
    static func apply(
        _ album: Album?,
        to item: MediaItem,
        overridingRetention retention: RetentionPolicy? = nil,
        fallbackRetention: RetentionPolicy = .forever,
        fallbackRetentionDate: Date? = nil
    ) {
        item.albumID = album?.id
        item.purpose = album?.purpose ?? .general
        item.analysisEnabled = album?.ocrEnabled ?? true
        item.primaryAction = album?.primaryAction ?? .automatic
        if album?.autoPins == true { item.isPinned = true }

        let policy = retention ?? album?.defaultRetention ?? fallbackRetention
        let customDate = album?.defaultRetentionDate ?? fallbackRetentionDate
        RetentionService.apply(policy, customDate: customDate, to: item)
    }

    /// Whether the nightly sweep may move this item on its own. An album set to
    /// finish manually keeps its expired photos visible until the user completes
    /// them; pinned photos are never swept, which the retention rules already ensure.
    static func allowsAutomaticCleanup(
        _ item: MediaItem,
        albums: [Album],
        isPremium: Bool = PremiumAccess.isActive
    ) -> Bool {
        guard let albumID = item.albumID else { return true }
        guard let album = albums.first(where: { $0.id == albumID }) else { return true }
        // Templates keep their own behaviour; only user albums opt out.
        guard album.purpose == .custom else { return true }
        return isPremium && album.autoCleanupEnabled
    }

    // MARK: - Summary

    /// One short line describing the album's rules, shown at the top of the
    /// automation screen so the settings can be understood at a glance.
    static func summary(for album: Album) -> String {
        var parts = [album.defaultRetention.title]
        parts.append(L10n.text(album.ocrEnabled ? "글자 검색 켬" : "글자 검색 끔"))
        if album.savesLocation { parts.append(L10n.text("위치 저장")) }
        if album.autoPins { parts.append(L10n.text("자동 고정")) }
        parts.append(L10n.text(album.autoCleanupEnabled ? "자동 정리" : "직접 완료"))
        return parts.joined(separator: " · ")
    }

    // MARK: - Applying to existing photos

    /// Photos a retention change would actually touch. Pinned photos are excluded —
    /// a pin is the user saying "keep this", and a rule change must not override it.
    static func itemsEligibleForRetroactiveRetention(
        in album: Album,
        from media: [MediaItem]
    ) -> [MediaItem] {
        media.filter { $0.albumID == album.id && $0.deletedAt == nil && !$0.isPinned }
    }

    @discardableResult
    static func applyRetentionToExisting(
        in album: Album,
        media: [MediaItem],
        context: ModelContext
    ) -> Int {
        let targets = itemsEligibleForRetroactiveRetention(in: album, from: media)
        for item in targets {
            RetentionService.apply(
                album.defaultRetention,
                customDate: album.defaultRetentionDate,
                to: item
            )
        }
        try? context.save()
        return targets.count
    }

    // MARK: - Cleanup suggestions

    struct CleanupSuggestions: Equatable {
        var agedOut: [MediaItem] = []
        var waitingForCompletion: [MediaItem] = []
        var expiringSoon: [MediaItem] = []

        var total: Int { agedOut.count + waitingForCompletion.count + expiringSoon.count }
        var isEmpty: Bool { total == 0 }

        static func == (lhs: CleanupSuggestions, rhs: CleanupSuggestions) -> Bool {
            lhs.agedOut.map(\.id) == rhs.agedOut.map(\.id)
                && lhs.waitingForCompletion.map(\.id) == rhs.waitingForCompletion.map(\.id)
                && lhs.expiringSoon.map(\.id) == rhs.expiringSoon.map(\.id)
        }
    }

    /// Derived entirely from stored fields — created date, expiry, completion flag.
    /// Nothing is inferred or predicted, and nothing is deleted: the user reviews
    /// and decides.
    static func cleanupSuggestions(
        for album: Album,
        media: [MediaItem],
        now: Date = .now,
        agedOutAfterDays: Int = 30,
        isPremium: Bool = PremiumAccess.isActive
    ) -> CleanupSuggestions {
        guard isPremium else { return CleanupSuggestions() }
        let calendar = Calendar.current
        let agedOutBefore = calendar.date(byAdding: .day, value: -agedOutAfterDays, to: now) ?? now
        let soonLimit = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        let items = media.filter { $0.albumID == album.id && $0.deletedAt == nil }

        var result = CleanupSuggestions()
        for item in items {
            // Pinned photos are deliberately kept, so they are never suggested.
            if item.isPinned { continue }
            if item.waitingForCompletion {
                result.waitingForCompletion.append(item)
                continue
            }
            if let expiration = item.expirationDate {
                if expiration <= now {
                    result.agedOut.append(item)
                } else if expiration <= soonLimit {
                    result.expiringSoon.append(item)
                }
                continue
            }
            if item.createdAt <= agedOutBefore { result.agedOut.append(item) }
        }
        return result
    }
}
