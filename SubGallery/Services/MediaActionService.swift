import EventKit
import MapKit
import UIKit

enum MediaActionError: LocalizedError {
    case invalidValue
    case calendarDenied
    case remindersDenied
    case noCalendar

    var errorDescription: String? {
        switch self {
        case .invalidValue: L10n.text("인식된 정보를 사용할 수 없습니다.")
        case .calendarDenied: L10n.text("캘린더 접근을 허용해 주세요.")
        case .remindersDenied: L10n.text("미리알림 접근을 허용해 주세요.")
        case .noCalendar: L10n.text("저장할 캘린더를 찾을 수 없습니다.")
        }
    }
}

@MainActor
enum MediaActionService {
    static func copy(_ value: String) {
        UIPasteboard.general.string = value
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func openURL(_ value: String) throws {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw MediaActionError.invalidValue
        }
        UIApplication.shared.open(url)
    }

    static func call(_ number: String) throws {
        let allowed = CharacterSet(charactersIn: "+0123456789")
        let normalized = String(number.unicodeScalars.filter(allowed.contains))
        guard !normalized.isEmpty, let url = URL(string: "tel:\(normalized)") else {
            throw MediaActionError.invalidValue
        }
        UIApplication.shared.open(url)
    }

    static func openMail(_ address: String) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "mailto:\(encoded)") else {
            throw MediaActionError.invalidValue
        }
        UIApplication.shared.open(url)
    }

    static func openMessage(_ number: String) throws {
        let allowed = CharacterSet(charactersIn: "+0123456789")
        let normalized = String(number.unicodeScalars.filter(allowed.contains))
        guard !normalized.isEmpty, let url = URL(string: "sms:\(normalized)") else {
            throw MediaActionError.invalidValue
        }
        UIApplication.shared.open(url)
    }

    static func openAddress(_ address: String) throws {
        guard let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://maps.apple.com/?q=\(encoded)") else {
            throw MediaActionError.invalidValue
        }
        UIApplication.shared.open(url)
    }

    static func openLocation(latitude: Double, longitude: Double, name: String) {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = name
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: coordinate),
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
    }

    static func addCalendarEvent(title: String, date: Date) async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { throw MediaActionError.calendarDenied }
        guard let calendar = store.defaultCalendarForNewEvents else { throw MediaActionError.noCalendar }
        let event = EKEvent(eventStore: store)
        event.title = title.isEmpty ? L10n.text("SubGallery에서 추가한 일정") : title
        event.startDate = date
        event.endDate = date.addingTimeInterval(60 * 60)
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
    }

    static func addReminder(title: String, date: Date?) async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { throw MediaActionError.remindersDenied }
        guard let calendar = store.defaultCalendarForNewReminders() else { throw MediaActionError.noCalendar }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title.isEmpty ? L10n.text("SubGallery 사진 확인") : title
        reminder.calendar = calendar
        if let date {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: date
            )
        }
        try store.save(reminder, commit: true)
    }
}
