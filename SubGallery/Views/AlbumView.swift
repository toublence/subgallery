import AVKit
import Photos
import SwiftData
import SwiftUI

struct AlbumView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var allMedia: [MediaItem]
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    let destination: AlbumDestination

    @State private var selection = Set<UUID>()
    @State private var isSelecting = false
    @State private var viewerItem: MediaItem?
    @State private var showsMoveSheet = false
    @State private var deleteConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 94, maximum: 180), spacing: 2)]

    private var title: String {
        switch destination {
        case .smart(let smart): smart.title
        case .user(_, let name): name
        }
    }

    private var items: [MediaItem] {
        switch destination {
        case .smart(.all): allMedia.filter { $0.deletedAt == nil }
        case .smart(.camera): allMedia.filter { $0.deletedAt == nil && $0.source == .camera }
        case .smart(.temporary): allMedia.filter { $0.deletedAt == nil && $0.expirationDate != nil }
        case .smart(.recentlyDeleted): allMedia.filter { $0.deletedAt != nil }
        case .user(let id, _): allMedia.filter { $0.deletedAt == nil && $0.albumID == id }
        }
    }

    private var isRecentlyDeleted: Bool {
        if case .smart(.recentlyDeleted) = destination { return true }
        return false
    }

    var body: some View {
        ScrollView {
            if case .smart(.temporary) = destination { temporarySummary }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items) { item in
                    MediaGridCell(item: item, isSelected: selection.contains(item.id))
                        .onTapGesture {
                            if isSelecting { toggle(item.id) } else { viewerItem = item }
                        }
                        .contextMenu { contextMenu(for: item) }
                        .accessibilityAddTraits(selection.contains(item.id) ? .isSelected : [])
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("항목 없음", systemImage: "photo", description: Text("촬영하거나 미디어를 가져오면 여기에 표시됩니다."))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "완료" : "선택") {
                    withAnimation { isSelecting.toggle(); selection.removeAll() }
                }
                .disabled(items.isEmpty)
            }
            if isSelecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { showsMoveSheet = true } label: { Label("이동", systemImage: "folder") }
                        .disabled(selection.isEmpty || isRecentlyDeleted)
                    Spacer()
                    if isRecentlyDeleted {
                        Button("복구") { restoreSelected() }.disabled(selection.isEmpty)
                        Spacer()
                    }
                    Button(role: .destructive) { deleteConfirmation = true } label: { Label("삭제", systemImage: "trash") }
                        .disabled(selection.isEmpty)
                }
            }
        }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewer(items: items, initialID: item.id, isRecentlyDeleted: isRecentlyDeleted)
        }
        .sheet(isPresented: $showsMoveSheet) { albumPicker }
        .confirmationDialog(
            isRecentlyDeleted ? "선택한 항목을 영구 삭제할까요?" : "선택한 항목을 최근 삭제로 이동할까요?",
            isPresented: $deleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(isRecentlyDeleted ? "영구 삭제" : "삭제", role: .destructive) { deleteSelected() }
        }
    }

    private var temporarySummary: some View {
        let total = items.reduce(Int64(0)) { $0 + $1.fileSize }
        let week = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        let soon = items.filter { ($0.expirationDate ?? .distantFuture) <= week }.count
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(items.count)개 · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    .font(.headline)
                Text("이번 주 정리 예정 \(soon)개").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        if isRecentlyDeleted {
            Button { item.deletedAt = nil } label: { Label("복구", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { permanentlyDelete(item) } label: { Label("지금 삭제", systemImage: "trash") }
        } else {
            Button { item.favorite.toggle() } label: {
                Label(item.favorite ? "즐겨찾기 해제" : "즐겨찾기", systemImage: item.favorite ? "heart.slash" : "heart")
            }
            Menu("보관 기간") {
                ForEach(RetentionPolicy.allCases) { policy in
                    Button(policy.title) { item.expirationDate = policy.expiration() }
                }
            }
            ShareLink(item: MediaStorage.url(for: item.localPath)) { Label("공유", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { item.deletedAt = .now } label: { Label("삭제", systemImage: "trash") }
        }
    }

    private var albumPicker: some View {
        NavigationStack {
            List(albums) { album in
                Button(album.name) {
                    allMedia.filter { selection.contains($0.id) }.forEach { $0.albumID = album.id }
                    selection.removeAll(); showsMoveSheet = false
                }
            }
            .overlay { if albums.isEmpty { ContentUnavailableView("앨범 없음", systemImage: "rectangle.stack.badge.plus") } }
            .navigationTitle("앨범으로 이동")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { showsMoveSheet = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func restoreSelected() {
        allMedia.filter { selection.contains($0.id) }.forEach { $0.deletedAt = nil }
        selection.removeAll()
    }

    private func deleteSelected() {
        let selected = allMedia.filter { selection.contains($0.id) }
        if isRecentlyDeleted { selected.forEach(permanentlyDelete) }
        else { selected.forEach { $0.deletedAt = .now } }
        selection.removeAll()
    }

    private func permanentlyDelete(_ item: MediaItem) {
        Task {
            try? await MediaStorage.shared.remove(item)
            await MainActor.run { modelContext.delete(item) }
        }
    }
}

struct MediaGridCell: View {
    let item: MediaItem
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MediaThumbnail(item: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            if item.kind == .video {
                Label(duration, systemImage: "video.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(5).shadow(radius: 2)
            }
            if let expiration = item.expirationDate {
                Text(expiration.formatted(.relative(presentation: .named)))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(5).background(.black.opacity(0.45), in: Capsule()).padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, .blue).padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
    }

    private var duration: String {
        Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))
    }
}

