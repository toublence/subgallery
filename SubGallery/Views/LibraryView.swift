import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum SmartAlbum: String, Hashable {
    case all, camera, temporary, pinned, unclassified, recentlyDeleted

    static let libraryCases: [SmartAlbum] = [.all, .camera, .temporary, .pinned, .unclassified]

    var title: String {
        switch self {
        case .all: L10n.text("전체")
        case .camera: L10n.text("카메라")
        case .temporary: L10n.text("임시 보관")
        case .pinned: L10n.text("고정")
        case .unclassified: L10n.text("미분류")
        case .recentlyDeleted: L10n.text("최근 삭제")
        }
    }

    var symbol: String {
        switch self {
        case .all: "photo.on.rectangle.angled"
        case .camera: "camera.fill"
        case .temporary: "clock.fill"
        case .pinned: "pin.fill"
        case .unclassified: "tray.full.fill"
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var media: [MediaItem]
    @Binding var isCameraPresented: Bool
    @Binding var requestedDestination: AlbumDestination?
    @Binding var requestedOnboardingAction: OnboardingAction?
    @AppStorage("storage.defaultRetention") private var defaultRetentionRaw = RetentionPolicy.forever.rawValue
    @AppStorage("storage.defaultRetentionDate") private var defaultRetentionDate = 0.0
    @AppStorage("camera.destinationAlbumID") private var cameraDestinationAlbumID = ""
    @AppStorage("defaults.cameraDestination") private var defaultCameraDestination = StorageDestination.camera.token
    @AppStorage("defaults.importDestination") private var defaultImportDestination = StorageDestination.all.token
    @AppStorage("defaults.shareDestination") private var defaultShareDestination = StorageDestination.temporary.token
    @AppStorage("camera.purposePresetID") private var cameraPurposePresetID = "general"
    @AppStorage("app.startScreen") private var appStartScreenRaw = AppStartScreen.library.rawValue
    @AppStorage("app.lastScreen") private var lastScreenRaw = AppStartScreen.library.rawValue
    @AppStorage("app.lastLibraryDestination") private var lastLibraryDestination = ""

    @State private var newAlbumName = ""
    @State private var showsNewAlbum = false
    @State private var showsFileImporter = false
    @State private var photosSelection: [PhotosPickerItem] = []
    @State private var albumPhotosSelection: [PhotosPickerItem] = []
    @State private var albumForPhotoImport: Album?
    @State private var showsAlbumPhotoPicker = false
    @State private var showsOnboardingPhotoPicker = false
    @State private var showsSettings = false
    @State private var showsPremium = false
    @State private var importError: String?
    @State private var searchText = StoreScreenshotMode.isEnabled && StoreScreenshotMode.screen == "search" ? StoreScreenshotMode.searchQuery : ""
    @State private var viewerItem: MediaItem?
    @State private var renamingAlbum: Album?
    @State private var renameAlbumText = ""
    @State private var coverAlbum: Album?
    @State private var retentionAlbum: Album?
    @State private var rulesAlbum: Album?
    @State private var albumPendingDeletion: Album?
    @State private var navigationPath: [AlbumDestination] = {
        guard StoreScreenshotMode.isEnabled else { return [] }
        switch StoreScreenshotMode.screen {
        case "retention": return [.smart(.temporary)]
        case "batch": return [.smart(.all)]
        default: return []
        }
    }()
    @State private var restoredLastDestination = false

    private var columns: [GridItem] {
        if horizontalSizeClass == .compact {
            return Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
        }
        return [GridItem(.adaptive(minimum: 154, maximum: 260), spacing: 18)]
    }

    private var albumGridSpacing: CGFloat {
        horizontalSizeClass == .compact ? 16 : 24
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                if searchText.isEmpty {
                    VStack(alignment: .leading, spacing: 28) {
                        LazyVGrid(columns: columns, spacing: albumGridSpacing) {
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
                            Text(L10n.text("내 앨범"))
                                .font(.title2.bold())

                            if albums.isEmpty {
                                Text(L10n.text("만든 앨범이 없습니다."))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                LazyVGrid(columns: columns, spacing: albumGridSpacing) {
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
                        description: Text(L10n.text("촬영하거나 가져온 사진은 기본 사진 앱과 섞이지 않고 이 앱에만 저장됩니다."))
                    )
                    .padding(.bottom, 70)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(L10n.text("보관함"))
                        .font(.headline.bold())
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                }
                ToolbarItem(placement: .principal) {
                    librarySearchBar
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showsNewAlbum = true } label: {
                        Label(L10n.text("새 앨범"), systemImage: "plus")
                    }
                    Menu {
                        NavigationLink(value: AlbumDestination.smart(.recentlyDeleted)) {
                            Label(L10n.text("최근 삭제"), systemImage: "trash")
                        }
                        Divider()
                        Button { showsPremium = true } label: { Label("Premium", systemImage: "sparkles") }
                        Button { showsSettings = true } label: { Label(L10n.text("설정"), systemImage: "gearshape") }
                    } label: {
                        Label(L10n.text("더 보기"), systemImage: "ellipsis")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { floatingControls }
            .navigationDestination(for: AlbumDestination.self) {
                AlbumView(destination: $0, isCameraPresented: $isCameraPresented)
            }
            .onChange(of: requestedDestination) { _, destination in
                guard let destination else { return }
                navigationPath = [destination]
                requestedDestination = nil
            }
            .onChange(of: requestedOnboardingAction) { _, action in
                guard action == .importPhotos else { return }
                showsOnboardingPhotoPicker = true
                requestedOnboardingAction = nil
            }
            .onChange(of: navigationPath) { _, path in
                guard restoredLastDestination else { return }
                lastScreenRaw = AppStartScreen.library.rawValue
                lastLibraryDestination = path.last?.persistenceToken ?? ""
            }
            .onChange(of: albums.map { "\($0.id.uuidString):\($0.name)" }) { _, _ in
                SharedInboxService.publishConfiguration(albums: albums)
                restoreLastDestinationIfNeeded()
            }
            .onAppear { restoreLastDestinationIfNeeded() }
        }
        .alert(L10n.text("새 앨범"), isPresented: $showsNewAlbum) {
            TextField(L10n.text("앨범 이름"), text: $newAlbumName)
            Button(L10n.text("취소"), role: .cancel) { newAlbumName = "" }
            Button(L10n.text("만들기")) { createAlbum() }
                .disabled(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(L10n.text("가져올 수 없음"), isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button(L10n.text("확인"), role: .cancel) { }
        } message: { Text(importError ?? L10n.text("알 수 없는 오류")) }
        .alert(L10n.text("앨범 이름 변경"), isPresented: Binding(
            get: { renamingAlbum != nil },
            set: { if !$0 { renamingAlbum = nil } }
        )) {
            TextField(L10n.text("앨범 이름"), text: $renameAlbumText)
            Button(L10n.text("취소"), role: .cancel) { renamingAlbum = nil }
            Button(L10n.text("저장")) { renameSelectedAlbum() }
                .disabled(renameAlbumText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(L10n.text("앨범을 삭제할까요?"), isPresented: Binding(
            get: { albumPendingDeletion != nil },
            set: { if !$0 { albumPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button(L10n.text("앨범만 삭제"), role: .destructive) { deleteSelectedAlbum() }
            Button(L10n.text("취소"), role: .cancel) { albumPendingDeletion = nil }
        } message: {
            Text(L10n.text("사진은 삭제되지 않으며 전체에서 계속 확인할 수 있습니다."))
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
        .photosPicker(
            isPresented: $showsOnboardingPhotoPicker,
            selection: $photosSelection,
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
        .sheet(item: $rulesAlbum) { album in
            AlbumRulesView(album: album)
                .presentationDetents([.large])
        }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewer(items: searchResults, initialID: item.id, isRecentlyDeleted: false)
        }
    }

    private var librarySearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(L10n.text("사진 속 글자, 파일 이름, 앨범"), text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("검색 지우기"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.22), lineWidth: 0.5))
        .frame(minWidth: 80, idealWidth: 340, maxWidth: 520)
        .layoutPriority(1)
    }

    private var floatingControls: some View {
        HStack(spacing: 8) {
            PhotosPicker(selection: $photosSelection, maxSelectionCount: 0, matching: .any(of: [.images, .videos])) {
                Label(L10n.text("사진 가져오기"), systemImage: "photo.badge.plus")
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .accessibilityHint(L10n.text("사진 앱에서 여러 항목을 선택합니다"))

            Menu {
                Button { showsFileImporter = true } label: { Label(L10n.text("파일 앱에서 가져오기"), systemImage: "folder") }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .padding(.vertical, 12).padding(.trailing, 12)
            }

            Divider().frame(height: 24)

            Button {
                cameraPurposePresetID = "general"
                cameraDestinationAlbumID = defaultCameraDestination
                isCameraPresented = true
            } label: {
                Label(L10n.text("카메라"), systemImage: "camera.fill")
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
        return NavigationLink(value: AlbumDestination.user(album.id, album.displayName)) {
            AlbumTile(title: album.displayName, count: albumMedia.count, cover: cover, symbol: "rectangle.stack.fill")
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { beginRename(album) } label: { Label(L10n.text("이름 변경"), systemImage: "pencil") }
            Button { beginPhotoImport(into: album) } label: { Label(L10n.text("사진 추가"), systemImage: "photo.badge.plus") }
            Button { coverAlbum = album } label: { Label(L10n.text("대표 사진 변경"), systemImage: "photo") }
                .disabled(albumMedia.isEmpty)
            Button { retentionAlbum = album } label: { Label(L10n.text("기본 보관 기간"), systemImage: "clock") }
            Button { rulesAlbum = album } label: { Label(L10n.text("앨범 규칙"), systemImage: "slider.horizontal.3") }
            Divider()
            Button(role: .destructive) { albumPendingDeletion = album } label: {
                Label(L10n.text("앨범 삭제"), systemImage: "trash")
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
                || item.analysisSearchText.localizedCaseInsensitiveContains(query)
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
        case .unclassified: media.filter { $0.deletedAt == nil && $0.albumID == nil }
        case .recentlyDeleted: media.filter { $0.deletedAt != nil }
        }
    }

    private func createAlbum() {
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        modelContext.insert(Album(name: name, sortOrder: albums.count))
        newAlbumName = ""
    }

    private func restoreLastDestinationIfNeeded() {
        guard !restoredLastDestination else { return }
        let startScreen = AppStartScreen(rawValue: appStartScreenRaw) ?? .library
        if startScreen == .library {
            lastScreenRaw = AppStartScreen.library.rawValue
        }
        guard startScreen == .last,
              lastScreenRaw == AppStartScreen.library.rawValue,
              !lastLibraryDestination.isEmpty else {
            restoredLastDestination = true
            return
        }
        guard let destination = AlbumDestination(
            persistenceToken: lastLibraryDestination,
            albums: albums
        ) else { return }
        navigationPath = [destination]
        restoredLastDestination = true
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
        let albumToken = StorageDestination.album(album.id).token
        if StorageDestination(token: cameraDestinationAlbumID) == .album(album.id) {
            cameraDestinationAlbumID = StorageDestination.camera.token
        }
        if defaultCameraDestination == albumToken { defaultCameraDestination = StorageDestination.camera.token }
        if defaultImportDestination == albumToken { defaultImportDestination = StorageDestination.all.token }
        if defaultShareDestination == albumToken { defaultShareDestination = StorageDestination.temporary.token }
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
        let importDestination = StorageDestination(token: defaultImportDestination)
        let defaultAlbum: Album? = {
            guard album == nil, case .album(let id) = importDestination else { return nil }
            return albums.first { $0.id == id }
        }()
        let targetAlbum = album ?? defaultAlbum
        let usesTemporaryDefault = album == nil && importDestination == .temporary
        let item = MediaItem(
            kind: stored.kind, source: source, localPath: stored.relativePath,
            thumbnailPath: stored.thumbnailRelativePath, fileName: stored.fileName,
            createdAt: stored.capturedAt ?? .now, fileSize: stored.fileSize,
            width: stored.width, height: stored.height, duration: stored.duration
        )
        item.latitude = stored.latitude
        item.longitude = stored.longitude
        item.albumID = targetAlbum?.id
        item.purpose = targetAlbum?.purpose ?? .general
        item.analysisEnabled = targetAlbum?.ocrEnabled ?? true
        item.primaryAction = targetAlbum?.primaryAction ?? .automatic
        item.isPinned = targetAlbum?.autoPins ?? false
        let policy = targetAlbum?.defaultRetention
            ?? (usesTemporaryDefault ? .sevenDays : RetentionPolicy(rawValue: defaultRetentionRaw) ?? .forever)
        let customDate = targetAlbum?.defaultRetentionDate
            ?? (defaultRetentionDate > 0 ? Date(timeIntervalSince1970: defaultRetentionDate) : nil)
        RetentionService.apply(policy, customDate: customDate, to: item)
        modelContext.insert(item)
        try? modelContext.save()
        OCRService.enqueue(item, in: modelContext)
    }
}

private extension AlbumDestination {
    var persistenceToken: String {
        switch self {
        case .smart(let smart): "smart:\(smart.rawValue)"
        case .user(let id, _): "album:\(id.uuidString)"
        }
    }

    init?(persistenceToken: String, albums: [Album]) {
        if persistenceToken.hasPrefix("smart:"),
           let smart = SmartAlbum(rawValue: String(persistenceToken.dropFirst("smart:".count))) {
            self = .smart(smart)
            return
        }
        let rawID = persistenceToken.hasPrefix("album:")
            ? String(persistenceToken.dropFirst("album:".count))
            : persistenceToken
        guard let id = UUID(uuidString: rawID),
              let album = albums.first(where: { $0.id == id }) else { return nil }
        self = .user(album.id, album.displayName)
    }
}

struct AlbumRulesView: View {
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
                Section(L10n.text("목적")) {
                    Picker(L10n.text("앨범 목적"), selection: Binding(
                        get: { album.purpose },
                        set: { album.purpose = $0 }
                    )) {
                        ForEach(CapturePurpose.allCases.filter {
                            $0 != .general && ($0 != .travel || album.purpose == .travel)
                        }) { purpose in
                            Text(purpose.title).tag(purpose)
                        }
                    }
                    Picker(L10n.text("대표 Action"), selection: Binding(
                        get: { album.primaryAction },
                        set: { album.primaryAction = $0 }
                    )) {
                        ForEach(PrimaryMediaAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                }

                Section(L10n.text("촬영 및 분석")) {
                    Toggle(L10n.text("텍스트·QR 분석"), isOn: Binding(get: { album.ocrEnabled }, set: { album.ocrEnabled = $0 }))
                    Toggle(L10n.text("촬영 위치 저장"), isOn: Binding(get: { album.savesLocation }, set: { album.savesLocation = $0 }))
                    Toggle(L10n.text("촬영 후 자동 고정"), isOn: Binding(get: { album.autoPins }, set: { album.autoPins = $0 }))
                }

                Section(L10n.text("기본 보관")) {
                    Picker(L10n.text("보관 기간"), selection: Binding(
                        get: { album.defaultRetention },
                        set: { policy in
                            album.defaultRetention = policy
                            album.defaultRetentionDate = policy == .customDate ? customDate : nil
                        }
                    )) {
                        ForEach(RetentionPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    if album.defaultRetention == .customDate {
                        DatePicker(L10n.text("날짜"), selection: $customDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                            .onChange(of: customDate) { _, date in album.defaultRetentionDate = date }
                    }
                }
            }
            .navigationTitle(L10n.text("앨범 규칙"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("완료")) { try? modelContext.save(); dismiss() }
                }
            }
        }
    }
}

struct AlbumTile: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
                            .font(horizontalSizeClass == .compact ? .title2 : .largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(title)
                .font(horizontalSizeClass == .compact ? .subheadline.bold() : .headline)
                .lineLimit(1)
            HStack {
                Text(L10n.format("%d개", count)).foregroundStyle(.secondary)
                if let detail { Text("· \(detail)").foregroundStyle(.orange).lineLimit(1) }
            }
            .font(horizontalSizeClass == .compact ? .caption : .subheadline)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct MediaThumbnail: View {
    let item: MediaItem

    var body: some View {
        Group {
            if let url = item.thumbnailURL, let image = UIImage(contentsOfFile: url.path) {
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
            .navigationTitle(L10n.text("대표 사진 변경"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("취소")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("최신 사진 자동 사용")) { select(nil) } }
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

                Section(L10n.text("날짜 지정")) {
                    DatePicker(L10n.text("보관 기한"), selection: $customDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    Button(L10n.text("이 날짜를 기본값으로 사용")) { save(.customDate) }
                }
            }
            .navigationTitle(L10n.text("기본 보관 기간"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("취소")) { dismiss() } } }
        }
    }

    private func save(_ policy: RetentionPolicy) {
        album.defaultRetention = policy
        album.defaultRetentionDate = policy == .customDate ? customDate : nil
        try? modelContext.save()
        dismiss()
    }
}
