import CoreImage
import Foundation
import SwiftData
import Vision

actor OCRService {
    static let shared = OCRService()

    func recognizeText(at url: URL) throws -> String {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw OCRServiceError.unreadableImage
        }

        let enhanced = image
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.35
            ])
            .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.5])

        let automatic = makeRequest(automaticallyDetectsLanguage: true)
        try VNImageRequestHandler(ciImage: image, options: [:]).perform([automatic])

        let koreanFocused = makeRequest(automaticallyDetectsLanguage: false)
        koreanFocused.recognitionLanguages = ["ko-KR", "en-US"]
        try VNImageRequestHandler(ciImage: enhanced, options: [:]).perform([koreanFocused])

        var seen = Set<String>()
        return [automatic, koreanFocused]
            .flatMap { $0.results ?? [] }
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { seen.insert($0).inserted }
            .joined(separator: "\n")
    }

    private func makeRequest(automaticallyDetectsLanguage: Bool) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        return request
    }

    @MainActor
    static func enqueue(_ item: MediaItem, in context: ModelContext, force: Bool = false) {
        guard item.kind == .photo, force || item.ocrStatus == .pending else { return }
        item.ocrStatus = .processing
        let url = MediaStorage.url(for: item.localPath)

        Task(priority: .utility) {
            do {
                let text = try await OCRService.shared.recognizeText(at: url)
                item.recognizedText = text
                item.ocrStatus = .completed
            } catch {
                item.ocrStatus = .failed
            }
            try? context.save()
        }
    }
}

private enum OCRServiceError: Error {
    case unreadableImage
}
