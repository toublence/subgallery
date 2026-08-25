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
    let fileName: String
    let fileSize: Int64
    let width: Int
    let height: Int
    let duration: Double
    let capturedAt: Date?
    let latitude: Double?
    let longitude: Double?
}

struct StoredMediaMetadata: Sendable {
    let capturedAt: Date?
    let latitude: Double?
    let longitude: Double?
}

struct MediaMetadataEntry: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
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

    /// Restores a CloudKit-downloaded asset into the app's local media cache.
    /// Existing local files always win so normal capture and editing stay fast.
    nonisolated static func materializedURL(for relativePath: String, cloudData: Data?) -> URL {
        let destination = url(for: relativePath)
        guard !FileManager.default.fileExists(atPath: destination.path), let cloudData else {
            return destination
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try cloudData.write(to: destination, options: .atomic)
        } catch {
            // Callers display their existing unavailable-file state if recovery fails.
        }
        return destination
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
        return try inspectAndThumbnail(
            url: destination,
            relativePath: relativePath,
            kind: kind,
            id: id,
            fileName: preferredName ?? destination.lastPathComponent
        )
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
        return try inspectAndThumbnail(
            url: destination,
            relativePath: relativePath,
            kind: kind,
            id: id,
            fileName: source.lastPathComponent
        )
    }

    func remove(_ item: MediaItem) throws {
        try? fileManager.removeItem(at: Self.url(for: item.localPath))
        if let thumbnailPath = item.thumbnailPath {
            try? fileManager.removeItem(at: Self.url(for: thumbnailPath))
        }
    }

    func remove(_ stored: StoredMedia) {
        try? fileManager.removeItem(at: Self.url(for: stored.relativePath))
        if let thumbnailPath = stored.thumbnailRelativePath {
            try? fileManager.removeItem(at: Self.url(for: thumbnailPath))
        }
    }

    func metadata(for relativePath: String) -> StoredMediaMetadata {
        let url = Self.url(for: relativePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return StoredMediaMetadata(capturedAt: nil, latitude: nil, longitude: nil)
        }
        let values = imageLocationMetadata(from: properties)
        return StoredMediaMetadata(capturedAt: values.0, latitude: values.1, longitude: values.2)
    }

    func detailedMetadata(for relativePath: String) -> [MediaMetadataEntry] {
        let url = Self.url(for: relativePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return []
        }

        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        var entries: [MediaMetadataEntry] = []

        func append(_ id: String, _ title: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            entries.append(MediaMetadataEntry(id: id, title: title, value: value))
        }

        append("cameraMake", "제조사", tiff?[kCGImagePropertyTIFFMake] as? String)
        append("cameraModel", "카메라", tiff?[kCGImagePropertyTIFFModel] as? String)
        append("lensModel", "렌즈", exif?[kCGImagePropertyExifLensModel] as? String)
        append("software", "소프트웨어", tiff?[kCGImagePropertyTIFFSoftware] as? String)

        if let focalLength = metadataNumber(exif?[kCGImagePropertyExifFocalLength]) {
            append("focalLength", "초점 거리", formattedNumber(focalLength, maximumFractionDigits: 1) + " mm")
        }
        if let focalLength35 = metadataNumber(exif?[kCGImagePropertyExifFocalLenIn35mmFilm]) {
            append("focalLength35", "35mm 환산", formattedNumber(focalLength35, maximumFractionDigits: 0) + " mm")
        }
        if let aperture = metadataNumber(exif?[kCGImagePropertyExifFNumber]) {
            append("aperture", "조리개", "ƒ/" + formattedNumber(aperture, maximumFractionDigits: 1))
        }
        if let exposure = metadataNumber(exif?[kCGImagePropertyExifExposureTime]), exposure > 0 {
            let value = exposure < 1
                ? "1/\(Int((1 / exposure).rounded()))초"
                : formattedNumber(exposure, maximumFractionDigits: 2) + "초"
            append("exposure", "셔터 속도", value)
        }
        if let isoValues = exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber],
           let iso = isoValues.first {
            append("iso", "ISO", String(iso.intValue))
        }
        if let profile = properties[kCGImagePropertyProfileName] as? String {
            append("colorProfile", "색상 프로파일", profile)
        }
        if let altitude = metadataNumber(gps?[kCGImagePropertyGPSAltitude]) {
            append("altitude", "고도", formattedNumber(altitude, maximumFractionDigits: 1) + " m")
        }
        let location = imageLocationMetadata(from: properties)
        if let latitude = location.1, let longitude = location.2 {
            append(
                "location",
                "위치",
                "\(formattedNumber(latitude, maximumFractionDigits: 6)), \(formattedNumber(longitude, maximumFractionDigits: 6))"
            )
        }
        return entries
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: Self.rootURL.appending(path: "Media"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: Self.rootURL.appending(path: "Thumbnails"), withIntermediateDirectories: true)
    }

    private func inspectAndThumbnail(
        url: URL,
        relativePath: String,
        kind: MediaKind,
        id: String,
        fileName: String
    ) throws -> StoredMedia {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        var width = 0
        var height = 0
        var duration = 0.0
        var thumbnail: CGImage?
        var capturedAt: Date?
        var latitude: Double?
        var longitude: Double?

        if kind == .photo, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
                height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
                (capturedAt, latitude, longitude) = imageLocationMetadata(from: properties)
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
            fileName: fileName,
            fileSize: size,
            width: width,
            height: height,
            duration: duration,
            capturedAt: capturedAt,
            latitude: latitude,
            longitude: longitude
        )
    }

    private func imageLocationMetadata(
        from properties: [CFString: Any]
    ) -> (Date?, Double?, Double?) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateString = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? tiff?[kCGImagePropertyTIFFDateTime] as? String

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let capturedAt = dateString.flatMap(formatter.date(from:))

        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              var latitude = metadataNumber(gps[kCGImagePropertyGPSLatitude]),
              var longitude = metadataNumber(gps[kCGImagePropertyGPSLongitude]) else {
            return (capturedAt, nil, nil)
        }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" {
            latitude *= -1
        }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" {
            longitude *= -1
        }
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            return (capturedAt, nil, nil)
        }
        return (capturedAt, latitude, longitude)
    }

    private func metadataNumber(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private func formattedNumber(_ value: Double, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
