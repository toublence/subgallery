import AVKit
import Photos
import SwiftData
import SwiftUI

struct MediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let items: [MediaItem]
    let initialID: UUID
    let isRecentlyDeleted: Bool
    @State private var selectedID: UUID
    @State private var showsInfo = false
    @State private var showsDelete = false

    init(items: [MediaItem], initialID: UUID, isRecentlyDeleted: Bool) {
        self.items = items
        self.initialID = initialID
        self.isRecentlyDeleted = isRecentlyDeleted
        _selectedID = State(initialValue: initialID)
    }

    private var current: MediaItem? { items.first { $0.id == selectedID } }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedID) {
                ForEach(items) { item in
                    ViewerPage(item: item).tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(.black)
            .toolbarBackground(.black.opacity(0.55), for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("완료") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button { showsInfo = true } label: { Image(systemName: "info.circle") } }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let current {
                        ShareLink(item: MediaStorage.url(for: current.localPath)) { Image(systemName: "square.and.arrow.up") }
                        Spacer()
                        Button { current.favorite.toggle() } label: { Image(systemName: current.favorite ? "heart.fill" : "heart") }
                        Spacer()
                        Button(role: .destructive) { showsDelete = true } label: { Image(systemName: "trash") }
                    }
                }
            }
        }
        .statusBarHidden()
        .sheet(isPresented: $showsInfo) { if let current { MediaInfoView(item: current) } }
        .confirmationDialog("이 항목을 삭제할까요?", isPresented: $showsDelete) {
            Button(isRecentlyDeleted ? "영구 삭제" : "삭제", role: .destructive) { deleteCurrent() }
        }
    }

    private func deleteCurrent() {
        guard let current else { return }
        if isRecentlyDeleted {
            Task {
                try? await MediaStorage.shared.remove(current)
                await MainActor.run { modelContext.delete(current); dismiss() }
            }
        } else {
            current.deletedAt = .now
            dismiss()
        }
    }
}

private struct ViewerPage: View {
    let item: MediaItem
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        Group {
            if item.kind == .video {
                VideoPlayer(player: AVPlayer(url: MediaStorage.url(for: item.localPath)))
            } else if let image = UIImage(contentsOfFile: MediaStorage.url(for: item.localPath).path) {
                Image(uiImage: image)
                    .resizable().scaledToFit().scaleEffect(scale)
                    .gesture(MagnifyGesture().onChanged { value in scale = min(max(lastScale * value.magnification, 1), 6) }
                        .onEnded { _ in lastScale = scale })
                    .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2; lastScale = scale } }
            } else {
                ContentUnavailableView("파일을 열 수 없음", systemImage: "exclamationmark.triangle")
            }
        }
    }
}

struct MediaInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("촬영 날짜", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("가져온 날짜", value: item.importedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("크기", value: ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                LabeledContent("해상도", value: "\(item.width) × \(item.height)")
                LabeledContent("파일 형식", value: URL(fileURLWithPath: item.localPath).pathExtension.uppercased())
                if item.kind == .video { LabeledContent("길이", value: Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))) }
                if let expiration = item.expirationDate { LabeledContent("보관 기한", value: expiration.formatted(date: .abbreviated, time: .shortened)) }
            }
            .navigationTitle("정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
