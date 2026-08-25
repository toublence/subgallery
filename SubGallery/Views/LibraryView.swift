import PhotosUI
import StoreKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum SmartAlbum: String, Hashable {
    case all, camera, temporary, pinned, unclassified, recentlyDeleted

    static let libraryCases: [SmartAlbum] = [.all, .pinned, .unclassified, .temporary]

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
    case template(CapturePurpose)
}

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.requestReview) private var requestReview
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    @Query(sort: \Document.createdAt, order: .reverse) private var documents: [Document]
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var media: [MediaItem]
    @Binding var isCameraPresented: Bool
    @Binding var captureContext: CaptureContext
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
    @StateObject private var purchases = PurchaseManager.shared

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
    @State private var documentToOpen: Document?
    @State private var viewerItem: MediaItem?
    @State private var renamingAlbum: Album?
    @State private var renameAlbumText = ""
    @State private var coverAlbum: Album?
    @State private var retentionAlbum: Album?
    @State private var rulesAlbum: Album?
    @State private var classificationItem: MediaItem?
    @State private var automaticClassificationNotice: SmartClassificationService.AutomaticClassificationNotice?
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
        let count = horizontalSizeClass == .compact ? 2 : 4
        let spacing: CGFloat = horizontalSizeClass == .compact ? 10 : 18
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    private var albumGridSpacing: CGFloat {
        horizontalSizeClass == .compact ? 16 : 24
    }

    private var userAlbums: [Album] {
        albums.filter { !$0.isBuiltIn }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                if searchText.isEmpty {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(L10n.text("보관함"))
                                .font(.title2.bold())

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
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            Text(L10n.text("내 앨범"))
                                .font(.title2.bold())

                            if userAlbums.isEmpty {
                                HStack(spacing: 12) {
                                    Image(systemName: "rectangle.stack")
                                        .foregroundStyle(.secondary)
                                    Text(L10n.text("만든 앨범이 없습니다."))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        showsNewAlbum = true
                                    } label: {
                                        Label(L10n.text("새 앨범"), systemImage: "plus")
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(14)
                                .background(
                                    Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                            } else {
                                LazyVGrid(columns: columns, spacing: albumGridSpacing) {
                                    ForEach(userAlbums) { album in
                                        userAlbumTile(album)
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            Text(L10n.text("템플릿"))
                                .font(.title2.bold())

                            LazyVGrid(columns: columns, spacing: albumGridSpacing) {
                                ForEach(CapturePresetService.templatePurposes) { purpose in
                                    templateTile(purpose)
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
                AlbumView(
                    destination: $0,
                    isCameraPresented: $isCameraPresented,
                    captureContext: $captureContext
                )
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
            .onAppear {
                restoreLastDestinationIfNeeded()
                requestReviewIfAppropriate()
            }
            .onReceive(NotificationCenter.default.publisher(for: .smartClassificationSuggested)) { notification in
                guard !isCameraPresented,
                      let id = notification.object as? UUID,
                      let item = media.first(where: { $0.id == id && $0.classificationStatus == .suggested }) else {
                    return
                }
                classificationItem = item
            }
            .onReceive(NotificationCenter.default.publisher(for: .automaticClassificationApplied)) { notification in
                guard !isCameraPresented,
                      let notice = notification.object as? SmartClassificationService.AutomaticClassificationNotice else {
                    return
                }
                showAutomaticClassificationNotice(notice)
            }
            .onChange(of: isCameraPresented) { _, isPresented in
                if !isPresented { requestReviewIfAppropriate() }
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = automaticClassificationNotice {
                AutomaticClassificationBanner(notice: notice) {
                    undoAutomaticClassification(notice)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 88)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
        .sheet(item: $documentToOpen) { document in
            PDFDocumentViewer(document: document)
        }
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
            AlbumAutomationView(album: album)
                .presentationDetents([.large])
        }
        .sheet(item: $classificationItem) { item in
            SmartClassificationSuggestionView(item: item)
                .presentationDetents([.medium, .large])
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
                captureContext = .general
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

    private func userAlbumTile(_ album: Album, symbol: String = "rectangle.stack.fill") -> some View {
        let albumMedia = media.filter { $0.albumID == album.id && $0.deletedAt == nil }
        let cover = album.coverMediaID.flatMap { coverID in albumMedia.first { $0.id == coverID } } ?? albumMedia.first
        return NavigationLink(value: AlbumDestination.user(album.id, album.displayName)) {
            AlbumTile(title: album.displayName, count: albumMedia.count, cover: cover, symbol: symbol)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { beginRename(album) } label: { Label(L10n.text("이름 변경"), systemImage: "pencil") }
            Button { beginPhotoImport(into: album) } label: { Label(L10n.text("사진 추가"), systemImage: "photo.badge.plus") }
            Button { coverAlbum = album } label: { Label(L10n.text("대표 사진 변경"), systemImage: "photo") }
                .disabled(albumMedia.isEmpty)
            Button { retentionAlbum = album } label: { Label(L10n.text("기본 보관 기간"), systemImage: "clock") }
            // No longer gated: the basic album rules are part of the free experience,
            // and only the advanced rows inside lead to the paywall.
            Button { rulesAlbum = album } label: {
                Label(L10n.text("앨범 자동화"), systemImage: "slider.horizontal.3")
            }
            Divider()
            Button(role: .destructive) { albumPendingDeletion = album } label: {
                Label(L10n.text("앨범 삭제"), systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func templateTile(_ purpose: CapturePurpose) -> some View {
        let templateMedia = media.filter {
            $0.deletedAt == nil && $0.templatePurpose == purpose
        }
        NavigationLink(value: AlbumDestination.template(purpose)) {
            AlbumTile(
                title: purpose.title,
                count: templateMedia.count,
                cover: templateMedia.first,
                symbol: templateSymbol(for: purpose),
                subtitle: templateFeature(for: purpose)
            )
        }
        .buttonStyle(.plain)
    }

    private func templateSymbol(for purpose: CapturePurpose) -> String {
        switch purpose {
        case .receipt: "receipt"
        case .travel: "airplane"
        case .document: "doc.text"
        case .qr: "qrcode"
        default: "folder"
        }
    }

    private func templateFeature(for purpose: CapturePurpose) -> String {
        switch purpose {
        case .receipt: L10n.text("지출 리포트")
        case .travel: L10n.text("사진 지도")
        case .document: L10n.text("OCR · PDF")
        case .qr: L10n.text("열기 · 복사")
        default: ""
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

    /// Built documents are searchable by their title and their recognised text, so a
    /// phrase inside a scanned contract finds the PDF and not only the source photo.
    private var documentSearchResults: [Document] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let normalizedQuery = normalizedSearchText(query)
        return documents.filter { document in
            document.searchText.localizedCaseInsensitiveContains(query)
                || (!normalizedQuery.isEmpty
                    && normalizedSearchText(document.searchText).contains(normalizedQuery))
        }
    }

    private func normalizedSearchText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private var searchResultsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !documentSearchResults.isEmpty {
                Text(L10n.text("만든 문서"))
                    .font(.headline)
                    .padding(.horizontal, 2)
                LazyVGrid(columns: TemplateGridLayout.columns, spacing: 12) {
                    ForEach(documentSearchResults) { document in
                        DocumentCard(document: document)
                            .contentShape(Rectangle())
                            .onTapGesture { documentToOpen = document }
                    }
                }
                .padding(.bottom, 8)
            }
            mediaSearchResults
        }
    }

    private var mediaSearchResults: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 94, maximum: 180), spacing: 2)], spacing: 2) {
            ForEach(searchResults) { item in
                MediaGridCell(item: item, isSelected: false)
                    .onTapGesture { viewerItem = item }
            }
        }
        .overlay {
            // Documents match separately, so "no results" only holds when neither
            // media nor documents matched.
            if searchResults.isEmpty && documentSearchResults.isEmpty {
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
        case .unclassified: media.filter { $0.deletedAt == nil && $0.isUnclassified }
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
        AlbumAutomationService.apply(
            targetAlbum,
            to: item,
            fallbackRetention: usesTemporaryDefault
                ? .sevenDays
                : RetentionPolicy(rawValue: defaultRetentionRaw) ?? .forever,
            fallbackRetentionDate: defaultRetentionDate > 0
                ? Date(timeIntervalSince1970: defaultRetentionDate)
                : nil
        )
        modelContext.insert(item)
        try? modelContext.save()
        ReviewPromptPolicy.recordSuccessfulSave()
        OCRService.enqueue(item, in: modelContext)
        requestReviewIfAppropriate()
    }

    private func requestReviewIfAppropriate() {
        guard ReviewPromptPolicy.shouldRequest else { return }
        ReviewPromptPolicy.markRequested()
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            requestReview()
        }
    }

    private func showAutomaticClassificationNotice(
        _ notice: SmartClassificationService.AutomaticClassificationNotice
    ) {
        withAnimation { automaticClassificationNotice = notice }
        Task {
            try? await Task.sleep(for: .seconds(6))
            guard automaticClassificationNotice?.id == notice.id else { return }
            withAnimation { automaticClassificationNotice = nil }
        }
    }

    private func undoAutomaticClassification(
        _ notice: SmartClassificationService.AutomaticClassificationNotice
    ) {
        _ = SmartClassificationService.undoAutomaticClassification(itemID: notice.itemID, in: modelContext)
        withAnimation { automaticClassificationNotice = nil }
    }
}

struct AutomaticClassificationBanner: View {
    let notice: SmartClassificationService.AutomaticClassificationNotice
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.purpose == .receipt ? "receipt.fill" : "qrcode")
                .foregroundStyle(Color.accentColor)
            Text(L10n.format("%@ 템플릿으로 자동 정리했어요", notice.purpose.title))
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(L10n.text("실행 취소"), action: undo)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
    }
}

private extension AlbumDestination {
    var persistenceToken: String {
        switch self {
        case .smart(let smart): "smart:\(smart.rawValue)"
        case .user(let id, _): "album:\(id.uuidString)"
        case .template(let purpose): "template:\(purpose.rawValue)"
        }
    }

    init?(persistenceToken: String, albums: [Album]) {
        if persistenceToken.hasPrefix("smart:"),
           let smart = SmartAlbum(rawValue: String(persistenceToken.dropFirst("smart:".count))) {
            self = .smart(smart)
            return
        }
        if persistenceToken.hasPrefix("template:"),
           let purpose = CapturePurpose(
               rawValue: String(persistenceToken.dropFirst("template:".count))
           ), purpose != .general, purpose != .custom {
            self = .template(purpose)
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

private enum CleanupCategory: String, CaseIterable, Identifiable {
    case today
    case soon
    case waiting
    case oldTemporary
    case recommendation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: L10n.text("오늘 만료")
        case .soon: L10n.text("곧 만료")
        case .waiting: L10n.text("완료 대기")
        case .oldTemporary: L10n.text("오래된 임시 사진")
        case .recommendation: L10n.text("정리 추천")
        }
    }
}

private struct CleanupSummary {
    let today: [MediaItem]
    let soon: [MediaItem]
    let waiting: [MediaItem]
    let oldTemporary: [MediaItem]
    let recommendations: [MediaItem]

    init(items: [MediaItem], now: Date = .now) {
        let active = items.filter { $0.deletedAt == nil }
        let startOfTomorrow = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: now)
        ) ?? now
        let endOfToday = startOfTomorrow.addingTimeInterval(-1)
        let week = Calendar.current.date(byAdding: .day, value: 7, to: endOfToday) ?? endOfToday
        let oldThreshold = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now

        today = active.filter {
            !$0.waitingForCompletion && ($0.expirationDate ?? .distantFuture) <= endOfToday
        }
        let usedToday = Set(today.map(\.id))
        soon = active.filter {
            !usedToday.contains($0.id)
                && !$0.waitingForCompletion
                && ($0.expirationDate ?? .distantFuture) <= week
        }
        let usedSoon = usedToday.union(soon.map(\.id))
        waiting = active.filter { !usedSoon.contains($0.id) && $0.waitingForCompletion }
        let usedWaiting = usedSoon.union(waiting.map(\.id))
        oldTemporary = active.filter {
            !usedWaiting.contains($0.id)
                && $0.importedAt <= oldThreshold
                && ($0.purpose == .temporary || $0.expirationDate != nil)
        }
        let usedOld = usedWaiting.union(oldTemporary.map(\.id))
        recommendations = active.filter {
            !usedOld.contains($0.id) && $0.classificationStatus == .suggested
        }
    }

    var totalCount: Int {
        today.count + soon.count + waiting.count + oldTemporary.count + recommendations.count
    }

    func items(for category: CleanupCategory) -> [MediaItem] {
        switch category {
        case .today: today
        case .soon: soon
        case .waiting: waiting
        case .oldTemporary: oldTemporary
        case .recommendation: recommendations
        }
    }
}

struct CleanupCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var media: [MediaItem]
    @StateObject private var purchases = PurchaseManager.shared
    @State private var selection = Set<UUID>()
    @State private var isSelecting = false
    @State private var viewerItem: MediaItem?
    @State private var classificationItem: MediaItem?
    @State private var pendingDelete = Set<UUID>()
    @State private var pendingComplete = Set<UUID>()
    @State private var showsPremium = false

    private var summary: CleanupSummary { CleanupSummary(items: media) }

    var body: some View {
        NavigationStack {
            Group {
                if purchases.isPremium { cleanupList }
                else { premiumRequired }
            }
            .navigationTitle(L10n.text("정리 센터"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("닫기")) { dismiss() }
                }
                if purchases.isPremium && summary.totalCount > 0 {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text(isSelecting ? "완료" : "선택")) {
                            isSelecting.toggle()
                            if !isSelecting { selection.removeAll() }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting && !selection.isEmpty { batchActions }
            }
        }
        .task { await purchases.prepare() }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewer(items: activeCleanupItems, initialID: item.id, isRecentlyDeleted: false)
        }
        .sheet(item: $classificationItem) { item in
            SmartClassificationSuggestionView(item: item)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsPremium) {
            PremiumView().presentationDetents([.large])
        }
        .confirmationDialog(L10n.text("선택한 사진을 완료 처리할까요?"), isPresented: Binding(
            get: { !pendingComplete.isEmpty },
            set: { if !$0 { pendingComplete.removeAll() } }
        ), titleVisibility: .visible) {
            Button(L10n.text("완료 처리")) { complete(pendingComplete) }
            Button(L10n.text("취소"), role: .cancel) { pendingComplete.removeAll() }
        }
        .confirmationDialog(L10n.text("선택한 사진을 최근 삭제로 이동할까요?"), isPresented: Binding(
            get: { !pendingDelete.isEmpty },
            set: { if !$0 { pendingDelete.removeAll() } }
        ), titleVisibility: .visible) {
            Button(L10n.text("삭제"), role: .destructive) { delete(pendingDelete) }
            Button(L10n.text("취소"), role: .cancel) { pendingDelete.removeAll() }
        } message: {
            Text(L10n.text("최근 삭제에서 7일 동안 복구할 수 있습니다."))
        }
    }

    private var cleanupList: some View {
        List {
            if summary.totalCount == 0 {
                ContentUnavailableView(
                    L10n.text("정리할 사진이 없습니다"),
                    systemImage: "checkmark.circle",
                    description: Text(L10n.text("지금은 확인이 필요한 사진이 없습니다."))
                )
            } else {
                ForEach(CleanupCategory.allCases) { category in
                    let items = summary.items(for: category)
                    if !items.isEmpty {
                        Section(category.title) {
                            ForEach(items) { item in cleanupRow(item, category: category) }
                        }
                    }
                }
            }
        }
    }

    private var premiumRequired: some View {
        ContentUnavailableView {
            Label(L10n.text("정리 센터는 Premium 기능입니다"), systemImage: "lock.fill")
        } description: {
            Text(L10n.text("만료 예정과 완료 대기 사진을 한곳에서 빠르게 정리합니다."))
        } actions: {
            Button(L10n.text("Premium 보기")) { showsPremium = true }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func cleanupRow(_ item: MediaItem, category: CleanupCategory) -> some View {
        Button {
            if isSelecting {
                if selection.contains(item.id) { selection.remove(item.id) }
                else { selection.insert(item.id) }
            } else {
                viewerItem = item
            }
        } label: {
            HStack(spacing: 12) {
                MediaThumbnail(item: item)
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.fileName).lineLimit(1).foregroundStyle(.primary)
                    Text(RetentionService.statusText(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelecting {
                    Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.contains(item.id) ? Color.accentColor : Color.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(L10n.text("계속 보관")) { keepForever([item.id]) }
                .tint(.blue)
            Button(L10n.text("7일 연장")) { extendSevenDays([item.id]) }
                .tint(.indigo)
            if category == .recommendation {
                Button(L10n.text("추천 보기")) { classificationItem = item }
                    .tint(.purple)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(L10n.text("삭제"), role: .destructive) { pendingDelete = [item.id] }
            if item.waitingForCompletion {
                Button(L10n.text("완료")) { pendingComplete = [item.id] }
                    .tint(.green)
            }
        }
    }

    private var batchActions: some View {
        HStack(spacing: 12) {
            Menu {
                Button(L10n.text("계속 보관")) { keepForever(selection) }
                Button(L10n.text("7일 연장")) { extendSevenDays(selection) }
                Button(L10n.text("완료 처리")) { pendingComplete = selection }
                Divider()
                Button(L10n.text("삭제"), role: .destructive) { pendingDelete = selection }
            } label: {
                Label(L10n.format("%d개 작업", selection.count), systemImage: "ellipsis.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var activeCleanupItems: [MediaItem] {
        CleanupCategory.allCases.flatMap { summary.items(for: $0) }
    }

    private func items(with ids: Set<UUID>) -> [MediaItem] {
        media.filter { ids.contains($0.id) && $0.deletedAt == nil }
    }

    private func keepForever(_ ids: Set<UUID>) {
        items(with: ids).forEach { RetentionService.apply(.forever, to: $0) }
        finishBatch()
    }

    private func extendSevenDays(_ ids: Set<UUID>) {
        items(with: ids).forEach { RetentionService.apply(.sevenDays, to: $0) }
        finishBatch()
    }

    private func complete(_ ids: Set<UUID>) {
        let targets = items(with: ids)
        pendingComplete.removeAll()
        Task {
            for item in targets { await MediaLifecycleService.complete(item) }
            finishBatch()
        }
    }

    private func delete(_ ids: Set<UUID>) {
        let targets = items(with: ids)
        pendingDelete.removeAll()
        Task {
            for item in targets { await MediaLifecycleService.moveToRecentlyDeleted(item) }
            finishBatch()
        }
    }

    private func finishBatch() {
        try? modelContext.save()
        selection.removeAll()
        isSelecting = false
    }
}

struct SmartClassificationSuggestionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    let item: MediaItem
    @State private var isChanging = false
    @State private var albumSelection: String
    @State private var retention: RetentionPolicy

    init(item: MediaItem) {
        self.item = item
        _albumSelection = State(initialValue: item.suggestedAlbumID?.uuidString ?? "suggested")
        _retention = State(initialValue: item.suggestedRetention ?? .forever)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor.opacity(0.1), in: Circle())

                VStack(spacing: 6) {
                    Text(L10n.format("%@으로 보입니다", suggestedPurpose.title))
                        .font(.title2.bold())
                    Text(L10n.text("사진을 이동하기 전에 추천 내용을 확인하세요."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if isChanging {
                    Form {
                        Picker(L10n.text("추천 앨범"), selection: $albumSelection) {
                            if item.suggestedAlbumID == nil {
                                Text(suggestedPurpose.title).tag("suggested")
                            }
                            Text(L10n.text("미분류")).tag("none")
                            ForEach(albums) { album in
                                Text(album.displayName).tag(album.id.uuidString)
                            }
                        }
                        Picker(L10n.text("보관 기간"), selection: $retention) {
                            ForEach(RetentionPolicy.allCases.filter { $0 != .customDate }) { policy in
                                Text(policy.title).tag(policy)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                } else {
                    VStack(spacing: 0) {
                        LabeledContent(L10n.text("추천 앨범"), value: recommendedAlbumName)
                        Divider().padding(.vertical, 12)
                        LabeledContent(L10n.text("보관 기간"), value: retention.title)
                    }
                    .padding(16)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                VStack(spacing: 10) {
                    Button(L10n.text("추천 적용")) { applySuggestion() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    Button(L10n.text(isChanging ? "추천대로 돌아가기" : "변경")) {
                        isChanging.toggle()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(L10n.text("스마트 자동 분류"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("추천 안 함")) {
                        SmartClassificationService.dismiss(item, in: modelContext)
                        dismiss()
                    }
                }
            }
        }
    }

    private var suggestedPurpose: CapturePurpose {
        item.suggestedPurpose ?? .custom
    }

    private var recommendedAlbumName: String {
        if let id = UUID(uuidString: albumSelection),
           let album = albums.first(where: { $0.id == id }) {
            return album.displayName
        }
        return albumSelection == "none" ? L10n.text("미분류") : suggestedPurpose.title
    }

    private func applySuggestion() {
        if let id = UUID(uuidString: albumSelection) {
            let album = albums.first { $0.id == id }
            SmartClassificationService.apply(item, album: album, retention: retention, in: modelContext)
        } else if albumSelection == "suggested" {
            SmartClassificationService.apply(item, album: nil, retention: retention, in: modelContext)
        } else {
            item.albumID = nil
            item.templatePurpose = nil
            RetentionService.apply(retention, to: item)
            SmartClassificationService.dismiss(item, in: modelContext)
        }
        dismiss()
    }
}

struct AlbumTile: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let title: String
    let count: Int
    let cover: MediaItem?
    let symbol: String
    var detail: String?
    var subtitle: String?

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
            if let subtitle {
                Text(subtitle)
                    .font(horizontalSizeClass == .compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                HStack {
                    Text(L10n.format("%d개", count)).foregroundStyle(.secondary)
                    if let detail { Text("· \(detail)").foregroundStyle(.orange).lineLimit(1) }
                }
                .font(horizontalSizeClass == .compact ? .caption : .subheadline)
            }
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
