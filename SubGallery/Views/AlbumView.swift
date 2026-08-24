import AVKit
import Photos
import PhotosUI
import SwiftData
import SwiftUI

private struct TemporaryGroup: Identifiable {
    let title: String
    let items: [MediaItem]
    var id: String { title }
}

private enum AlbumGridMode: String, CaseIterable, Identifiable {
    case small, standard, large, original
    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: "작은 그리드"
        case .standard: "기본 그리드"
        case .large: "큰 그리드"
        case .original: "원본 비율"
        }
    }
}

private enum AlbumSortMode: String, CaseIterable, Identifiable {
    case newest, oldest, captured, imported, fileName
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: "최신순"
        case .oldest: "오래된순"
        case .captured: "촬영일순"
        case .imported: "가져온 날짜순"
        case .fileName: "파일 이름순"
        }
    }
}

private enum AlbumFilterMode: String, CaseIterable, Identifiable {
    case all, photo, video, pinned, temporary, waiting, dueToday
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "전체"
        case .photo: "사진"
        case .video: "동영상"
        case .pinned: "고정"
        case .temporary: "임시 보관"
        case .waiting: "완료 대기"
        case .dueToday: "오늘 정리 예정"
        }
    }
}

struct AlbumView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var allMedia: [MediaItem]
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    let destination: AlbumDestination
    @Binding var isCameraPresented: Bool
    @AppStorage("camera.destinationAlbumID") private var cameraDestinationAlbumID = ""

    @State private var selection = Set<UUID>()
    @State private var isSelecting = false
    @State private var viewerItem: MediaItem?
    @State private var showsMoveSheet = false
    @State private var showsRetentionSheet = false
    @State private var showsShareSheet = false
    @State private var showsFilesExporter = false
    @State private var deleteConfirmation = false
    @State private var photosSelection: [PhotosPickerItem] = []
    @State private var importError: String?
    @State private var bulkMessage: String?
    @State private var gridMode: AlbumGridMode
    @State private var sortMode: AlbumSortMode
    @State private var filterMode: AlbumFilterMode

    init(destination: AlbumDestination, isCameraPresented: Binding<Bool>) {
        self.destination = destination
        _isCameraPresented = isCameraPresented
        let key = destination.preferencesKey
        _gridMode = State(initialValue: AlbumGridMode(
            rawValue: UserDefaults.standard.string(forKey: "album.view.\(key)") ?? ""
        ) ?? .standard)
        _sortMode = State(initialValue: AlbumSortMode(
            rawValue: UserDefaults.standard.string(forKey: "album.sort.\(key)") ?? ""
        ) ?? .newest)
        _filterMode = State(initialValue: AlbumFilterMode(
            rawValue: UserDefaults.standard.string(forKey: "album.filter.\(key)") ?? ""
        ) ?? .all)
    }

    private var columns: [GridItem] {
        switch gridMode {
        case .small: [GridItem(.adaptive(minimum: 68, maximum: 104), spacing: 2)]
        case .standard: [GridItem(.adaptive(minimum: 94, maximum: 180), spacing: 4)]
        case .large: [GridItem(.adaptive(minimum: 160, maximum: 360), spacing: 8)]
        case .original: [GridItem(.adaptive(minimum: 150, maximum: 320), spacing: 6)]
        }
    }

    private var gridSpacing: CGFloat {
        switch gridMode {
        case .small: 2
        case .standard: 4
        case .large: 8
        case .original: 6
        }
    }

    private var title: String {
        switch destination {
        case .smart(let smart): smart.title
        case .user(let id, let name): albums.first { $0.id == id }?.name ?? name
        }
    }

    private var userAlbum: Album? {
        guard case .user(let id, _) = destination else { return nil }
        return albums.first { $0.id == id }
    }

    private var baseItems: [MediaItem] {
        switch destination {
        case .smart(.all): allMedia.filter { $0.deletedAt == nil }
        case .smart(.camera): allMedia.filter { $0.deletedAt == nil && $0.source == .camera }
        case .smart(.temporary): allMedia.filter { $0.deletedAt == nil && ($0.expirationDate != nil || $0.waitingForCompletion) }
        case .smart(.pinned): allMedia.filter { $0.deletedAt == nil && $0.isPinned }
        case .smart(.recentlyDeleted): allMedia.filter { $0.deletedAt != nil }
        case .user(let id, _): allMedia.filter { $0.deletedAt == nil && $0.albumID == id }
        }
    }

    private var items: [MediaItem] {
        let filtered = baseItems.filter(matchesFilter)
        return filtered.sorted(by: isOrderedBefore)
    }

    private var isRecentlyDeleted: Bool {
        if case .smart(.recentlyDeleted) = destination { return true }
        return false
    }

    private var selectedItems: [MediaItem] {
        items.filter { selection.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            if case .smart(.temporary) = destination { temporarySummary }
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                if case .smart(.temporary) = destination {
                    ForEach(temporaryGroups) { group in
                        Section {
                            ForEach(group.items) { item in mediaCell(item) }
                        } header: {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 12)
                        }
                    }
                } else {
                    ForEach(items) { item in mediaCell(item) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("항목 없음", systemImage: "photo", description: Text("촬영하거나 미디어를 가져오면 여기에 표시됩니다."))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let album = userAlbum, !isSelecting { albumCaptureControls(album) }
        }
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selection.count == items.count ? "전체 선택 해제" : "전체 선택") {
                        if selection.count == items.count {
                            selection.removeAll()
                        } else {
                            selection = Set(items.map(\.id))
                        }
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !isSelecting { displayOptionsMenu }
                Button(L10n.text(isSelecting ? "완료" : "선택")) {
                    setSelecting(!isSelecting)
                }
                .disabled(items.isEmpty)
            }
            if isSelecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    if isRecentlyDeleted {
                        Button("복구") { restoreSelected() }.disabled(selection.isEmpty)
                        Spacer()
                        Button(role: .destructive) { deleteConfirmation = true } label: { Label("삭제", systemImage: "trash") }
                            .disabled(selection.isEmpty)
                    } else {
                        Menu {
                            Button { saveSelectedToPhotos() } label: {
                                Label("사진 앱에 저장", systemImage: "photo.badge.arrow.down")
                            }
                            Button { showsFilesExporter = true } label: {
                                Label("파일 앱으로 내보내기", systemImage: "folder")
                            }
                            Button { showsShareSheet = true } label: {
                                Label("공유", systemImage: "square.and.arrow.up")
                            }
                            Divider()
                            Button { showsMoveSheet = true } label: {
                                Label("앨범으로 이동", systemImage: "rectangle.stack")
                            }
                            .disabled(albums.isEmpty)
                            Button { showsRetentionSheet = true } label: {
                                Label("보관 기간 변경", systemImage: "clock")
                            }
                            Button { togglePinnedSelected() } label: {
                                let removesPins = selectedItems.allSatisfy(\.isPinned)
                                Label(removesPins ? "고정 해제" : "고정", systemImage: removesPins ? "pin.slash" : "pin")
                            }
                            Button { completeSelected() } label: {
                                Label("완료 처리", systemImage: "checkmark.circle")
                            }
                            .disabled(!selectedItems.contains(where: \.waitingForCompletion))
                            Divider()
                            Button(role: .destructive) { deleteConfirmation = true } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        } label: {
                            Label(L10n.format("%d개 작업", selection.count), systemImage: "ellipsis.circle")
                        }
                        .disabled(selection.isEmpty)
                    }
                }
            }
        }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewer(items: items, initialID: item.id, isRecentlyDeleted: isRecentlyDeleted)
        }
        .sheet(isPresented: $showsMoveSheet) { albumPicker }
        .sheet(isPresented: $showsRetentionSheet) {
            BatchRetentionPickerView(items: selectedItems) {
                selection.removeAll()
                isSelecting = false
                showsRetentionSheet = false
            }
        }
        .sheet(isPresented: $showsShareSheet) {
            ActivityShareSheet(urls: selectedItems.map { MediaStorage.url(for: $0.localPath) })
        }
        .sheet(isPresented: $showsFilesExporter) {
            FilesExportPicker(urls: selectedItems.map { MediaStorage.url(for: $0.localPath) })
        }
        .onChange(of: photosSelection) { _, selection in importPhotos(selection, into: userAlbum) }
        .alert("가져올 수 없음", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("확인", role: .cancel) { }
        } message: { Text(importError ?? L10n.text("알 수 없는 오류")) }
        .alert("일괄 작업", isPresented: Binding(
            get: { bulkMessage != nil },
            set: { if !$0 { bulkMessage = nil } }
        )) {
            Button("확인", role: .cancel) { }
        } message: { Text(bulkMessage ?? "") }
        .confirmationDialog(
            isRecentlyDeleted ? "선택한 항목을 영구 삭제할까요?" : "선택한 항목을 최근 삭제로 이동할까요?",
            isPresented: $deleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text(isRecentlyDeleted ? "영구 삭제" : "삭제"), role: .destructive) { deleteSelected() }
        }
    }

    private func mediaCell(_ item: MediaItem) -> some View {
        Button {
            if isSelecting { toggle(item.id) } else { viewerItem = item }
        } label: {
            MediaGridCell(
                item: item,
                isSelected: selection.contains(item.id),
                usesOriginalAspect: gridMode == .original,
                showsSelectionControl: isSelecting
            )
        }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu { contextMenu(for: item) }
            .accessibilityAddTraits(selection.contains(item.id) ? .isSelected : [])
    }

    private var displayOptionsMenu: some View {
        Menu {
            Menu("보기") {
                ForEach(AlbumGridMode.allCases) { mode in
                    Button { setGridMode(mode) } label: {
                        Label(mode.title, systemImage: gridMode == mode ? "checkmark" : "square.grid.2x2")
                    }
                }
            }
            Menu("정렬") {
                ForEach(AlbumSortMode.allCases) { mode in
                    Button { setSortMode(mode) } label: {
                        Label(mode.title, systemImage: sortMode == mode ? "checkmark" : "arrow.up.arrow.down")
                    }
                }
            }
            Menu("필터") {
                ForEach(AlbumFilterMode.allCases) { mode in
                    Button { setFilterMode(mode) } label: {
                        Label(mode.title, systemImage: filterMode == mode ? "checkmark" : "line.3.horizontal.decrease")
                    }
                }
            }
            Divider()
            if let album = userAlbum {
                NavigationLink {
                    MediaMapView(albumID: album.id, albumName: album.name)
                } label: {
                    Label("지도", systemImage: "map")
                }
                .disabled(baseItems.isEmpty)
            }
            Button { setSelecting(true) } label: { Label("선택", systemImage: "checkmark.circle") }
        } label: {
            Label("보기 옵션", systemImage: "ellipsis.circle")
        }
    }

    private func albumCaptureControls(_ album: Album) -> some View {
        HStack(spacing: 8) {
            PhotosPicker(selection: $photosSelection, maxSelectionCount: 0, matching: .any(of: [.images, .videos])) {
                Label("사진 가져오기", systemImage: "photo.badge.plus")
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }

            Divider().frame(height: 24)

            Button {
                cameraDestinationAlbumID = StorageDestination.album(album.id).token
                isCameraPresented = true
            } label: {
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

    private var temporaryGroups: [TemporaryGroup] {
        let now = Date.now
        let endOfToday = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        let week = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        return [
            TemporaryGroup(title: L10n.text("완료 대기"), items: items.filter { $0.waitingForCompletion }),
            TemporaryGroup(title: L10n.text("오늘 정리 예정"), items: items.filter { !$0.waitingForCompletion && ($0.expirationDate ?? .distantFuture) <= endOfToday }),
            TemporaryGroup(title: L10n.text("7일 이내 정리"), items: items.filter { !$0.waitingForCompletion && ($0.expirationDate ?? .distantFuture) > endOfToday && ($0.expirationDate ?? .distantFuture) <= week }),
            TemporaryGroup(title: L10n.text("이후 정리"), items: items.filter { !$0.waitingForCompletion && ($0.expirationDate ?? .distantFuture) > week })
        ].filter { !$0.items.isEmpty }
    }

    private var temporarySummary: some View {
        let total = items.reduce(Int64(0)) { $0 + $1.fileSize }
        let week = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        let soon = items.filter { ($0.expirationDate ?? .distantFuture) <= week }.count
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format("%d개 · %@", items.count, ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))
                    .font(.headline)
                Text(L10n.format("이번 주 정리 예정 %d개", soon)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        if isRecentlyDeleted {
            Button { item.deletedAt = nil } label: { Label("복구", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { permanentlyDelete(item) } label: { Label("지금 삭제", systemImage: "trash") }
        } else {
            if item.waitingForCompletion {
                Button { Task { await MediaLifecycleService.complete(item) } } label: {
                    Label("완료", systemImage: "checkmark.circle")
                }
            }
            Button { togglePin(item) } label: {
                Label(L10n.text(item.isPinned ? "고정 해제" : "고정"), systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            Button { item.favorite.toggle() } label: {
                Label(item.favorite ? "즐겨찾기 해제" : "즐겨찾기", systemImage: item.favorite ? "heart.slash" : "heart")
            }
            Menu("보관 기간") {
                ForEach(RetentionPolicy.allCases.filter { $0 != .customDate }) { policy in
                    Button(policy.title) { RetentionService.apply(policy, to: item) }
                }
            }
            ShareLink(item: MediaStorage.url(for: item.localPath)) { Label("공유", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) {
                Task { await MediaLifecycleService.moveToRecentlyDeleted(item) }
            } label: { Label("삭제", systemImage: "trash") }
        }
    }

    private var albumPicker: some View {
        NavigationStack {
            List(albums) { album in
                Button(album.name) {
                    allMedia.filter { selection.contains($0.id) }.forEach { $0.albumID = album.id }
                    try? modelContext.save()
                    selection.removeAll(); isSelecting = false; showsMoveSheet = false
                }
            }
            .overlay { if albums.isEmpty { ContentUnavailableView("앨범 없음", systemImage: "rectangle.stack.badge.plus") } }
            .navigationTitle("앨범으로 이동")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { showsMoveSheet = false } } }
        }
        .presentationDetents([.large])
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func setSelecting(_ selecting: Bool) {
        withAnimation {
            isSelecting = selecting
            selection.removeAll()
        }
    }

    private func setGridMode(_ mode: AlbumGridMode) {
        gridMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "album.view.\(destination.preferencesKey)")
    }

    private func setSortMode(_ mode: AlbumSortMode) {
        sortMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "album.sort.\(destination.preferencesKey)")
    }

    private func setFilterMode(_ mode: AlbumFilterMode) {
        filterMode = mode
        selection.removeAll()
        UserDefaults.standard.set(mode.rawValue, forKey: "album.filter.\(destination.preferencesKey)")
    }

    private func matchesFilter(_ item: MediaItem) -> Bool {
        switch filterMode {
        case .all: true
        case .photo: item.kind == .photo
        case .video: item.kind == .video
        case .pinned: item.isPinned
        case .temporary: item.expirationDate != nil || item.waitingForCompletion
        case .waiting: item.waitingForCompletion
        case .dueToday:
            !item.waitingForCompletion && (item.expirationDate ?? .distantFuture) <= Calendar.current.endOfToday
        }
    }

    private func isOrderedBefore(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        switch sortMode {
        case .newest: max(lhs.createdAt, lhs.importedAt) > max(rhs.createdAt, rhs.importedAt)
        case .oldest: min(lhs.createdAt, lhs.importedAt) < min(rhs.createdAt, rhs.importedAt)
        case .captured: lhs.createdAt > rhs.createdAt
        case .imported: lhs.importedAt > rhs.importedAt
        case .fileName:
            lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
        }
    }

    private func togglePin(_ item: MediaItem) {
        item.isPinned.toggle()
        if !item.isPinned && RetentionService.shouldMoveToRecentlyDeleted(item) {
            Task { await MediaLifecycleService.moveToRecentlyDeleted(item) }
        }
        try? modelContext.save()
    }

    private func restoreSelected() {
        allMedia.filter { selection.contains($0.id) }.forEach(MediaLifecycleService.restore)
        selection.removeAll()
    }

    private func togglePinnedSelected() {
        let changing = selectedItems
        let shouldPin = !changing.allSatisfy(\.isPinned)
        changing.forEach { $0.isPinned = shouldPin }
        Task {
            if !shouldPin {
                for item in changing where RetentionService.shouldMoveToRecentlyDeleted(item) {
                    await MediaLifecycleService.moveToRecentlyDeleted(item)
                }
            }
            try? modelContext.save()
            selection.removeAll()
            isSelecting = false
        }
    }

    private func completeSelected() {
        let completing = selectedItems.filter(\.waitingForCompletion)
        Task {
            for item in completing {
                await MediaLifecycleService.complete(item)
            }
            try? modelContext.save()
            selection.removeAll()
            isSelecting = false
        }
    }

    private func saveSelectedToPhotos() {
        let exporting = selectedItems
        Task {
            do {
                try await MediaExportService.saveToPhotos(exporting)
                bulkMessage = L10n.format("%d개 항목을 Photos에 저장했습니다.", exporting.count)
                selection.removeAll()
                isSelecting = false
            } catch {
                bulkMessage = error.localizedDescription
            }
        }
    }

    private func deleteSelected() {
        let selected = allMedia.filter { selection.contains($0.id) }
        if isRecentlyDeleted { selected.forEach(permanentlyDelete) }
        else { selected.forEach { item in Task { await MediaLifecycleService.moveToRecentlyDeleted(item) } } }
        selection.removeAll()
    }

    private func permanentlyDelete(_ item: MediaItem) {
        Task {
            await MediaLifecycleService.permanentlyDelete(item, from: modelContext)
        }
    }

    private func importPhotos(_ selection: [PhotosPickerItem], into album: Album?) {
        guard !selection.isEmpty, let album else { return }
        Task {
            defer { photosSelection = [] }
            for selectionItem in selection {
                do {
                    guard let data = try await selectionItem.loadTransferable(type: Data.self) else { continue }
                    let stored = try await MediaStorage.shared.store(
                        data: data,
                        type: selectionItem.supportedContentTypes.first
                    )
                    insert(stored, into: album)
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func insert(_ stored: StoredMedia, into album: Album) {
        let item = MediaItem(
            kind: stored.kind, source: .photos, localPath: stored.relativePath,
            thumbnailPath: stored.thumbnailRelativePath, fileName: stored.fileName,
            createdAt: stored.capturedAt ?? .now, fileSize: stored.fileSize,
            width: stored.width, height: stored.height, duration: stored.duration
        )
        item.latitude = stored.latitude
        item.longitude = stored.longitude
        item.albumID = album.id
        RetentionService.apply(album.defaultRetention, customDate: album.defaultRetentionDate, to: item)
        modelContext.insert(item)
        try? modelContext.save()
        OCRService.enqueue(item, in: modelContext)
    }
}

struct BatchRetentionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let items: [MediaItem]
    let onDone: () -> Void
    @State private var customDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(RetentionPolicy.allCases.filter { $0 != .customDate }) { policy in
                        Button(policy.title) { apply(policy) }
                    }
                }
                Section("날짜 지정") {
                    DatePicker("보관 기한", selection: $customDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    Button("이 날짜까지 보관") { apply(.customDate) }
                }
            }
            .navigationTitle(L10n.format("%d개 보관 기간", items.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private func apply(_ policy: RetentionPolicy) {
        items.forEach { RetentionService.apply(policy, customDate: policy == .customDate ? customDate : nil, to: $0) }
        try? modelContext.save()
        onDone()
        dismiss()
    }
}

struct MediaGridCell: View {
    let item: MediaItem
    let isSelected: Bool
    var usesOriginalAspect = false
    var showsSelectionControl = false

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(cellAspectRatio, contentMode: .fit)
            .overlay { cellContent }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if showsSelectionControl && isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.blue.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.blue, lineWidth: 3)
                        }
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsSelectionControl {
                    selectionBadge.padding(7)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.fileName.isEmpty ? L10n.text("사진") : item.fileName)
            .accessibilityValue(item.waitingForCompletion || item.expirationDate != nil ? RetentionService.statusText(for: item) : "")
    }

    private var cellAspectRatio: CGFloat {
        guard usesOriginalAspect, item.width > 0, item.height > 0 else { return 1 }
        return min(max(CGFloat(item.width) / CGFloat(item.height), 0.45), 2.2)
    }

    private var selectionBadge: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.blue : Color.black.opacity(0.62))
            Circle()
                .stroke(.white, lineWidth: 2.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 28, height: 28)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .accessibilityLabel(isSelected ? "선택됨" : "선택 안 됨")
    }

    private var cellContent: some View {
        ZStack(alignment: .bottomTrailing) {
            MediaThumbnail(item: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            if item.kind == .video {
                Label(duration, systemImage: "video.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(5).shadow(radius: 2)
            }
            if item.waitingForCompletion || item.expirationDate != nil {
                Text(RetentionService.statusText(for: item))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(5).background(.black.opacity(0.45), in: Capsule()).padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if item.isPinned && !showsSelectionControl {
                Image(systemName: "pin.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(6).background(.black.opacity(0.4), in: Circle()).padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    private var duration: String {
        Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))
    }
}

private extension AlbumDestination {
    var preferencesKey: String {
        switch self {
        case .smart(let smart): "smart.\(smart.rawValue)"
        case .user(let id, _): "user.\(id.uuidString)"
        }
    }
}

private extension Calendar {
    var endOfToday: Date {
        date(bySettingHour: 23, minute: 59, second: 59, of: .now) ?? .now
    }
}
