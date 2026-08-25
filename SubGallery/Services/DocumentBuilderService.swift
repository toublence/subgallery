import CoreGraphics
import Foundation
import PDFKit
import Security
import SwiftData
import UIKit
import Vision

@Model
final class Document {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date.now
    var pageCount: Int = 0
    /// Relative to `MediaStorage.rootURL`, matching how media paths are stored, so
    /// the container can move between installs without breaking references.
    var pdfRelativePath: String = ""
    var thumbnailRelativePath: String?
    var recognizedText: String = ""
    var sourceItemIDsJSON: String = "[]"

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        pageCount: Int,
        pdfRelativePath: String,
        thumbnailRelativePath: String? = nil,
        recognizedText: String = "",
        sourceItemIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.pageCount = pageCount
        self.pdfRelativePath = pdfRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.recognizedText = recognizedText
        self.sourceItemIDs = sourceItemIDs
    }

    var sourceItemIDs: [UUID] {
        get {
            (try? JSONDecoder().decode([UUID].self, from: Data(sourceItemIDsJSON.utf8))) ?? []
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            sourceItemIDsJSON = String(decoding: data, as: UTF8.self)
        }
    }

    var pdfURL: URL { MediaStorage.url(for: pdfRelativePath) }

    var thumbnailURL: URL? {
        thumbnailRelativePath.map(MediaStorage.url(for:))
    }

    var searchText: String {
        [title, recognizedText].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

// MARK: - Free usage

/// The free-document rule as a value, mirroring `TravelMapTrialPolicy`, so the
/// counting can be tested without touching the keychain.
struct DocumentTrialPolicy: Equatable {
    static let freeUseLimit = 3
    private(set) var used: Int

    init(used: Int) {
        self.used = min(max(used, 0), Self.freeUseLimit)
    }

    var remaining: Int { max(0, Self.freeUseLimit - used) }
    var isLastFreeUse: Bool { remaining == 1 }
    func canBuild(isPremium: Bool) -> Bool { isPremium || remaining > 0 }

    /// Applied only after a document has actually been written and saved. Opening
    /// the builder, cancelling, or a failed export never reaches this.
    func consumingIfEligible(isPremium: Bool) -> Self {
        guard !isPremium, remaining > 0 else { return self }
        return Self(used: used + 1)
    }
}

/// Counts completed documents for free users. Kept in the keychain rather than
/// `UserDefaults` because keychain items survive a delete-and-reinstall, so the
/// three free documents cannot be reset by removing the app.
@MainActor
enum DocumentBuilderUsageStore {
    static let freeLimit = DocumentTrialPolicy.freeUseLimit

    private static let service = "com.namslab.subgallery.document-builder"
    private static let account = "documentBuilderFreeUsesUsed"

    static var used: Int {
        guard let data = read(), let value = Int(String(decoding: data, as: UTF8.self)) else { return 0 }
        return DocumentTrialPolicy(used: value).used
    }

    static var remaining: Int { DocumentTrialPolicy(used: used).remaining }

    static func hasFreeUseAvailable(isPremium: Bool) -> Bool {
        DocumentTrialPolicy(used: used).canBuild(isPremium: isPremium)
    }

    static func isLastFreeUse(isPremium: Bool) -> Bool {
        !isPremium && DocumentTrialPolicy(used: used).isLastFreeUse
    }

    @discardableResult
    static func recordSuccessfulBuild(isPremium: Bool) -> Int {
        let current = DocumentTrialPolicy(used: used)
        let next = current.consumingIfEligible(isPremium: isPremium)
        guard next != current else { return current.remaining }
        write(next.used)
        return next.remaining
    }

    #if DEBUG
    static func configureForTesting(used value: Int) { write(value) }
    #endif

    private static func write(_ value: Int) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(String(value).utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Page

/// One page on its way into a document. Holds the image itself so scanner output,
/// imported photos and library items all travel the same path.
struct DocumentPage: Identifiable, Equatable {
    enum Rendering: String, CaseIterable, Identifiable {
        case original, color, monochrome

        var id: String { rawValue }

        var title: String {
            switch self {
            case .original: L10n.text("원본")
            case .color: L10n.text("컬러 문서")
            case .monochrome: L10n.text("흑백")
            }
        }
    }

    let id: UUID
    let image: UIImage
    var rotation: Int
    var rendering: Rendering
    /// Set when the page came from an item already in the library.
    var sourceItemID: UUID?

    init(
        id: UUID = UUID(),
        image: UIImage,
        rotation: Int = 0,
        rendering: Rendering = .original,
        sourceItemID: UUID? = nil
    ) {
        self.id = id
        self.image = image
        self.rotation = rotation
        self.rendering = rendering
        self.sourceItemID = sourceItemID
    }

    static func == (lhs: DocumentPage, rhs: DocumentPage) -> Bool {
        lhs.id == rhs.id && lhs.rotation == rhs.rotation && lhs.rendering == rhs.rendering
    }
}

enum DocumentBuilderError: LocalizedError {
    case noPages
    case renderFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noPages: L10n.text("문서로 만들 페이지가 없습니다.")
        case .renderFailed: L10n.text("문서를 만들 수 없습니다.")
        case .writeFailed: L10n.text("문서를 저장할 수 없습니다.")
        }
    }
}

struct BuiltDocument {
    let pdfRelativePath: String
    let thumbnailRelativePath: String?
    let pageCount: Int
    let recognizedText: String
}

enum DocumentBuilderService {
    static let directoryName = "Documents"

    /// Renders pages into a single PDF and runs text recognition over them.
    /// Everything here is local: PDFKit/CoreGraphics for the file, Vision for the
    /// text. No network, no third-party SDK.
    static func build(
        pages: [DocumentPage],
        title: String
    ) async throws -> BuiltDocument {
        guard !pages.isEmpty else { throw DocumentBuilderError.noPages }

        let prepared = pages.map { renderedImage(for: $0) }
        let data = try pdfData(from: prepared, title: title)

        let directory = MediaStorage.url(for: directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = availablePDFFileName(in: directory)
        let destination = directory.appending(path: fileName)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw DocumentBuilderError.writeFailed
        }

        let thumbnailPath = writeThumbnail(from: prepared.first, directory: directory)
        let text = await recognizedText(from: prepared)

        return BuiltDocument(
            pdfRelativePath: "\(directoryName)/\(fileName)",
            thumbnailRelativePath: thumbnailPath,
            pageCount: prepared.count,
            recognizedText: text
        )
    }

    static func defaultTitle(now: Date = .now) -> String {
        let date = L10n.date(now, dateStyle: .numeric, timeStyle: .omitted)
        return "\(date) \(CapturePurpose.document.title)"
    }

    static func availablePDFFileName(in directory: URL, now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"

        let baseName = "\(formatter.string(from: now)) \(L10n.text("pdf.default_filename"))"
        var fileName = "\(baseName).pdf"
        var copyNumber = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: fileName).path) {
            fileName = "\(baseName) \(copyNumber).pdf"
            copyNumber += 1
        }
        return fileName
    }

    static func remove(_ document: Document) {
        try? FileManager.default.removeItem(at: document.pdfURL)
        if let thumbnail = document.thumbnailURL {
            try? FileManager.default.removeItem(at: thumbnail)
        }
    }

    // MARK: - Rendering

    static func renderedImage(for page: DocumentPage) -> UIImage {
        var image = page.image
        if page.rotation % 360 != 0 { image = rotated(image, degrees: page.rotation) }
        switch page.rendering {
        case .original: return image
        case .color: return adjusted(image, saturation: 1.1, contrast: 1.2)
        case .monochrome: return adjusted(image, saturation: 0, contrast: 1.45)
        }
    }

    private static func rotated(_ image: UIImage, degrees: Int) -> UIImage {
        let radians = CGFloat(degrees) * .pi / 180
        let size = abs(degrees % 180) == 90
            ? CGSize(width: image.size.height, height: image.size.width)
            : image.size
        return UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            context.cgContext.rotate(by: radians)
            image.draw(in: CGRect(
                x: -image.size.width / 2,
                y: -image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            ))
        }
    }

    private static func adjusted(_ image: UIImage, saturation: Double, contrast: Double) -> UIImage {
        guard let input = CIImage(image: image) else { return image }
        let output = input.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: saturation,
            kCIInputContrastKey: contrast
        ])
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return image }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }

    // MARK: - PDF

    static func pdfData(from images: [UIImage], title: String) throws -> Data {
        guard !images.isEmpty else { throw DocumentBuilderError.noPages }
        let metadata: [AnyHashable: Any] = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "SubGallery"
        ]
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw DocumentBuilderError.renderFailed }

        // Each page takes the size of its own image so nothing is letterboxed or
        // cropped to a fixed paper size.
        var mediaBox = CGRect(origin: .zero, size: images[0].size)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata as CFDictionary) else {
            throw DocumentBuilderError.renderFailed
        }
        for image in images {
            guard let cgImage = image.cgImage else { continue }
            var pageBox = CGRect(origin: .zero, size: image.size)
            let pageInfo: [String: Any] = [
                kCGPDFContextMediaBox as String: NSData(
                    bytes: &pageBox,
                    length: MemoryLayout<CGRect>.size
                )
            ]
            context.beginPDFPage(pageInfo as CFDictionary)
            context.draw(cgImage, in: pageBox)
            context.endPDFPage()
        }
        context.closePDF()

        guard data.length > 0 else { throw DocumentBuilderError.renderFailed }
        return data as Data
    }

    private static func writeThumbnail(from image: UIImage?, directory: URL) -> String? {
        guard let image else { return nil }
        let target = CGSize(width: 240, height: 240 * image.size.height / max(image.size.width, 1))
        let thumbnail = UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = thumbnail.jpegData(compressionQuality: 0.8) else { return nil }
        let name = "\(UUID().uuidString)-thumb.jpg"
        do {
            try data.write(to: directory.appending(path: name), options: .atomic)
            return "\(directoryName)/\(name)"
        } catch {
            return nil
        }
    }

    // MARK: - OCR

    /// Reuses the same Vision text recognition the rest of the app relies on, so a
    /// document is searchable by its contents exactly like a photo is.
    private static func recognizedText(from images: [UIImage]) async -> String {
        var pages: [String] = []
        for image in images {
            guard let cgImage = image.cgImage else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ko-KR", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            guard (try? handler.perform([request])) != nil else { continue }
            let lines = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !lines.isEmpty { pages.append(lines.joined(separator: "\n")) }
        }
        return pages.joined(separator: "\n\n")
    }
}
