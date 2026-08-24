import Foundation
import SwiftData

enum RetentionService {
    static func apply(
        _ policy: RetentionPolicy,
        customDate: Date? = nil,
        to item: MediaItem,
        now: Date = .now
    ) {
        item.expirationType = policy
        item.waitingForCompletion = policy == .untilComplete
        item.expirationDate = policy == .customDate ? customDate : policy.expiration(from: now)
    }

    static func statusText(for item: MediaItem, now: Date = .now) -> String {
        if item.waitingForCompletion { return L10n.text("완료 대기") }
        guard let expiration = item.expirationDate else { return L10n.text("계속 보관") }
        if expiration <= now { return L10n.text(item.isPinned ? "확인 필요" : "오늘 정리 예정") }
        if Calendar.current.isDateInToday(expiration) { return L10n.text("오늘 정리 예정") }
        let days = max(1, Calendar.current.dateComponents([.day], from: now, to: expiration).day ?? 1)
        return L10n.format("%d일 남음", days)
    }

    static func shouldMoveToRecentlyDeleted(_ item: MediaItem, now: Date = .now) -> Bool {
        guard item.deletedAt == nil,
              !item.waitingForCompletion,
              !item.isPinned,
              let expiration = item.expirationDate else { return false }
        return expiration <= now
    }
}

@MainActor
enum MediaLifecycleService {
    static func complete(_ item: MediaItem) async {
        await moveToRecentlyDeleted(item)
    }

    static func moveToRecentlyDeleted(_ item: MediaItem) async {
        await ReminderService.shared.cancel(for: item)
        item.deletedAt = .now
        item.reminderDate = nil
        item.reminderIdentifier = nil
    }

    static func restore(_ item: MediaItem) {
        item.deletedAt = nil
    }

    static func permanentlyDelete(_ item: MediaItem, from context: ModelContext) async {
        await ReminderService.shared.cancel(for: item)
        try? await MediaStorage.shared.remove(item)
        context.delete(item)
    }
}
