import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private let appGroupID = "group.com.namslab.subgallery"

private struct SharedAlbumOption: Codable, Identifiable {
    let id: UUID
    let name: String
}

private struct SharedInboxManifest: Codable {
    let fileName: String
    let originalName: String
    let destinationToken: String
    let retentionRaw: String
}

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareExtensionModel(extensionContext: extensionContext)
        let host = UIHostingController(rootView: ShareExtensionView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

@MainActor
private final class ShareExtensionModel: ObservableObject {
    @Published var destinationToken = "temporary"
    @Published var retentionRaw = "default"
    @Published var isSaving = false
    @Published var errorMessage: String?
    let albums: [SharedAlbumOption]
    private weak var extensionContext: NSExtensionContext?

    init(extensionContext: NSExtensionContext?) {
        self.extensionContext = extensionContext
        let defaults = UserDefaults(suiteName: appGroupID)
        if let data = defaults?.data(forKey: "shared.albums") {
            albums = (try? JSONDecoder().decode([SharedAlbumOption].self, from: data)) ?? []
        } else {
            albums = []
        }
    }

    func cancel() {
        extensionContext?.cancelRequest(withError: CancellationError())
    }

    func save() {
        guard !isSaving else { return }
        isSaving = true
        let context = extensionContext
        let destination = destinationToken
        let retention = retentionRaw
        Task {
            do {
                let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
                guard !providers.isEmpty else { throw ShareSaveError.noItems }
                for provider in providers {
                    let payload = try await SharedPayloadLoader.load(provider)
                    defer { try? FileManager.default.removeItem(at: payload.temporaryURL) }
                    try SharedPayloadLoader.enqueue(payload, destinationToken: destination, retentionRaw: retention)
                }
                context?.completeRequest(returningItems: nil)
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ShareExtensionView: View {
    @ObservedObject var model: ShareExtensionModel

    var body: some View {
        NavigationStack {
            Form {
                Section("저장 위치") {
                    Picker("저장 위치", selection: $model.destinationToken) {
                        Text("임시 보관").tag("temporary")
                        Text("기본 앨범").tag("default")
                        ForEach(model.albums) { album in
                            Text(album.name).tag("album:\(album.id.uuidString)")
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("보관") {
                    Picker("보관", selection: $model.retentionRaw) {
                        Text("기본값 사용").tag("default")
                        Text("완료할 때까지").tag("untilComplete")
                        Text("24시간").tag("oneDay")
                        Text("7일").tag("sevenDays")
                        Text("30일").tag("thirtyDays")
                        Text("계속 보관").tag("forever")
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    Text("SubGallery의 비공개 수신함에 저장되며 앱을 자동으로 열지 않습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("SubGallery에 저장")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { model.cancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { model.save() }.disabled(model.isSaving)
                }
            }
            .overlay { if model.isSaving { ProgressView("저장 중…").padding().background(.regularMaterial, in: .rect(cornerRadius: 14)) } }
            .alert("저장할 수 없음", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) { }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }
}

private struct SharedPayload {
    let temporaryURL: URL
    let originalName: String
}

private enum ShareSaveError: LocalizedError {
    case noItems
    case unsupported
    case unavailable

    var errorDescription: String? {
        switch self {
        case .noItems: "저장할 항목이 없습니다."
        case .unsupported: "이 형식은 아직 저장할 수 없습니다."
        case .unavailable: "공유된 항목을 읽을 수 없습니다."
        }
    }
}

private enum SharedPayloadLoader {
    static func load(_ provider: NSItemProvider) async throws -> SharedPayload {
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return try await copyFile(from: provider, typeIdentifier: UTType.movie.identifier, fallbackExtension: "mov")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return try await copyFile(from: provider, typeIdentifier: UTType.image.identifier, fallbackExtension: "jpg")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            let file = try await copyFile(from: provider, typeIdentifier: UTType.pdf.identifier, fallbackExtension: "pdf")
            defer { try? FileManager.default.removeItem(at: file.temporaryURL) }
            guard let document = PDFDocument(url: file.temporaryURL), let page = document.page(at: 0) else {
                throw ShareSaveError.unsupported
            }
            let image = page.thumbnail(of: CGSize(width: 1400, height: 1800), for: .mediaBox)
            return try imagePayload(image, originalName: file.originalName + ".jpg")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let item = try await loadItem(provider, typeIdentifier: UTType.url.identifier)
            if let url = item as? URL { return try cardPayload(title: "웹 링크", text: url.absoluteString) }
            if let value = item as? String { return try cardPayload(title: "웹 링크", text: value) }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let item = try await loadItem(provider, typeIdentifier: UTType.plainText.identifier)
            if let value = item as? String { return try cardPayload(title: "공유한 텍스트", text: value) }
        }
        throw ShareSaveError.unsupported
    }

    static func enqueue(_ payload: SharedPayload, destinationToken: String, retentionRaw: String) throws {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw ShareSaveError.unavailable
        }
        let inbox = container.appending(path: "ShareInbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let ext = payload.temporaryURL.pathExtension.isEmpty ? "jpg" : payload.temporaryURL.pathExtension
        let fileName = "\(id).\(ext)"
        let destination = inbox.appending(path: fileName)
        try FileManager.default.copyItem(at: payload.temporaryURL, to: destination)
        let manifest = SharedInboxManifest(
            fileName: fileName,
            originalName: payload.originalName,
            destinationToken: destinationToken,
            retentionRaw: retentionRaw
        )
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: inbox.appending(path: "\(id).json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func copyFile(
        from provider: NSItemProvider,
        typeIdentifier: String,
        fallbackExtension: String
    ) async throws -> SharedPayload {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw ShareSaveError.unavailable }
                    let ext = url.pathExtension.isEmpty ? fallbackExtension : url.pathExtension
                    let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: SharedPayload(temporaryURL: copy, originalName: url.lastPathComponent))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func loadItem(_ provider: NSItemProvider, typeIdentifier: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: ShareSaveError.unavailable) }
            }
        }
    }

    private static func cardPayload(title: String, text: String) throws -> SharedPayload {
        let size = CGSize(width: 1200, height: 900)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            NSString(string: title).draw(
                in: CGRect(x: 80, y: 90, width: 1040, height: 100),
                withAttributes: [.font: UIFont.systemFont(ofSize: 54, weight: .bold), .foregroundColor: UIColor.label]
            )
            NSString(string: text).draw(
                in: CGRect(x: 80, y: 220, width: 1040, height: 590),
                withAttributes: [.font: UIFont.systemFont(ofSize: 38), .foregroundColor: UIColor.label]
            )
        }
        return try imagePayload(image, originalName: "SubGallery-공유.jpg")
    }

    private static func imagePayload(_ image: UIImage, originalName: String) throws -> SharedPayload {
        guard let data = image.jpegData(compressionQuality: 0.94) else { throw ShareSaveError.unavailable }
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
        try data.write(to: url, options: .atomic)
        return SharedPayload(temporaryURL: url, originalName: originalName)
    }
}
