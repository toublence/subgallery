import AVFoundation
import AVKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum VideoEditingError: LocalizedError {
    case invalidRange
    case noVideoTrack
    case exportUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidRange: L10n.text("편집할 구간을 확인해 주세요.")
        case .noVideoTrack: L10n.text("동영상 트랙을 읽을 수 없습니다.")
        case .exportUnavailable: L10n.text("이 동영상을 편집할 수 없습니다.")
        }
    }
}

struct VideoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem
    let onSaved: (MediaItem) -> Void

    @State private var player: AVPlayer
    @State private var trimStart: Double
    @State private var trimEnd: Double
    @State private var removesAudio = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(item: MediaItem, onSaved: @escaping (MediaItem) -> Void) {
        self.item = item
        self.onSaved = onSaved
        let duration = max(item.duration, 0.1)
        _player = State(initialValue: AVPlayer(url: item.mediaURL))
        _trimStart = State(initialValue: 0)
        _trimEnd = State(initialValue: duration)
    }

    private var maximumDuration: Double { max(item.duration, 0.1) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label(L10n.text("구간 자르기"), systemImage: "timeline.selection")
                            .font(.headline)
                        Spacer()
                        Text("\(timeText(trimStart)) – \(timeText(trimEnd))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 8) {
                        HStack {
                            Text(L10n.text("시작"))
                            Slider(value: $trimStart, in: 0...maximumDuration, step: 0.1)
                                .onChange(of: trimStart) { _, value in
                                    trimStart = min(value, max(0, trimEnd - 0.1))
                                    seek(to: trimStart)
                                }
                        }
                        HStack {
                            Text(L10n.text("끝"))
                            Slider(value: $trimEnd, in: 0...maximumDuration, step: 0.1)
                                .onChange(of: trimEnd) { _, value in
                                    trimEnd = max(value, min(maximumDuration, trimStart + 0.1))
                                    seek(to: trimEnd)
                                }
                        }
                    }

                    Toggle(isOn: $removesAudio) {
                        Label(L10n.text("소리 제거"), systemImage: removesAudio ? "speaker.slash.fill" : "speaker.wave.2")
                    }

                    Button {
                        previewSelection()
                    } label: {
                        Label(L10n.text("선택 구간 미리보기"), systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Text(L10n.text("원본은 유지되고 편집본이 같은 앨범에 새로 저장됩니다."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.regularMaterial)
            }
            .navigationTitle(L10n.text("동영상 편집"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("취소")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("편집본 저장")) { saveCopy() }
                        .disabled(isSaving || trimEnd - trimStart < 0.1)
                }
            }
            .overlay { if isSaving { ProgressView("편집본 저장 중…").padding().background(.regularMaterial, in: .rect(cornerRadius: 14)) } }
        }
        .onDisappear { player.pause() }
        .alert(L10n.text("편집본을 저장할 수 없음"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.text("확인"), role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func seek(to seconds: Double) {
        player.pause()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func previewSelection() {
        player.pause()
        player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
        let previewDuration = trimEnd - trimStart
        Task {
            try? await Task.sleep(for: .seconds(previewDuration))
            await MainActor.run { player.pause() }
        }
    }

    private func timeText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func saveCopy() {
        let source = item.mediaURL
        let start = trimStart
        let end = trimEnd
        let shouldRemoveAudio = removesAudio
        isSaving = true

        Task {
            do {
                let stored = try await VideoEditingService.render(
                    source: source,
                    preferredName: item.fileName,
                    start: start,
                    end: end,
                    removesAudio: shouldRemoveAudio
                )
                await MainActor.run {
                    let copy = MediaItem(
                        kind: .video,
                        source: item.source,
                        localPath: stored.relativePath,
                        thumbnailPath: stored.thumbnailRelativePath,
                        fileName: stored.fileName,
                        createdAt: .now,
                        albumID: item.albumID,
                        expirationDate: item.expirationDate,
                        fileSize: stored.fileSize,
                        width: stored.width,
                        height: stored.height,
                        duration: stored.duration
                    )
                    copy.expirationTypeRaw = item.expirationTypeRaw
                    copy.waitingForCompletion = item.waitingForCompletion
                    copy.isPinned = item.isPinned
                    copy.note = item.note
                    copy.latitude = item.latitude
                    copy.longitude = item.longitude
                    modelContext.insert(copy)
                    try? modelContext.save()
                    onSaved(copy)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private enum VideoEditingService {
    static func render(
        source: URL,
        preferredName: String,
        start: Double,
        end: Double,
        removesAudio: Bool
    ) async throws -> StoredMedia {
        guard end > start else { throw VideoEditingError.invalidRange }
        let asset = AVURLAsset(url: source)
        let composition = AVMutableComposition()
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw VideoEditingError.noVideoTrack }
        for sourceTrack in videoTracks {
            guard let track = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try track.insertTimeRange(range, of: sourceTrack, at: .zero)
            track.preferredTransform = try await sourceTrack.load(.preferredTransform)
        }

        if !removesAudio {
            for sourceTrack in try await asset.loadTracks(withMediaType: .audio) {
                guard let track = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }
                try track.insertTimeRange(range, of: sourceTrack, at: .zero)
            }
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoEditingError.exportUnavailable
        }
        let baseName = URL(fileURLWithPath: preferredName).deletingPathExtension().lastPathComponent
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "\(baseName)-편집본-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        exporter.metadata = []
        try await exporter.export(to: temporaryURL, as: .mov)
        return try await MediaStorage.shared.store(fileAt: temporaryURL, type: .quickTimeMovie)
    }
}
