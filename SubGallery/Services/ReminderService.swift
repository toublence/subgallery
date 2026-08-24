import Foundation
import UserNotifications

enum ReminderAuthorizationError: LocalizedError {
    case denied

    var errorDescription: String? {
        L10n.text("알림이 허용되지 않았습니다. 설정 앱에서 SubGallery 알림을 허용해 주세요.")
    }
}

actor ReminderService {
    static let shared = ReminderService()
    private let center = UNUserNotificationCenter.current()

    func schedule(for item: MediaItem, at date: Date, requestsPermission: Bool = true) async throws -> String {
        if requestsPermission {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    throw ReminderAuthorizationError.denied
                }
            case .denied: throw ReminderAuthorizationError.denied
            default: break
            }
        }

        let identifier = notificationIdentifier(for: item.id)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = "SubGallery"
        content.body = L10n.text("저장해둔 사진을 확인할 시간이에요.")
        content.sound = .default
        content.userInfo = ["mediaID": item.id.uuidString]
        if let path = item.thumbnailPath,
           let attachment = try? UNNotificationAttachment(
            identifier: "thumbnail",
            url: MediaStorage.url(for: path)
           ) {
            content.attachments = [attachment]
        }

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: max(date, Date.now.addingTimeInterval(1))
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        return identifier
    }

    func cancel(for item: MediaItem) {
        let identifier = item.reminderIdentifier ?? notificationIdentifier(for: item.id)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func schedulePinnedExpirationSafetyIfAuthorized(for item: MediaItem) async -> String? {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
              item.reminderIdentifier == nil else { return nil }
        return try? await schedule(for: item, at: .now.addingTimeInterval(5), requestsPermission: false)
    }

    private func notificationIdentifier(for id: UUID) -> String {
        "media.\(id.uuidString)"
    }
}

enum ReminderDateOption: String, CaseIterable, Identifiable {
    case oneHour
    case tonight
    case tomorrow
    case weekend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneHour: L10n.text("1시간 후")
        case .tonight: L10n.text("오늘 저녁")
        case .tomorrow: L10n.text("내일")
        case .weekend: L10n.text("이번 주말")
        }
    }

    func date(from now: Date = .now) -> Date {
        let calendar = Calendar.current
        switch self {
        case .oneHour:
            return now.addingTimeInterval(60 * 60)
        case .tonight:
            let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now
            return tonight > now ? tonight : (calendar.date(byAdding: .day, value: 1, to: tonight) ?? now)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        case .weekend:
            let weekday = calendar.component(.weekday, from: now)
            let daysUntilSaturday = weekday == 7 ? 7 : (7 - weekday)
            let saturday = calendar.date(byAdding: .day, value: daysUntilSaturday, to: now) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: saturday) ?? saturday
        }
    }
}
