import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum SmartAlbum: String, Hashable, CaseIterable {
    case all, camera, temporary, recentlyDeleted

    var title: String {
        switch self {
        case .all: "전체"
        case .camera: "카메라"
        case .temporary: "임시 보관"
        case .recentlyDeleted: "최근 삭제"
        }
    }

    var symbol: String {
        switch self {
        case .all: "photo.on.rectangle.angled"
        case .camera: "camera.fill"
        case .temporary: "clock.fill"
        case .recentlyDeleted: "trash.fill"
        }
    }
}

enum AlbumDestination: Hashable {
    case smart(SmartAlbum)
    case user(UUID, String)
}

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var media: [MediaItem]
    @Binding var isCameraPresented: Bool

    @State private var newAlbumName = ""
    @State private var showsNewAlbum = false
    @State private var showsFileImporter = false
    @State private var photosSelection: [PhotosPickerItem] = []
    @State private var showsSettings = false
    @State private var showsPremium = false
    @State private var importError: String?

    private let columns = [GridItem(.adaptive(minimum: 154, maximum: 260), spacing: 18)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(SmartAlbum.allCases, id: \.self) { smart in
                        NavigationLink(value: AlbumDestination.smart(smart)) {
                            AlbumTile(
                                title: smart.title,
                                count: items(in: smart).count,
                                cover: items(in: smart).first,
                                symbol: smart.symbol,
                                detail: smart == .temporary ? cleanupDetail : nil
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(albums) { album in
                        NavigationLink(value: AlbumDestination.user(album.id, album.name)) {
                            let albumMedia = media.filter { $0.albumID == album.id && $0.deletedAt == nil }
                            AlbumTile(title: album.name, count: albumMedia.count, cover: albumMedia.first, symbol: "rectangle.stack.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 104)
            }
            .overlay {
                if media.isEmpty && albums.isEmpty {
                    ContentUnavailableView(
                        "나만의 보관함",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("촬영하거나 가져온 사진은 기본 사진 앱과 섞이지 않고 이 앱에만 저장됩니다.")
                    )
                    .padding(.bottom, 70)
                }
            }
            .navigationTitle("보관함")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showsNewAlbum = true } label: {
                        Label("새 앨범", systemImage: "plus")
                    }
                    Menu {
                        Button { showsPremium = true } label: { Label("Premium", systemImage: "sparkles") }
                        Button { showsSettings = true } label: { Label("맞춤 설정", systemImage: "slider.horizontal.3") }
                        Button { showsSettings = true } label: { Label("설정", systemImage: "gearshape") }
                    } label: {
                        Label("더 보기", systemImage: "ellipsis")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { floatingControls }
            .navigationDestination(for: AlbumDestination.self) { AlbumView(destination: $0) }
        }
        .alert("새 앨범", isPresented: $showsNewAlbum) {
            TextField("앨범 이름", text: $newAlbumName)
            Button("취소", role: .cancel) { newAlbumName = "" }
            Button("만들기") { createAlbum() }
                .disabled(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("가져올 수 없음", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("확인", role: .cancel) { }
        } message: { Text(importError ?? "알 수 없는 오류") }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
        .onChange(of: photosSelection) { _, selection in importPhotos(selection) }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .sheet(isPresented: $showsPremium) { PremiumView() }
    }

    private var floatingControls: some View {
        HStack(spacing: 8) {
            PhotosPicker(selection: $photosSelection, maxSelectionCount: 0, matching: .any(of: [.images, .videos])) {
                Label("사진 가져오기", systemImage: "photo.badge.plus")
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .accessibilityHint("사진 앱에서 여러 항목을 선택합니다")

            Menu {
                Button { showsFileImporter = true } label: { Label("파일 앱에서 가져오기", systemImage: "folder") }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .padding(.vertical, 12).padding(.trailing, 12)
            }

            Divider().frame(height: 24)

            Button { isCameraPresented = true } label: {
                Label("카메라", systemImage: "camera.fill")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .padding(.bottom, 8)
    }

    private var cleanupDetail: String? {
        let week = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        let count = media.filter { $0.deletedAt == nil && ($0.expirationDate ?? .distantFuture) <= week }.count
        return count > 0 ? "이번 주 \(count)개 정리 예정" : nil
    }

    private func items(in smart: SmartAlbum) -> [MediaItem] {
        switch smart {
        case .all: media.filter { $0.deletedAt == nil }
        case .camera: media.filter { $0.deletedAt == nil && $0.source == .camera }
        case .temporary: media.filter { $0.deletedAt == nil && $0.expirationDate != nil }
        case .recentlyDeleted: media.filter { $0.deletedAt != nil }
        }
    }

    private func createAlbum() {
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        modelContext.insert(Album(name: name, sortOrder: albums.count))
        newAlbumName = ""
    }

    private func importPhotos(_ selection: [PhotosPickerItem]) {
        guard !selection.isEmpty else { return }
        Task {
            defer { photosSelection = [] }
            for item in selection {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    let stored = try await MediaStorage.shared.store(data: data, type: item.supportedContentTypes.first)
                    insert(stored, source: .photos)
                } catch { importError = error.localizedDescription }
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        Task {
            do {
                for url in try result.get() {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let stored = try await MediaStorage.shared.store(fileAt: url)
                    insert(stored, source: .files)
                }
            } catch { importError = error.localizedDescription }
        }
    }

    @MainActor
    private func insert(_ stored: StoredMedia, source: MediaSource) {
        modelContext.insert(MediaItem(
            kind: stored.kind, source: source, localPath: stored.relativePath,
            thumbnailPath: stored.thumbnailRelativePath, fileSize: stored.fileSize,
            width: stored.width, height: stored.height, duration: stored.duration
        ))
    }
}

struct AlbumTile: View {
    let title: String
    let count: Int
    let cover: MediaItem?
    let symbol: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let cover { MediaThumbnail(item: cover) }
                else { Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary) }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(title).font(.headline).lineLimit(1)
            HStack {
                Text("\(count)개").foregroundStyle(.secondary)
                if let detail { Text("· \(detail)").foregroundStyle(.orange).lineLimit(1) }
            }
            .font(.subheadline)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct MediaThumbnail: View {
    let item: MediaItem

    var body: some View {
        Group {
            if let path = item.thumbnailPath, let image = UIImage(contentsOfFile: MediaStorage.url(for: path).path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.kind == .video ? "video.fill" : "photo.fill")
                    .resizable().scaledToFit().padding(28).foregroundStyle(.secondary)
            }
        }
    }
}
