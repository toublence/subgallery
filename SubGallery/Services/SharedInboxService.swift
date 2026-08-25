import Foundation
import SwiftData

struct SharedAlbumOption: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
}

struct SharedInboxManifest: Codable, Sendable {
    let fileName: String
    let originalName: String
    let destinationToken: String
    let retentionRaw: String
}

@MainActor
enum SharedInboxService {
    static let appGroupID = "group.com.namslab.subgallery"

    static func publishConfiguration(albums: [Album]) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(albums.map { SharedAlbumOption(id: $0.id, name: $0.displayName) }) else { return }
        defaults.set(data, forKey: "shared.albums")
        defaults.set(UserDefaults.standard.string(forKey: "defaults.shareDestination") ?? "temporary", forKey: "shared.defaultDestination")
    }

    static func ingestPendingItems(in context: ModelContext) async {
        guard let inbox = inboxURL else { return }
        let fileManager = FileManager.default
        guard let manifests = try? fileManager.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "json" }) else { return }
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []

        for manifestURL in manifests {
            do {
                let manifest = try JSONDecoder().decode(SharedInboxManifest.self, from: Data(contentsOf: manifestURL))
                let sourceURL = inbox.appending(path: manifest.fileName)
                let stored = try await MediaStorage.shared.store(fileAt: sourceURL)
                let target = resolvedDestination(manifest.destinationToken)
                let album: Album? = {
                    guard case .album(let id) = target else { return nil }
                    return albums.first { $0.id == id }
                }()
                let item = MediaItem(
                    kind: stored.kind,
                    source: .files,
                    localPath: stored.relativePath,
                    thumbnailPath: stored.thumbnailRelativePath,
                    fileName: manifest.originalName,
                    createdAt: stored.capturedAt ?? .now,
                    fileSize: stored.fileSize,
                    width: stored.width,
                    height: stored.height,
                    duration: stored.duration
                )
                item.latitude = stored.latitude
                item.longitude = stored.longitude
                AlbumAutomationService.apply(
                    album,
                    to: item,
                    // The share sheet's own choice, when the user made one, outranks
                    // the album default.
                    overridingRetention: RetentionPolicy(rawValue: manifest.retentionRaw),
                    fallbackRetention: target == .temporary ? .sevenDays : defaultRetention
                )
                context.insert(item)
                try context.save()
                OCRService.enqueue(item, in: context)
                try? fileManager.removeItem(at: sourceURL)
                try? fileManager.removeItem(at: manifestURL)
            } catch {
                continue
            }
        }
    }

    private static var inboxURL: URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        let inbox = container.appending(path: "ShareInbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    private static func resolvedDestination(_ token: String) -> StorageDestination {
        if token == "default" {
            return StorageDestination(token: UserDefaults.standard.string(forKey: "defaults.shareDestination") ?? "temporary")
        }
        return StorageDestination(token: token)
    }

    private static var defaultRetention: RetentionPolicy {
        RetentionPolicy(rawValue: UserDefaults.standard.string(forKey: "storage.defaultRetention") ?? "") ?? .forever
    }
}
