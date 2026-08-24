import Photos
import SwiftUI
import UIKit

enum MediaExportError: LocalizedError {
    case photosAccessDenied
    case noItems

    var errorDescription: String? {
        switch self {
        case .photosAccessDenied: L10n.text("사진 앱에 추가할 권한이 필요합니다.")
        case .noItems: L10n.text("내보낼 항목이 없습니다.")
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

        try await PHPhotoLibrary.shared().performChanges {
            for item in items {
                let request = PHAssetCreationRequest.forAsset()
                let type: PHAssetResourceType = item.kind == .video ? .video : .photo
                request.addResource(with: type, fileURL: MediaStorage.url(for: item.localPath), options: nil)
            }
        }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

struct FilesExportPicker: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) { }
}
