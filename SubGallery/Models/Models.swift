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

enum RetentionPolicy: String, Codable, CaseIterable, Identifiable {
    case today
    case oneDay
    case sevenDays
    case thirtyDays
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "오늘까지"
        case .oneDay: "24시간"
        case .sevenDays: "7일"
        case .thirtyDays: "30일"
        case .forever: "계속 보관"
        }
    }

    func expiration(from date: Date = .now) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .today: return calendar.date(bySettingHour: 23, minute: 59, second: 59, of: date)
        case .oneDay: return calendar.date(byAdding: .day, value: 1, to: date)
        case .sevenDays: return calendar.date(byAdding: .day, value: 7, to: date)
        case .thirtyDays: return calendar.date(byAdding: .day, value: 30, to: date)
        case .forever: return nil
        }
    }
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
    var expirationDate: Date?
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
        self.expirationDate = expirationDate
        self.deletedAt = nil
        self.fileSize = fileSize
        self.width = width
        self.height = height
        self.duration = duration
    }

    var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .photo }
    var source: MediaSource { MediaSource(rawValue: sourceRaw) ?? .files }
}

@Model
final class Album {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var sortOrder: Int
    var coverMediaID: UUID?
    var defaultRetentionRaw: String

    init(name: String, sortOrder: Int = 0, defaultRetention: RetentionPolicy = .forever) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.sortOrder = sortOrder
        self.defaultRetentionRaw = defaultRetention.rawValue
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
