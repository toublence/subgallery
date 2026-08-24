import AVKit
import SwiftUI

struct SlideshowView: View {
    @Environment(\.dismiss) private var dismiss
    let items: [MediaItem]

    @State private var currentIndex = 0
    @State private var isPlaying = true
    @State private var showsControls = true

    private var currentItem: MediaItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    private var playbackState: SlideshowPlaybackState {
        SlideshowPlaybackState(index: currentIndex, isPlaying: isPlaying)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let currentItem {
                SlideshowPage(item: currentItem, isPlaying: isPlaying)
                    .id(currentItem.id)
                    .transition(.opacity)
            } else {
                ContentUnavailableView("슬라이드쇼 항목 없음", systemImage: "photo")
                    .foregroundStyle(.white)
            }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { showsControls.toggle() } }
                .gesture(DragGesture(minimumDistance: 40).onEnded { value in
                    if value.translation.width < -40 { showNext() }
                    if value.translation.width > 40 { showPrevious() }
                })

            if showsControls { controls }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task(id: playbackState) {
            guard isPlaying, let currentItem else { return }
            let seconds = currentItem.kind == .video ? max(currentItem.duration, 2) : 4
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, isPlaying else { return }
            await MainActor.run { showNext() }
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                Text("\(min(currentIndex + 1, items.count)) / \(items.count)")
                    .font(.subheadline.monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(20)

            Spacer()

            HStack(spacing: 34) {
                Button(action: showPrevious) {
                    Image(systemName: "backward.fill")
                }
                Button { isPlaying.toggle() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 58, height: 58)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Button(action: showNext) {
                    Image(systemName: "forward.fill")
                }
            }
            .font(.title3)
            .padding(.horizontal, 30)
            .padding(.vertical, 16)
            .background(.black.opacity(0.35), in: Capsule())
            .padding(.bottom, 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .transition(.opacity)
    }

    private func showNext() {
        guard !items.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            currentIndex = (currentIndex + 1) % items.count
        }
    }

    private func showPrevious() {
        guard !items.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            currentIndex = (currentIndex - 1 + items.count) % items.count
        }
    }
}

private struct SlideshowPlaybackState: Hashable {
    let index: Int
    let isPlaying: Bool
}

private struct SlideshowPage: View {
    let item: MediaItem
    let isPlaying: Bool
    @State private var player: AVPlayer

    init(item: MediaItem, isPlaying: Bool) {
        self.item = item
        self.isPlaying = isPlaying
        _player = State(initialValue: AVPlayer(url: MediaStorage.url(for: item.localPath)))
    }

    var body: some View {
        Group {
            if item.kind == .video {
                VideoPlayer(player: player)
            } else if let image = UIImage(contentsOfFile: MediaStorage.url(for: item.localPath).path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ContentUnavailableView("사진을 열 수 없음", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.white)
            }
        }
        .onAppear { updatePlayback() }
        .onDisappear { player.pause() }
        .onChange(of: isPlaying) { _, _ in updatePlayback() }
    }

    private func updatePlayback() {
        guard item.kind == .video else { return }
        isPlaying ? player.play() : player.pause()
    }
}
