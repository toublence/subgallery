import Foundation
import SwiftData

enum MediaKind: String, Codable, CaseIterable {
    case photo
    case video
}

enum MediaSource: String, Codable {
    case camera
    case photos
    case files
}

enum AppStartScreen: String, CaseIterable, Identifiable {
    case library
    case camera
    case last

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: L10n.text("보관함")
        case .camera: L10n.text("카메라")
        case .last: L10n.text("마지막 화면")
        }
    }
}

enum RetentionPolicy: String, Codable, CaseIterable, Identifiable {
    case forever
    case today
    case oneDay
    case sevenDays
    case thirtyDays
    case customDate
    case untilComplete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: L10n.text("오늘까지")
        case .oneDay: L10n.text("24시간")
        case .sevenDays: L10n.text("7일")
        case .thirtyDays: L10n.text("30일")
        case .customDate: L10n.text("날짜 지정")
        case .untilComplete: L10n.text("완료할 때까지")
        case .forever: L10n.text("계속 보관")
        }
    }

    func expiration(from date: Date = .now) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .today: return calendar.date(bySettingHour: 23, minute: 59, second: 59, of: date)
        case .oneDay: return calendar.date(byAdding: .day, value: 1, to: date)
        case .sevenDays: return calendar.date(byAdding: .day, value: 7, to: date)
        case .thirtyDays: return calendar.date(byAdding: .day, value: 30, to: date)
        case .customDate, .untilComplete, .forever: return nil
        }
    }
}

enum OCRStatus: String, Codable {
    case pending
    case processing
    case completed
    case failed
    case notApplicable
}

@Model
final class MediaItem {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var sourceRaw: String
    var localPath: String
    var thumbnailPath: String?
    var createdAt: Date
    var importedAt: Date
    var albumID: UUID?
    var favorite: Bool
    var expirationTypeRaw: String = "forever"
    var expirationDate: Date?
    var waitingForCompletion: Bool = false
    var isPinned: Bool = false
    var reminderDate: Date?
    var reminderIdentifier: String?
    var recognizedText: String = ""
    var ocrStatusRaw: String = "notApplicable"
    var fileName: String = ""
    var note: String = ""
    var deletedAt: Date?
    var fileSize: Int64
    var width: Int
    var height: Int
    var duration: Double
    var latitude: Double?
    var longitude: Double?

    init(
        id: UUID = UUID(), kind: MediaKind, source: MediaSource,
        localPath: String, thumbnailPath: String? = nil,
        fileName: String? = nil,
        createdAt: Date = .now, albumID: UUID? = nil,
        expirationDate: Date? = nil, fileSize: Int64 = 0,
        width: Int = 0, height: Int = 0, duration: Double = 0
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.sourceRaw = source.rawValue
        self.localPath = localPath
        self.thumbnailPath = thumbnailPath
        self.createdAt = createdAt
        self.importedAt = .now
        self.albumID = albumID
        self.favorite = false
        self.expirationTypeRaw = RetentionPolicy.forever.rawValue
        self.expirationDate = expirationDate
        self.waitingForCompletion = false
        self.isPinned = false
        self.reminderDate = nil
        self.reminderIdentifier = nil
        self.recognizedText = ""
        self.ocrStatusRaw = kind == .photo ? OCRStatus.pending.rawValue : OCRStatus.notApplicable.rawValue
        self.fileName = fileName ?? URL(fileURLWithPath: localPath).lastPathComponent
        self.note = ""
        self.deletedAt = nil
        self.fileSize = fileSize
        self.width = width
        self.height = height
        self.duration = duration
    }

    var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .photo }
    var source: MediaSource { MediaSource(rawValue: sourceRaw) ?? .files }
    var expirationType: RetentionPolicy {
        get { RetentionPolicy(rawValue: expirationTypeRaw) ?? (expirationDate == nil ? .forever : .customDate) }
        set { expirationTypeRaw = newValue.rawValue }
    }
    var ocrStatus: OCRStatus {
        get { OCRStatus(rawValue: ocrStatusRaw) ?? .pending }
        set { ocrStatusRaw = newValue.rawValue }
    }
}

@Model
final class Album {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var sortOrder: Int
    var coverMediaID: UUID?
    var defaultRetentionRaw: String
    var defaultRetentionDate: Date?

    init(name: String, sortOrder: Int = 0, defaultRetention: RetentionPolicy = .forever) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.sortOrder = sortOrder
        self.coverMediaID = nil
        self.defaultRetentionRaw = defaultRetention.rawValue
        self.defaultRetentionDate = nil
    }

    var defaultRetention: RetentionPolicy {
        get { RetentionPolicy(rawValue: defaultRetentionRaw) ?? .forever }
        set { defaultRetentionRaw = newValue.rawValue }
    }
}

@Model
final class CapturePreset {
    @Attribute(.unique) var id: UUID
    var name: String
    var albumID: UUID?
    var retentionRaw: String
    var savesLocation: Bool
    var aspectRatio: String
    var captureMode: String

    init(name: String, albumID: UUID? = nil, retention: RetentionPolicy = .sevenDays) {
        self.id = UUID()
        self.name = name
        self.albumID = albumID
        self.retentionRaw = retention.rawValue
        self.savesLocation = false
        self.aspectRatio = "4:3"
        self.captureMode = "photo"
    }
}
