import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

struct StoredMedia: Sendable {
    let kind: MediaKind
    let relativePath: String
    let thumbnailRelativePath: String?
    let fileSize: Int64
    let width: Int
    let height: Int
    let duration: Double
}

actor MediaStorage {
    static let shared = MediaStorage()

    private let fileManager = FileManager.default

    nonisolated static var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "SubGallery", directoryHint: .isDirectory)
    }

    nonisolated static func url(for relativePath: String) -> URL {
        rootURL.appending(path: relativePath)
    }

    func store(data: Data, type: UTType?, preferredName: String? = nil) throws -> StoredMedia {
        try prepareDirectories()
        let kind: MediaKind = type?.conforms(to: .movie) == true ? .video : .photo
        let fallback = kind == .video ? "mov" : "jpg"
        let fileExtension = type?.preferredFilenameExtension ?? fallback
        let id = UUID().uuidString
        let filename = preferredName.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? id
        let relativePath = "Media/\(filename)-\(id).\(fileExtension)"
        let destination = Self.url(for: relativePath)
        try data.write(to: destination, options: .atomic)
        return try inspectAndThumbnail(url: destination, relativePath: relativePath, kind: kind, id: id)
    }

    func store(fileAt source: URL, type: UTType? = nil) throws -> StoredMedia {
        try prepareDirectories()
        let resolvedType = type ?? UTType(filenameExtension: source.pathExtension)
        let kind: MediaKind = resolvedType?.conforms(to: .movie) == true ? .video : .photo
        let ext = source.pathExtension.isEmpty ? (kind == .video ? "mov" : "jpg") : source.pathExtension
        let id = UUID().uuidString
        let relativePath = "Media/\(id).\(ext)"
        let destination = Self.url(for: relativePath)
        try fileManager.copyItem(at: source, to: destination)
        return try inspectAndThumbnail(url: destination, relativePath: relativePath, kind: kind, id: id)
    }

    func remove(_ item: MediaItem) throws {
        try? fileManager.removeItem(at: Self.url(for: item.localPath))
        if let thumbnailPath = item.thumbnailPath {
            try? fileManager.removeItem(at: Self.url(for: thumbnailPath))
        }
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: Self.rootURL.appending(path: "Media"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: Self.rootURL.appending(path: "Thumbnails"), withIntermediateDirectories: true)
    }

    private func inspectAndThumbnail(url: URL, relativePath: String, kind: MediaKind, id: String) throws -> StoredMedia {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        var width = 0
        var height = 0
        var duration = 0.0
        var thumbnail: CGImage?

        if kind == .photo, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
                height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 720
            ]
            thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else if kind == .video {
            let asset = AVURLAsset(url: url)
            duration = CMTimeGetSeconds(asset.duration)
            if let track = asset.tracks(withMediaType: .video).first {
                let transformed = track.naturalSize.applying(track.preferredTransform)
                width = Int(abs(transformed.width))
                height = Int(abs(transformed.height))
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            thumbnail = try? generator.copyCGImage(at: CMTime(seconds: min(0.2, duration), preferredTimescale: 600), actualTime: nil)
        }

        var thumbnailPath: String?
        if let thumbnail, let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.82) {
            let relative = "Thumbnails/\(id).jpg"
            try jpeg.write(to: Self.url(for: relative), options: .atomic)
            thumbnailPath = relative
        }

        return StoredMedia(
            kind: kind,
            relativePath: relativePath,
            thumbnailRelativePath: thumbnailPath,
            fileSize: size,
            width: width,
            height: height,
            duration: duration
        )
    }
}

