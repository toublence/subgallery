import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum SmartAlbum: String, Hashable {
    case all, camera, temporary, pinned, recentlyDeleted

    static let libraryCases: [SmartAlbum] = [.all, .camera, .temporary, .pinned]

    var title: String {
        switch self {
        case .all: L10n.text("전체")
        case .camera: L10n.text("카메라")
        case .temporary: L10n.text("임시 보관")
        case .pinned: L10n.text("고정")
        case .recentlyDeleted: L10n.text("최근 삭제")
        }
    }

    var symbol: String {
        switch self {
        case .all: "photo.on.rectangle.angled"
        case .camera: "camera.fill"
        case .temporary: "clock.fill"
        case .pinned: "pin.fill"
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
    @Binding var requestedDestination: AlbumDestination?
    @AppStorage("storage.defaultRetention") private var defaultRetentionRaw = RetentionPolicy.forever.rawValue
    @AppStorage("storage.defaultRetentionDate") private var defaultRetentionDate = 0.0
    @AppStorage("camera.destinationAlbumID") private var cameraDestinationAlbumID = ""

    @State private var newAlbumName = ""
    @State private var showsNewAlbum = false
    @State private var showsFileImporter = false
    @State private var photosSelection: [PhotosPickerItem] = []
    @State private var albumPhotosSelection: [PhotosPickerItem] = []
    @State private var albumForPhotoImport: Album?
    @State private var showsAlbumPhotoPicker = false
    @State private var showsSettings = false
    @State private var showsPremium = false
    @State private var importError: String?
    @State private var searchText = ""
    @State private var viewerItem: MediaItem?
    @State private var renamingAlbum: Album?
    @State private var renameAlbumText = ""
    @State private var coverAlbum: Album?
    @State private var retentionAlbum: Album?
    @State private var albumPendingDeletion: Album?
    @State private var navigationPath: [AlbumDestination] = []

    private let columns = [GridItem(.adaptive(minimum: 154, maximum: 260), spacing: 18)]

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                if searchText.isEmpty {
                    VStack(alignment: .leading, spacing: 28) {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(SmartAlbum.libraryCases, id: \.self) { smart in
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
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            Text("내 앨범")
                                .font(.title2.bold())

                            if albums.isEmpty {
                                Text("만든 앨범이 없습니다.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                LazyVGrid(columns: columns, spacing: 24) {
                                    ForEach(albums) { album in
                                        userAlbumTile(album)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 104)
                } else {
                    searchResultsView
                }
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
                        NavigationLink(value: AlbumDestination.smart(.recentlyDeleted)) {
                            Label("최근 삭제", systemImage: "trash")
                        }
                        Divider()
                        Button { showsPremium = true } label: { Label("Premium", systemImage: "sparkles") }
                        Button { showsSettings = true } label: { Label("설정", systemImage: "gearshape") }
                    } label: {
                        Label("더 보기", systemImage: "ellipsis")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { floatingControls }
            .navigationDestination(for: AlbumDestination.self) {
                AlbumView(destination: $0, isCameraPresented: $isCameraPresented)
            }
            .searchable(text: $searchText, prompt: "사진 속 글자, 파일 이름, 앨범")
            .onChange(of: requestedDestination) { _, destination in
                guard let destination else { return }
                navigationPath = [destination]
                requestedDestination = nil
            }
        }
        .alert("새 앨범", isPresented: $showsNewAlbum) {
            TextField("앨범 이름", text: $newAlbumName)
            Button("취소", role: .cancel) { newAlbumName = "" }
            Button("만들기") { createAlbum() }
                .disabled(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("가져올 수 없음", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("확인", role: .cancel) { }
        } message: { Text(importError ?? L10n.text("알 수 없는 오류")) }
        .alert("앨범 이름 변경", isPresented: Binding(
            get: { renamingAlbum != nil },
            set: { if !$0 { renamingAlbum = nil } }
        )) {
            TextField("앨범 이름", text: $renameAlbumText)
            Button("취소", role: .cancel) { renamingAlbum = nil }
            Button("저장") { renameSelectedAlbum() }
                .disabled(renameAlbumText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("앨범을 삭제할까요?", isPresented: Binding(
            get: { albumPendingDeletion != nil },
            set: { if !$0 { albumPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("앨범만 삭제", role: .destructive) { deleteSelectedAlbum() }
            Button("취소", role: .cancel) { albumPendingDeletion = nil }
        } message: {
            Text("사진은 삭제되지 않으며 전체에서 계속 확인할 수 있습니다.")
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
        .onChange(of: photosSelection) { _, selection in importPhotos(selection) }
        .onChange(of: albumPhotosSelection) { _, selection in importPhotos(selection, into: albumForPhotoImport) }
        .photosPicker(
            isPresented: $showsAlbumPhotoPicker,
            selection: $albumPhotosSelection,
            maxSelectionCount: 0,
            matching: .any(of: [.images, .videos])
        )
        .sheet(isPresented: $showsSettings) {
            SettingsView().presentationDetents([.large])
        }
        .sheet(isPresented: $showsPremium) {
            PremiumView().presentationDetents([.large])
        }
        .sheet(item: $coverAlbum) { album in
            AlbumCoverPickerView(album: album, items: media.filter { $0.albumID == album.id && $0.deletedAt == nil })
                .presentationDetents([.large])
        }
        .sheet(item: $retentionAlbum) { album in
            AlbumRetentionPickerView(album: album)
                .presentationDetents([.large])
        }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewer(items: searchResults, initialID: item.id, isRecentlyDeleted: false)
        }
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

    private func userAlbumTile(_ album: Album) -> some View {
        let albumMedia = media.filter { $0.albumID == album.id && $0.deletedAt == nil }
        let cover = album.coverMediaID.flatMap { coverID in albumMedia.first { $0.id == coverID } } ?? albumMedia.first
        return NavigationLink(value: AlbumDestination.user(album.id, album.name)) {
            AlbumTile(title: album.name, count: albumMedia.count, cover: cover, symbol: "rectangle.stack.fill")
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { beginRename(album) } label: { Label("이름 변경", systemImage: "pencil") }
            Button { beginPhotoImport(into: album) } label: { Label("사진 추가", systemImage: "photo.badge.plus") }
            Button { coverAlbum = album } label: { Label("대표 사진 변경", systemImage: "photo") }
                .disabled(albumMedia.isEmpty)
            Button { retentionAlbum = album } label: { Label("기본 보관 기간", systemImage: "clock") }
            Divider()
            Button(role: .destructive) { albumPendingDeletion = album } label: {
                Label("앨범 삭제", systemImage: "trash")
            }
        }
    }

    private var cleanupDetail: String? {
        let week = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        let count = media.filter {
            $0.deletedAt == nil && !$0.waitingForCompletion && ($0.expirationDate ?? .distantFuture) <= week
        }.count
        return count > 0 ? L10n.format("이번 주 %d개 정리 예정", count) : nil
    }

    private var searchResults: [MediaItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let matchingAlbumIDs = Set(albums.filter { $0.name.localizedCaseInsensitiveContains(query) }.map(\.id))
        let normalizedQuery = normalizedSearchText(query)
        return media.filter { item in
            guard item.deletedAt == nil else { return false }
            return item.fileName.localizedCaseInsensitiveContains(query)
                || item.localPath.localizedCaseInsensitiveContains(query)
                || item.recognizedText.localizedCaseInsensitiveContains(query)
                || item.note.localizedCaseInsensitiveContains(query)
                || (!normalizedQuery.isEmpty && normalizedSearchText(item.recognizedText).contains(normalizedQuery))
                || item.albumID.map(matchingAlbumIDs.contains) == true
        }
    }

    private func normalizedSearchText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private var searchResultsView: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 94, maximum: 180), spacing: 2)], spacing: 2) {
            ForEach(searchResults) { item in
                MediaGridCell(item: item, isSelected: false)
                    .onTapGesture { viewerItem = item }
            }
        }
        .overlay {
            if searchResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(minHeight: 420)
            }
        }
        .padding(.bottom, 104)
    }

    private func items(in smart: SmartAlbum) -> [MediaItem] {
        switch smart {
        case .all: media.filter { $0.deletedAt == nil }
        case .camera: media.filter { $0.deletedAt == nil && $0.source == .camera }
        case .temporary: media.filter { $0.deletedAt == nil && ($0.expirationDate != nil || $0.waitingForCompletion) }
        case .pinned: media.filter { $0.deletedAt == nil && $0.isPinned }
        case .recentlyDeleted: media.filter { $0.deletedAt != nil }
        }
    }

    private func createAlbum() {
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        modelContext.insert(Album(name: name, sortOrder: albums.count))
        newAlbumName = ""
    }

    private func beginRename(_ album: Album) {
        renameAlbumText = album.name
        renamingAlbum = album
    }

    private func renameSelectedAlbum() {
        guard let album = renamingAlbum else { return }
        album.name = renameAlbumText.trimmingCharacters(in: .whitespacesAndNewlines)
        try? modelContext.save()
        renamingAlbum = nil
    }

    private func beginPhotoImport(into album: Album) {
        albumForPhotoImport = album
        showsAlbumPhotoPicker = true
    }

    private func deleteSelectedAlbum() {
        guard let album = albumPendingDeletion else { return }
        media.filter { $0.albumID == album.id }.forEach { $0.albumID = nil }
        if cameraDestinationAlbumID == album.id.uuidString { cameraDestinationAlbumID = "" }
        modelContext.delete(album)
        try? modelContext.save()
        albumPendingDeletion = nil
    }

    private func importPhotos(_ selection: [PhotosPickerItem], into album: Album? = nil) {
        guard !selection.isEmpty else { return }
        Task {
            defer {
                if album == nil { photosSelection = [] } else { albumPhotosSelection = []; albumForPhotoImport = nil }
            }
            for item in selection {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    let stored = try await MediaStorage.shared.store(data: data, type: item.supportedContentTypes.first)
                    insert(stored, source: .photos, album: album)
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
    private func insert(_ stored: StoredMedia, source: MediaSource, album: Album? = nil) {
        let item = MediaItem(
            kind: stored.kind, source: source, localPath: stored.relativePath,
            thumbnailPath: stored.thumbnailRelativePath, fileName: stored.fileName, fileSize: stored.fileSize,
            width: stored.width, height: stored.height, duration: stored.duration
        )
        item.albumID = album?.id
        let policy = album?.defaultRetention ?? RetentionPolicy(rawValue: defaultRetentionRaw) ?? .forever
        let customDate = album?.defaultRetentionDate
            ?? (defaultRetentionDate > 0 ? Date(timeIntervalSince1970: defaultRetentionDate) : nil)
        RetentionService.apply(policy, customDate: customDate, to: item)
        modelContext.insert(item)
        try? modelContext.save()
        OCRService.enqueue(item, in: modelContext)
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
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let cover {
                        MediaThumbnail(item: cover)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        Image(systemName: symbol)
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(title).font(.headline).lineLimit(1)
            HStack {
                Text(L10n.format("%d개", count)).foregroundStyle(.secondary)
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

struct AlbumCoverPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let album: Album
    let items: [MediaItem]

    private let columns = [GridItem(.adaptive(minimum: 94, maximum: 180), spacing: 4)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(items) { item in
                        MediaGridCell(item: item, isSelected: album.coverMediaID == item.id)
                            .onTapGesture { select(item.id) }
                    }
                }
                .padding(20)
            }
            .navigationTitle("대표 사진 변경")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("최신 사진 자동 사용") { select(nil) } }
            }
        }
    }

    private func select(_ id: UUID?) {
        album.coverMediaID = id
        try? modelContext.save()
        dismiss()
    }
}

struct AlbumRetentionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let album: Album
    @State private var customDate: Date

    init(album: Album) {
        self.album = album
        _customDate = State(initialValue: album.defaultRetentionDate
            ?? Calendar.current.date(byAdding: .day, value: 1, to: .now)
            ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(RetentionPolicy.allCases.filter { $0 != .customDate }) { policy in
                        Button {
                            save(policy)
                        } label: {
                            HStack {
                                Text(policy.title).foregroundStyle(.primary)
                                Spacer()
                                if album.defaultRetention == policy {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section("날짜 지정") {
                    DatePicker("보관 기한", selection: $customDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    Button("이 날짜를 기본값으로 사용") { save(.customDate) }
                }
            }
            .navigationTitle("기본 보관 기간")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
        }
    }

    private func save(_ policy: RetentionPolicy) {
        album.defaultRetention = policy
        album.defaultRetentionDate = policy == .customDate ? customDate : nil
        try? modelContext.save()
        dismiss()
    }
}
