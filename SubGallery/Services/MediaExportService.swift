import AVFoundation
import Photos
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum MediaExportError: LocalizedError {
    case photosAccessDenied
    case noItems
    case exportFailed
    case premiumRequired

    var errorDescription: String? {
        switch self {
        case .photosAccessDenied: L10n.text("사진 앱에 추가할 권한이 필요합니다.")
        case .noItems: L10n.text("내보낼 항목이 없습니다.")
        case .exportFailed: L10n.text("메타데이터를 제거한 파일을 만들 수 없습니다.")
        case .premiumRequired: L10n.text("개인정보 보호 내보내기는 Premium 기능입니다.")
        }
    }
}

enum MediaExportService {
    static func saveToPhotos(_ items: [MediaItem]) async throws {
        guard !items.isEmpty else { throw MediaExportError.noItems }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw MediaExportError.photosAccessDenied
        }

        let stripsMetadata = PremiumAccess.isActive
            && UserDefaults.standard.bool(forKey: "privacy.stripMetadata")
        let urls = try await preparedURLs(for: items, strippingMetadata: stripsMetadata)
        defer { cleanupPreparedURLs(urls) }

        try await PHPhotoLibrary.shared().performChanges {
            for (item, url) in zip(items, urls) {
                let request = PHAssetCreationRequest.forAsset()
                let type: PHAssetResourceType = item.kind == .video ? .video : .photo
                request.addResource(with: type, fileURL: url, options: nil)
            }
        }
        SubGalleryAnalytics.mediaExported(
            destination: .photos,
            metadataRemoved: stripsMetadata
        )
    }

    static func preparedURLs(for items: [MediaItem], strippingMetadata: Bool) async throws -> [URL] {
        guard !items.isEmpty else { throw MediaExportError.noItems }
        guard strippingMetadata && PremiumAccess.isActive else {
            return items.map(\.mediaURL)
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SubGalleryExport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var urls: [URL] = []
            for item in items {
                let source = item.mediaURL
                if item.kind == .photo {
                    urls.append(try metadataFreePhoto(source: source, destinationDirectory: directory))
                } else {
                    urls.append(try await metadataFreeVideo(source: source, destinationDirectory: directory))
                }
            }
            return urls
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func metadataFreeCopy(of item: MediaItem) async throws -> StoredMedia {
        guard PremiumAccess.isActive else { throw MediaExportError.premiumRequired }
        let urls = try await preparedURLs(for: [item], strippingMetadata: true)
        defer { cleanupPreparedURLs(urls) }
        guard let url = urls.first else { throw MediaExportError.exportFailed }
        let type: UTType = item.kind == .video ? .quickTimeMovie : (url.pathExtension.lowercased() == "png" ? .png : .jpeg)
        return try await MediaStorage.shared.store(fileAt: url, type: type)
    }

    static func cleanupPreparedURLs(_ urls: [URL]) {
        let directories = Set(urls.map { $0.deletingLastPathComponent() }.filter {
            $0.lastPathComponent.hasPrefix("SubGalleryExport-")
        })
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private static func metadataFreePhoto(source: URL, destinationDirectory: URL) throws -> URL {
        guard let image = UIImage(contentsOfFile: source.path) else { throw MediaExportError.exportFailed }
        let normalized = UIGraphicsImageRenderer(size: image.size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        let keepsPNG = source.pathExtension.lowercased() == "png"
        guard let data = keepsPNG ? normalized.pngData() : normalized.jpegData(compressionQuality: 0.96) else {
            throw MediaExportError.exportFailed
        }
        let baseName = source.deletingPathExtension().lastPathComponent
        let destination = destinationDirectory.appending(path: "\(baseName).\(keepsPNG ? "png" : "jpg")")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static func metadataFreeVideo(source: URL, destinationDirectory: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaExportError.exportFailed
        }
        exporter.metadata = []
        let destination = destinationDirectory.appending(path: "\(source.deletingPathExtension().lastPathComponent).mov")
        try await exporter.export(to: destination, as: .mov)
        return destination
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    /// Lets QR payloads be shared as plain text through the same sheet the media
    /// export path already uses.
    var text: String? = nil
    var onComplete: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let items: [Any] = urls.isEmpty ? [text].compactMap { $0 } : urls
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            DispatchQueue.main.async { context.coordinator.onComplete?(completed) }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }

    final class Coordinator {
        let onComplete: ((Bool) -> Void)?

        init(onComplete: ((Bool) -> Void)?) {
            self.onComplete = onComplete
        }
    }
}

struct FilesExportPicker: UIViewControllerRepresentable {
    let urls: [URL]
    var onComplete: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: ((Bool) -> Void)?

        init(onComplete: ((Bool) -> Void)?) { self.onComplete = onComplete }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onComplete?(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onComplete?(false)
        }
    }
}
