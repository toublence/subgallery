import AVFoundation
import CoreLocation
import SwiftData
import SwiftUI

struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var media: [MediaItem]
    let onOpenLibrary: (AlbumDestination) -> Void
    @StateObject private var camera = CameraController()
    @StateObject private var locationProvider = CaptureLocationProvider()
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
    @AppStorage("camera.saveLocation") private var savesLocation = false

    private var destination: StorageDestination {
        StorageDestination(token: destinationAlbumID)
    }

    private var destinationAlbum: Album? {
        guard case .album(let id) = destination else { return nil }
        return albums.first { $0.id == id }
    }

    private var destinationName: String {
        if let destinationAlbum { return destinationAlbum.name }
        return destination == .temporary ? L10n.text("임시 보관") : L10n.text("카메라")
    }

    private var libraryThumbnail: MediaItem? {
        lastCapture ?? media.first {
            guard $0.deletedAt == nil else { return false }
            if let destinationAlbum { return $0.albumID == destinationAlbum.id }
            if destination == .temporary { return $0.expirationDate != nil || $0.waitingForCompletion }
            return $0.source == .camera
        }
    }

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
            if let destinationAlbum {
                retention = destinationAlbum.defaultRetention
            } else if destination == .temporary {
                retention = .sevenDays
            } else {
                retention = RetentionPolicy(rawValue: defaultRetentionRaw) ?? .forever
            }
            aspectRatio = lastAspectRatio
            camera.mode = MediaKind(rawValue: lastMode) ?? .photo
            camera.flashMode = lastFlash ? .on : .off
            camera.preferredLensID = lastLensID.isEmpty ? nil : lastLensID
            camera.preferredZoomFactor = CGFloat(lastZoom)
            loadedDefaults = true
        }
        camera.onPhoto = storePhoto
        camera.onVideo = storeVideo
        if savesLocation { locationProvider.requestCurrentLocation() }
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
                    .disabled(camera.isRecording)
                Spacer()
                destinationMenu.disabled(camera.isRecording)
                if camera.mode == .photo {
                    Menu {
                        ForEach(["4:3", "1:1", "16:9"], id: \.self) { ratio in Button(ratio) { aspectRatio = ratio } }
                    } label: { Text(aspectRatio).font(.subheadline.weight(.semibold)) }
                } else {
                    videoFormatMenu
                }
                Menu {
                    ForEach(RetentionPolicy.allCases.filter { $0 != .customDate }) { policy in
                        Button(policy.title) { retention = policy }
                    }
                } label: { Image(systemName: retention == .forever ? "infinity" : "clock") }
                .disabled(camera.isRecording)
                if camera.supportsFlash {
                    Button { camera.flashMode = camera.flashMode == .off ? .on : .off } label: {
                        Image(systemName: camera.flashMode == .off ? "bolt.slash.fill" : "bolt.fill")
                    }
                    .disabled(camera.isRecording)
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

            if camera.mode == .photo { photoAdjustments }

            Picker("촬영 모드", selection: $camera.mode) {
                Text("사진").tag(MediaKind.photo)
                Text("동영상").tag(MediaKind.video)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .disabled(camera.isRecording)

            HStack {
                Group {
                    if let libraryThumbnail {
                        Button { openInternalLibrary() } label: {
                            MediaThumbnail(item: libraryThumbnail).frame(width: 50, height: 50).clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .accessibilityLabel("SubGallery 보관함 열기")
                        .disabled(camera.isRecording)
                    } else {
                        Button { openInternalLibrary() } label: {
                            Image(systemName: "photo.on.rectangle.angled")
                                .frame(width: 50, height: 50)
                                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .accessibilityLabel("SubGallery 보관함 열기")
                        .disabled(camera.isRecording)
                    }
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
                if camera.supportsCameraSwitch {
                    Button { camera.switchCamera() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill").font(.title2)
                            .frame(width: 50, height: 50).background(.white.opacity(0.16), in: Circle())
                    }
                    .disabled(camera.isRecording)
                } else {
                    Color.clear.frame(width: 50, height: 50)
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
                destinationAlbumID = StorageDestination.camera.token
            } label: {
                Label("카메라", systemImage: destination == .camera ? "checkmark" : "camera")
            }
            Button {
                destinationAlbumID = StorageDestination.temporary.token
            } label: {
                Label("임시 보관", systemImage: destination == .temporary ? "checkmark" : "clock")
            }
            if !albums.isEmpty { Divider() }
            ForEach(albums) { album in
                Button {
                    destinationAlbumID = StorageDestination.album(album.id).token
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
                    .disabled(camera.isRecording)
            }
        }
    }

    private var photoAdjustments: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "plus.magnifyingglass")
                Slider(
                    value: Binding(get: { camera.zoomFactor }, set: camera.setZoom),
                    in: camera.minimumZoomFactor...max(camera.minimumZoomFactor, camera.maximumZoomFactor)
                )
                Text(String(format: "%.1f×", camera.zoomFactor)).monospacedDigit().frame(width: 42)
            }
            HStack(spacing: 10) {
                Image(systemName: "plusminus")
                Slider(
                    value: Binding(get: { Double(camera.exposureBias) }, set: { camera.setExposureBias(Float($0)) }),
                    in: Double(camera.minimumExposureBias)...Double(max(camera.minimumExposureBias, camera.maximumExposureBias))
                )
                Text(String(format: "%+.1f", camera.exposureBias)).monospacedDigit().frame(width: 42)
            }
        }
        .font(.caption)
        .padding(.horizontal, 34)
    }

    private var videoFormatMenu: some View {
        Menu {
            ForEach(camera.availableVideoOptions) { option in
                Button {
                    camera.selectVideoOption(option)
                } label: {
                    if option == camera.selectedVideoOption {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Text(camera.selectedVideoOption?.title ?? L10n.text("동영상 설정"))
                .font(.caption.weight(.semibold))
        }
        .disabled(camera.isRecording)
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
        if camera.mode == .video { return width * 16 / 9 }
        switch aspectRatio {
        case "1:1": return width
        case "16:9": return width * 16 / 9
        default: return width * 4 / 3
        }
    }

    private func lensLabel(_ device: AVCaptureDevice) -> String {
        guard let wide = camera.availableLenses.first(where: { $0.deviceType == .builtInWideAngleCamera }),
              device.activeFormat.videoFieldOfView > 0 else { return "1×" }
        let factor = Double(wide.activeFormat.videoFieldOfView / device.activeFormat.videoFieldOfView)
        let rounded = max(0.5, (factor * 2).rounded() / 2)
        return rounded == rounded.rounded()
            ? "\(Int(rounded))×"
            : String(format: "%.1f×", rounded)
    }

    private func storePhoto(_ data: Data) {
        Task {
            let output = croppedPhotoData(data) ?? data
            guard let stored = try? await MediaStorage.shared.store(data: output, type: .jpeg) else { return }
            await insert(stored)
        }
    }

    private func openInternalLibrary() {
        if let album = destinationAlbum {
            onOpenLibrary(.user(album.id, album.name))
        } else if destination == .temporary {
            onOpenLibrary(.smart(.temporary))
        } else {
            onOpenLibrary(.smart(.camera))
        }
    }

    private func croppedPhotoData(_ data: Data) -> Data? {
        guard aspectRatio != "4:3", let image = UIImage(data: data) else { return nil }
        let normalized = UIGraphicsImageRenderer(size: image.size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let cgImage = normalized.cgImage else { return nil }
        let targetRatio: CGFloat = aspectRatio == "1:1"
            ? 1
            : (normalized.size.width < normalized.size.height ? 9 / 16 : 16 / 9)
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let currentRatio = width / height
        let rect: CGRect
        if currentRatio > targetRatio {
            let croppedWidth = height * targetRatio
            rect = CGRect(x: (width - croppedWidth) / 2, y: 0, width: croppedWidth, height: height)
        } else {
            let croppedHeight = width / targetRatio
            rect = CGRect(x: 0, y: (height - croppedHeight) / 2, width: width, height: croppedHeight)
        }
        guard let cropped = cgImage.cropping(to: rect.integral) else { return nil }
        return UIImage(cgImage: cropped, scale: normalized.scale, orientation: .up).jpegData(compressionQuality: 0.94)
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
            createdAt: stored.capturedAt ?? .now,
            fileSize: stored.fileSize,
            width: stored.width, height: stored.height, duration: stored.duration
        )
        if savesLocation, let location = locationProvider.latestLocation {
            item.latitude = location.coordinate.latitude
            item.longitude = location.coordinate.longitude
        } else {
            item.latitude = stored.latitude
            item.longitude = stored.longitude
        }
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
        } else if destination == .temporary {
            retention = .sevenDays
        } else {
            destinationAlbumID = StorageDestination.camera.token
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

private final class CaptureLocationProvider: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var latestLocation: CLLocation?
    private let manager = CLLocationManager()
    private var requestsLocationAfterAuthorization = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestCurrentLocation() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .notDetermined:
            requestsLocationAfterAuthorization = true
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard requestsLocationAfterAuthorization,
              manager.authorizationStatus == .authorizedAlways
                || manager.authorizationStatus == .authorizedWhenInUse else { return }
        requestsLocationAfterAuthorization = false
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latestLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        requestsLocationAfterAuthorization = false
    }
}
