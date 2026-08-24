import AVFoundation
import SwiftData
import SwiftUI

struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    @StateObject private var camera = CameraController()
    @State private var aspectRatio = "4:3"
    @State private var retention: RetentionPolicy = .forever
    @State private var lastCapture: MediaItem?
    @State private var zoomStart: CGFloat = 1
    @State private var loadedDefaults = false
    @AppStorage("storage.defaultRetention") private var defaultRetentionRaw = RetentionPolicy.forever.rawValue
    @AppStorage("storage.defaultRetentionDate") private var defaultRetentionDate = 0.0
    @AppStorage("camera.lastMode") private var lastMode = MediaKind.photo.rawValue
    @AppStorage("camera.lastAspectRatio") private var lastAspectRatio = "4:3"
    @AppStorage("camera.lastLensID") private var lastLensID = ""
    @AppStorage("camera.lastZoom") private var lastZoom = 1.0
    @AppStorage("camera.lastFlash") private var lastFlash = false
    @AppStorage("camera.destinationAlbumID") private var destinationAlbumID = ""

    private var destinationAlbum: Album? {
        guard let id = UUID(uuidString: destinationAlbumID) else { return nil }
        return albums.first { $0.id == id }
    }

    private var destinationName: String { destinationAlbum?.name ?? L10n.text("카메라") }

    var body: some View {
        cameraWithPersistence
            .alert("마이크 접근이 필요합니다.", isPresented: $camera.needsMicrophoneSettings) {
                Button("취소", role: .cancel) { }
                Button("설정 열기", action: openAppSettings)
            }
    }

    private var cameraWithPersistence: some View {
        cameraWithLifecycle
            .onChange(of: persistenceSnapshot) { previous, current in
                persistCameraState(previous, current)
            }
    }

    private var persistenceSnapshot: CameraPersistenceSnapshot {
        CameraPersistenceSnapshot(
            aspectRatio: aspectRatio,
            mode: camera.mode.rawValue,
            lensID: camera.selectedLensID ?? "",
            zoom: Double(camera.zoomFactor),
            flashEnabled: camera.flashMode == .on,
            destinationAlbumID: destinationAlbumID
        )
    }

    private var cameraWithLifecycle: some View {
        cameraContent
            .preferredColorScheme(.dark)
            .onAppear(perform: startCamera)
            .onDisappear { camera.stop() }
    }

    @ViewBuilder
    private var cameraContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.authorization == .denied || camera.authorization == .restricted {
                permissionView
            } else {
                preview
                controls
            }
        }
    }

    private func startCamera() {
        if !loadedDefaults {
            retention = destinationAlbum?.defaultRetention
                ?? RetentionPolicy(rawValue: defaultRetentionRaw)
                ?? .forever
            aspectRatio = lastAspectRatio
            camera.mode = MediaKind(rawValue: lastMode) ?? .photo
            camera.flashMode = lastFlash ? .on : .off
            camera.preferredLensID = lastLensID.isEmpty ? nil : lastLensID
            camera.preferredZoomFactor = CGFloat(lastZoom)
            loadedDefaults = true
        }
        camera.onPhoto = storePhoto
        camera.onVideo = storeVideo
        camera.requestAndStart()
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var preview: some View {
        GeometryReader { proxy in
            CameraPreview(session: camera.session, onFocus: camera.focus)
                .frame(width: proxy.size.width, height: previewHeight(in: proxy.size))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxHeight: .infinity)
                .gesture(MagnifyGesture()
                    .onChanged { value in
                        let delta = value.magnification / zoomStart
                        if abs(delta - 1) > 0.03 { camera.zoom(by: delta); zoomStart = value.magnification }
                    }
                    .onEnded { _ in zoomStart = 1 })
                .padding(.vertical, 92)
        }
        .ignoresSafeArea()
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                Spacer()
                destinationMenu
                Menu {
                    ForEach(["4:3", "1:1", "16:9"], id: \.self) { ratio in Button(ratio) { aspectRatio = ratio } }
                } label: { Text(aspectRatio).font(.subheadline.weight(.semibold)) }
                Menu {
                    ForEach(RetentionPolicy.allCases.filter { $0 != .customDate }) { policy in
                        Button(policy.title) { retention = policy }
                    }
                } label: { Image(systemName: retention == .forever ? "infinity" : "clock") }
                Button { camera.flashMode = camera.flashMode == .off ? .on : .off } label: {
                    Image(systemName: camera.flashMode == .off ? "bolt.slash.fill" : "bolt.fill")
                }
            }
            .font(.title3)
            .padding(.horizontal, 20).padding(.top, 8)

            Spacer()

            if camera.isRecording {
                Text(Duration.seconds(camera.recordingDuration).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit().font(.headline).padding(8).background(.black.opacity(0.45), in: Capsule())
            }

            lensPicker

            Picker("촬영 모드", selection: $camera.mode) {
                Text("사진").tag(MediaKind.photo)
                Text("동영상").tag(MediaKind.video)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            HStack {
                Group {
                    if let lastCapture {
                        Button { } label: {
                            MediaThumbnail(item: lastCapture).frame(width: 50, height: 50).clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    } else { Color.clear.frame(width: 50, height: 50) }
                }
                Spacer()
                Button { camera.capture() } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                        Circle().fill(camera.mode == .video ? .red : .white)
                            .frame(width: camera.isRecording ? 32 : 62, height: camera.isRecording ? 32 : 62)
                            .clipShape(camera.isRecording ? AnyShape(RoundedRectangle(cornerRadius: 7)) : AnyShape(Circle()))
                    }
                }
                .accessibilityLabel(L10n.text(camera.mode == .photo ? "사진 촬영" : camera.isRecording ? "녹화 중지" : "녹화 시작"))
                Spacer()
                Button { camera.switchCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill").font(.title2)
                        .frame(width: 50, height: 50).background(.white.opacity(0.16), in: Circle())
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var destinationMenu: some View {
        Menu {
            Button {
                destinationAlbumID = ""
            } label: {
                Label("카메라", systemImage: destinationAlbum == nil ? "checkmark" : "camera")
            }
            if !albums.isEmpty { Divider() }
            ForEach(albums) { album in
                Button {
                    destinationAlbumID = album.id.uuidString
                } label: {
                    Label(album.name, systemImage: destinationAlbum?.id == album.id ? "checkmark" : "rectangle.stack")
                }
            }
        } label: {
            Label(destinationName, systemImage: "folder")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
    }

    private var lensPicker: some View {
        HStack(spacing: 6) {
            ForEach(camera.availableLenses, id: \.uniqueID) { lens in
                Button(lensLabel(lens)) { camera.selectLens(lens) }
                    .font(.caption.weight(.bold))
                    .frame(minWidth: 38, minHeight: 38)
                    .background(camera.selectedLensID == lens.uniqueID ? .white : .black.opacity(0.5), in: Circle())
                    .foregroundStyle(camera.selectedLensID == lens.uniqueID ? .black : .white)
            }
        }
    }

    private var permissionView: some View {
        ContentUnavailableView {
            Label("카메라 접근 필요", systemImage: "camera.fill")
        } description: {
            Text("촬영한 사진은 SubGallery 안에만 저장됩니다. 카메라 접근을 설정에서 허용해 주세요.")
        } actions: {
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
    }

    private func previewHeight(in size: CGSize) -> CGFloat {
        let width = size.width
        switch aspectRatio {
        case "1:1": return width
        case "16:9": return width * 16 / 9
        default: return width * 4 / 3
        }
    }

    private func lensLabel(_ device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera: "0.5×"
        case .builtInTelephotoCamera: "\(Int(device.virtualDeviceSwitchOverVideoZoomFactors.last?.doubleValue ?? 3))×"
        default: "1×"
        }
    }

    private func storePhoto(_ data: Data) {
        Task {
            guard let stored = try? await MediaStorage.shared.store(data: data, type: .heic) else { return }
            await insert(stored)
        }
    }

    private func storeVideo(_ url: URL) {
        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let stored = try? await MediaStorage.shared.store(fileAt: url, type: .quickTimeMovie) else { return }
            await insert(stored)
        }
    }

    @MainActor
    private func insert(_ stored: StoredMedia) {
        let item = MediaItem(
            kind: stored.kind, source: .camera, localPath: stored.relativePath,
            thumbnailPath: stored.thumbnailRelativePath, fileName: stored.fileName,
            fileSize: stored.fileSize,
            width: stored.width, height: stored.height, duration: stored.duration
        )
        item.albumID = destinationAlbum?.id
        let customDate = destinationAlbum?.defaultRetentionDate
            ?? (defaultRetentionDate > 0 ? Date(timeIntervalSince1970: defaultRetentionDate) : nil)
        RetentionService.apply(retention, customDate: customDate, to: item)
        modelContext.insert(item)
        try? modelContext.save()
        OCRService.enqueue(item, in: modelContext)
        lastCapture = item
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func applyDestinationRetention() {
        if let album = destinationAlbum {
            retention = album.defaultRetention
        } else {
            destinationAlbumID = ""
            retention = RetentionPolicy(rawValue: defaultRetentionRaw) ?? .forever
        }
    }

    private func persistCameraState(
        _ previous: CameraPersistenceSnapshot,
        _ current: CameraPersistenceSnapshot
    ) {
        lastAspectRatio = current.aspectRatio
        lastMode = current.mode
        lastLensID = current.lensID
        lastZoom = current.zoom
        lastFlash = current.flashEnabled
        if previous.destinationAlbumID != current.destinationAlbumID {
            applyDestinationRetention()
        }
    }
}

private struct CameraPersistenceSnapshot: Equatable {
    let aspectRatio: String
    let mode: String
    let lensID: String
    let zoom: Double
    let flashEnabled: Bool
    let destinationAlbumID: String
}
