import AVFoundation
import CoreLocation
import SwiftData
import SwiftUI

struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var media: [MediaItem]
    @Query(sort: \CapturePreset.sortOrder) private var presets: [CapturePreset]
    let onOpenLibrary: (AlbumDestination) -> Void
    @StateObject private var purchases = PurchaseManager.shared
    @StateObject private var camera = CameraController()
    @StateObject private var locationProvider = CaptureLocationProvider()
    @State private var aspectRatio = "4:3"
    @State private var retention: RetentionPolicy = .forever
    @State private var lastCapture: MediaItem?
    @State private var zoomStart: CGFloat = 1
    @State private var loadedDefaults = false
    @State private var showsAlbumCoachMark = false
    @State private var showsRetentionCoachMark = false
    @State private var classificationItem: MediaItem?
    @State private var automaticClassificationNotice: SmartClassificationService.AutomaticClassificationNotice?
    @AppStorage("storage.defaultRetention") private var defaultRetentionRaw = RetentionPolicy.forever.rawValue
    @AppStorage("storage.defaultRetentionDate") private var defaultRetentionDate = 0.0
    @AppStorage("camera.lastMode") private var lastMode = MediaKind.photo.rawValue
    @AppStorage("camera.lastAspectRatio") private var lastAspectRatio = "4:3"
    @AppStorage("camera.lastLensID") private var lastLensID = ""
    @AppStorage("camera.lastZoom") private var lastZoom = 1.0
    @AppStorage("camera.lastFlash") private var lastFlash = false
    @AppStorage("camera.destinationAlbumID") private var destinationAlbumID = ""
    @AppStorage("camera.saveLocation") private var savesLocation = false
    @AppStorage("camera.purposePresetID") private var purposePresetID = "general"
    @AppStorage("education.cameraAlbumCoachMarkSeen") private var albumCoachMarkSeen = false
    @AppStorage("education.retentionCoachMarkSeen") private var retentionCoachMarkSeen = false

    private var destination: StorageDestination {
        StorageDestination(token: destinationAlbumID)
    }

    private var destinationAlbum: Album? {
        guard case .album(let id) = destination else { return nil }
        return albums.first { $0.id == id }
    }

    private var destinationName: String {
        if let destinationAlbum { return destinationAlbum.displayName }
        return destination == .temporary ? L10n.text("임시 보관") : L10n.text("카메라")
    }

    private var selectedPreset: CapturePreset? {
        if let id = UUID(uuidString: purposePresetID), let preset = presets.first(where: { $0.id == id }) {
            return preset
        }
        return presets.first { $0.purpose == .general }
    }

    private var activePreset: CapturePreset? {
        guard let selectedPreset,
              CapturePresetService.canUse(selectedPreset, hasPremium: purchases.isPremium),
              selectedPreset.purpose != .general else { return nil }
        return selectedPreset
    }

    private var availablePresets: [CapturePreset] {
        presets.filter { CapturePresetService.canUse($0, hasPremium: purchases.isPremium) }
    }

    private var purposeName: String {
        activePreset?.displayName ?? destinationAlbum.map { $0.purpose == .custom ? L10n.text("일반") : $0.purpose.title }
            ?? L10n.text("일반")
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
            .overlay(alignment: .bottom) {
                if let notice = automaticClassificationNotice {
                    AutomaticClassificationBanner(notice: notice) {
                        undoAutomaticClassification(notice)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 112)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .alert(L10n.text("마이크 접근이 필요합니다."), isPresented: $camera.needsMicrophoneSettings) {
                Button(L10n.text("취소"), role: .cancel) { }
                Button(L10n.text("설정 열기"), action: openAppSettings)
            }
            .onReceive(NotificationCenter.default.publisher(for: .smartClassificationSuggested)) { notification in
                guard let id = notification.object as? UUID,
                      lastCapture?.id == id,
                      classificationItem == nil,
                      let item = media.first(where: { $0.id == id && $0.classificationStatus == .suggested }) else {
                    return
                }
                showsAlbumCoachMark = false
                showsRetentionCoachMark = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard lastCapture?.id == id,
                          item.classificationStatus == .suggested,
                          classificationItem == nil else { return }
                    classificationItem = item
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .automaticClassificationApplied)) { notification in
                guard let notice = notification.object as? SmartClassificationService.AutomaticClassificationNotice,
                      lastCapture?.id == notice.itemID else { return }
                showAutomaticClassificationNotice(notice)
            }
            .sheet(item: $classificationItem) { item in
                SmartClassificationSuggestionView(item: item)
                    .presentationDetents([.medium, .large])
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
            applyPurposeRules()
            loadedDefaults = true
        }
        camera.onPhoto = storePhoto
        camera.onVideo = storeVideo
        if StoreScreenshotMode.isEnabled { return }
        if shouldSaveLocation { locationProvider.requestCurrentLocation() }
        camera.requestAndStart()
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var preview: some View {
        GeometryReader { proxy in
            Group {
                if StoreScreenshotMode.isEnabled, let item = media.first {
                    MediaThumbnail(item: item)
                        .scaledToFill()
                } else {
                    CameraPreview(session: camera.session, onFocus: camera.focus)
                }
            }
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
                purposeMenu.disabled(camera.isRecording)
                if camera.mode == .photo {
                    Menu {
                        ForEach(["4:3", "1:1", "16:9"], id: \.self) { ratio in Button(ratio) { aspectRatio = ratio } }
                    } label: { Text(aspectRatio).font(.subheadline.weight(.semibold)) }
                } else {
                    videoFormatMenu
                }
                retentionMenu
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

            Picker(L10n.text("촬영 모드"), selection: $camera.mode) {
                Text(L10n.text("사진")).tag(MediaKind.photo)
                Text(L10n.text("동영상")).tag(MediaKind.video)
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
                        .accessibilityLabel(L10n.text("SubGallery 보관함 열기"))
                        .disabled(camera.isRecording)
                    } else {
                        Button { openInternalLibrary() } label: {
                            Image(systemName: "photo.on.rectangle.angled")
                                .frame(width: 50, height: 50)
                                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .accessibilityLabel(L10n.text("SubGallery 보관함 열기"))
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

    private var purposeMenu: some View {
        Menu {
            Section(L10n.text("촬영 목적")) {
                ForEach(availablePresets) { preset in
                    Button {
                        selectPreset(preset)
                    } label: {
                        Label(preset.displayName, systemImage: selectedPreset?.id == preset.id ? "checkmark" : purposeSymbol(preset.purpose))
                    }
                }
            }
            Divider()
            Menu(L10n.text("저장 위치")) {
                Button {
                    selectDestination(.camera)
                } label: {
                    Label(L10n.text("카메라"), systemImage: destination == .camera ? "checkmark" : "camera")
                }
                Button {
                    selectDestination(.temporary)
                } label: {
                    Label(L10n.text("임시 보관"), systemImage: destination == .temporary ? "checkmark" : "clock")
                }
                ForEach(albums) { album in
                    Button {
                        selectDestination(.album(album.id))
                    } label: {
                        Label(album.displayName, systemImage: destinationAlbum?.id == album.id ? "checkmark" : "rectangle.stack")
                    }
                }
            }
        } label: {
            Label(purposeName, systemImage: "scope")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .popover(isPresented: albumCoachMarkBinding, arrowEdge: .top) {
            CameraCoachMark(
                symbol: "rectangle.stack.fill",
                text: L10n.text("여기서 저장할 앨범을 바꿀 수 있어요."),
                dismiss: {
                    albumCoachMarkSeen = true
                    showsAlbumCoachMark = false
                }
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    private var retentionMenu: some View {
        Menu {
            ForEach(RetentionPolicy.allCases.filter { $0 != .customDate }) { policy in
                Button(policy.title) { retention = policy }
            }
        } label: {
            Image(systemName: retention == .forever ? "infinity" : "clock")
        }
        .disabled(camera.isRecording)
        .popover(isPresented: retentionCoachMarkBinding, arrowEdge: .top) {
            CameraCoachMark(
                symbol: "clock.badge.checkmark",
                text: L10n.text("앨범마다 보관 기간을 다르게 설정할 수 있어요."),
                dismiss: {
                    retentionCoachMarkSeen = true
                    showsRetentionCoachMark = false
                }
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    private var albumCoachMarkBinding: Binding<Bool> {
        Binding(
            get: { showsAlbumCoachMark },
            set: {
                showsAlbumCoachMark = $0
                if !$0 { albumCoachMarkSeen = true }
            }
        )
    }

    private var retentionCoachMarkBinding: Binding<Bool> {
        Binding(
            get: { showsRetentionCoachMark },
            set: {
                showsRetentionCoachMark = $0
                if !$0 { retentionCoachMarkSeen = true }
            }
        )
    }

    private func purposeSymbol(_ purpose: CapturePurpose) -> String {
        switch purpose {
        case .general: "camera"
        case .receipt: "receipt"
        case .parking: "car.fill"
        case .document: "doc.text"
        case .qr: "qrcode"
        case .temporary: "clock"
        case .travel: "airplane"
        case .custom: "scope"
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
            Label(L10n.text("카메라 접근 필요"), systemImage: "camera.fill")
        } description: {
            Text(L10n.text("촬영한 사진은 SubGallery 안에만 저장됩니다. 카메라 접근을 설정에서 허용해 주세요."))
        } actions: {
            Button(L10n.text("설정 열기")) {
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
            onOpenLibrary(.user(album.id, album.displayName))
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
        if shouldSaveLocation, let location = locationProvider.latestLocation {
            item.latitude = location.coordinate.latitude
            item.longitude = location.coordinate.longitude
        } else {
            item.latitude = stored.latitude
            item.longitude = stored.longitude
        }
        item.albumID = destinationAlbum?.id
        item.purpose = activePreset?.purpose ?? destinationAlbum?.purpose ?? .general
        item.analysisEnabled = activePreset?.ocrEnabled ?? destinationAlbum?.ocrEnabled ?? true
        item.primaryAction = activePreset?.primaryAction ?? destinationAlbum?.primaryAction ?? .automatic
        item.isPinned = activePreset?.autoPins ?? destinationAlbum?.autoPins ?? false
        let customDate = destinationAlbum?.defaultRetentionDate
            ?? (defaultRetentionDate > 0 ? Date(timeIntervalSince1970: defaultRetentionDate) : nil)
        RetentionService.apply(retention, customDate: customDate, to: item)
        modelContext.insert(item)
        try? modelContext.save()
        ReviewPromptPolicy.recordSuccessfulSave()
        OCRService.enqueue(item, in: modelContext)
        lastCapture = item
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if !albumCoachMarkSeen && !PremiumAccess.isActive {
            showsAlbumCoachMark = true
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

    private var shouldSaveLocation: Bool {
        activePreset?.savesLocation ?? destinationAlbum?.savesLocation ?? savesLocation
    }

    private func selectPreset(_ preset: CapturePreset) {
        guard CapturePresetService.canUse(preset, hasPremium: purchases.isPremium) else { return }
        purposePresetID = preset.id.uuidString
        if preset.purpose == .general {
            applyDestinationRetention()
        } else {
            if let albumID = preset.albumID {
                destinationAlbumID = StorageDestination.album(albumID).token
            }
            retention = preset.retention
        }
        if preset.savesLocation { locationProvider.requestCurrentLocation() }
    }

    private func selectDestination(_ destination: StorageDestination) {
        purposePresetID = "general"
        destinationAlbumID = destination.token
        applyDestinationRetention()
        if destinationAlbum?.savesLocation == true { locationProvider.requestCurrentLocation() }
        if albumCoachMarkSeen && !retentionCoachMarkSeen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                showsRetentionCoachMark = true
            }
        }
    }

    private func applyPurposeRules() {
        guard let selectedPreset,
              CapturePresetService.canUse(selectedPreset, hasPremium: purchases.isPremium) else {
            purposePresetID = "general"
            applyDestinationRetention()
            return
        }
        if selectedPreset.purpose == .general {
            applyDestinationRetention()
        } else {
            if let albumID = selectedPreset.albumID {
                destinationAlbumID = StorageDestination.album(albumID).token
            }
            retention = selectedPreset.retention
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
            if let activePreset {
                retention = activePreset.retention
            } else {
                applyDestinationRetention()
            }
        }
    }
}

private struct CameraCoachMark: View {
    let symbol: String
    let text: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(text, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("확인"), action: dismiss)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(.primary)
        .padding()
        .frame(width: 270)
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
