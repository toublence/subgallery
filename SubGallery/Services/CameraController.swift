@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct CameraVideoOption: Identifiable, Hashable {
    let width: Int32
    let height: Int32
    let fps: Int

    var id: String { "\(width)x\(height)-\(fps)" }
    var resolutionTitle: String {
        if width >= 3_800 { return "4K" }
        return "\(height)p"
    }
    var title: String { "\(resolutionTitle) · \(fps) FPS" }
}

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var isConfigured = false
    @Published var isRecording = false
    @Published var mode: MediaKind = .photo
    @Published var availableLenses: [AVCaptureDevice] = []
    @Published var selectedLensID: String?
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published var recordingDuration: TimeInterval = 0
    @Published var zoomFactor: CGFloat = 1
    @Published var minimumZoomFactor: CGFloat = 1
    @Published var maximumZoomFactor: CGFloat = 1
    @Published var supportsFlash = false
    @Published var supportsCameraSwitch = false
    @Published var exposureBias: Float = 0
    @Published var minimumExposureBias: Float = 0
    @Published var maximumExposureBias: Float = 0
    @Published var availableVideoOptions: [CameraVideoOption] = []
    @Published var selectedVideoOption: CameraVideoOption?
    @Published var needsMicrophoneSettings = false

    var onPhoto: ((Data) -> Void)?
    var onVideo: ((URL) -> Void)?
    var preferredLensID: String?
    var preferredZoomFactor: CGFloat = 1

    private let queue = DispatchQueue(label: "com.namslab.subgallery.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var timer: Timer?

    func requestAndStart() {
        switch authorization {
        case .authorized: configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorization = granted ? .authorized : .denied
                    if granted { self?.configureAndStart() }
                }
            }
        default: break
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func capture() {
        mode == .photo ? capturePhoto() : toggleRecording()
    }

    func selectLens(_ device: AVCaptureDevice) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                if let currentInput = self.currentInput { self.session.removeInput(currentInput) }
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.currentInput = input
                    let zoom = min(max(1, self.preferredZoomFactor), device.activeFormat.videoMaxZoomFactor)
                    if (try? device.lockForConfiguration()) != nil {
                        device.videoZoomFactor = zoom
                        device.unlockForConfiguration()
                    }
                    DispatchQueue.main.async {
                        self.selectedLensID = device.uniqueID
                        self.zoomFactor = zoom
                    }
                    self.publishCapabilities(for: device)
                }
                self.session.commitConfiguration()
            } catch { self.session.commitConfiguration() }
        }
    }

    func switchCamera() {
        let target: AVCaptureDevice.Position = currentInput?.device.position == .front ? .back : .front
        let types: [AVCaptureDevice.DeviceType] = target == .front ? [.builtInWideAngleCamera] : [.builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: target)
        if let device = discovery.devices.first { selectLens(device) }
    }

    func setZoom(_ value: CGFloat) {
        guard let device = currentInput?.device else { return }
        queue.async {
            do {
                try device.lockForConfiguration()
                let zoom = min(max(device.minAvailableVideoZoomFactor, value), device.maxAvailableVideoZoomFactor)
                device.videoZoomFactor = zoom
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.preferredZoomFactor = zoom
                    self.zoomFactor = zoom
                }
            } catch { }
        }
    }

    func setExposureBias(_ value: Float) {
        guard let device = currentInput?.device else { return }
        queue.async {
            do {
                try device.lockForConfiguration()
                let bias = min(max(device.minExposureTargetBias, value), device.maxExposureTargetBias)
                device.setExposureTargetBias(bias, completionHandler: nil)
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.exposureBias = bias }
            } catch { }
        }
    }

    func selectVideoOption(_ option: CameraVideoOption) {
        guard let device = currentInput?.device else { return }
        queue.async {
            guard let format = device.formats.first(where: { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dimensions.width == option.width && dimensions.height == option.height
                    && format.videoSupportedFrameRateRanges.contains { range in
                        range.minFrameRate <= Double(option.fps) && range.maxFrameRate >= Double(option.fps)
                    }
            }) else { return }
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: CMTimeScale(option.fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.selectedVideoOption = option }
            } catch { }
        }
    }

    func focus(at devicePoint: CGPoint) {
        guard let device = currentInput?.device else { return }
        queue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func zoom(by factor: CGFloat) {
        guard let device = currentInput?.device else { return }
        queue.async {
            do {
                try device.lockForConfiguration()
                let zoom = min(max(device.minAvailableVideoZoomFactor, device.videoZoomFactor * factor), device.maxAvailableVideoZoomFactor)
                device.videoZoomFactor = zoom
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.preferredZoomFactor = zoom
                    self.zoomFactor = zoom
                }
            } catch { }
        }
    }

    private func configureAndStart() {
        queue.async { [weak self] in
            guard let self, !self.isConfigured else {
                if self?.session.isRunning == false { self?.session.startRunning() }
                return
            }
            let types: [AVCaptureDevice.DeviceType] = [
                .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera
            ]
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
            let devices = discovery.devices
            guard let device = self.preferredLensID.flatMap({ id in devices.first(where: { $0.uniqueID == id }) })
                    ?? devices.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera })
                    ?? devices.first,
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            let lenses = devices.filter { $0.position == device.position }

            self.session.beginConfiguration()
            self.session.sessionPreset = .inputPriority
            if self.session.canAddInput(input) { self.session.addInput(input); self.currentInput = input }
            if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
            if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
            let zoom = min(max(1, self.preferredZoomFactor), device.activeFormat.videoMaxZoomFactor)
            if (try? device.lockForConfiguration()) != nil {
                device.videoZoomFactor = zoom
                device.unlockForConfiguration()
            }
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async {
                self.availableLenses = lenses
                self.selectedLensID = device.uniqueID
                self.zoomFactor = zoom
                self.isConfigured = true
            }
            self.publishCapabilities(for: device, lenses: lenses)
        }
    }

    private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        if currentInput?.device.hasFlash == true { settings.flashMode = flashMode }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func toggleRecording() {
        if movieOutput.isRecording {
            movieOutput.stopRecording()
            setTorch(false)
            timer?.invalidate()
            timer = nil
            isRecording = false
        } else {
            requestMicrophoneAndStartRecording()
        }
    }

    private func requestMicrophoneAndStartRecording() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            addMicrophoneAndStartRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.addMicrophoneAndStartRecording()
                } else {
                    DispatchQueue.main.async { self.needsMicrophoneSettings = true }
                }
            }
        case .denied, .restricted:
            needsMicrophoneSettings = true
        @unknown default:
            needsMicrophoneSettings = true
        }
    }

    private func addMicrophoneAndStartRecording() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.audioInput == nil,
               let device = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: device) {
                self.session.beginConfiguration()
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.audioInput = input
                }
                self.session.commitConfiguration()
            }
            DispatchQueue.main.async { self.startRecording() }
        }
    }

    private func startRecording() {
        setTorch(flashMode == .on)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        recordingDuration = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.recordingDuration += 1 }
    }

    private func setTorch(_ enabled: Bool) {
        guard let device = currentInput?.device, device.hasTorch else { return }
        queue.async {
            do {
                try device.lockForConfiguration()
                device.torchMode = enabled ? .on : .off
                device.unlockForConfiguration()
            } catch { }
        }
    }

    private func publishCapabilities(for device: AVCaptureDevice, lenses: [AVCaptureDevice]? = nil) {
        let discoveredLenses = lenses ?? AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: device.position
        ).devices
        let options = videoOptions(for: device)
        let currentDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let durationSeconds = device.activeVideoMinFrameDuration.seconds
        let currentFPS = durationSeconds.isFinite && durationSeconds > 0 ? Int((1 / durationSeconds).rounded()) : 0
        DispatchQueue.main.async {
            self.availableLenses = discoveredLenses
            self.supportsFlash = device.hasFlash || device.hasTorch
            let oppositePosition: AVCaptureDevice.Position = device.position == .front ? .back : .front
            self.supportsCameraSwitch = !AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera],
                mediaType: .video,
                position: oppositePosition
            ).devices.isEmpty
            self.minimumZoomFactor = device.minAvailableVideoZoomFactor
            self.maximumZoomFactor = min(device.maxAvailableVideoZoomFactor, 10)
            self.exposureBias = device.exposureTargetBias
            self.minimumExposureBias = device.minExposureTargetBias
            self.maximumExposureBias = device.maxExposureTargetBias
            self.availableVideoOptions = options
            self.selectedVideoOption = options.first {
                $0.width == currentDimensions.width && $0.height == currentDimensions.height && $0.fps == currentFPS
            }
        }
    }

    private func videoOptions(for device: AVCaptureDevice) -> [CameraVideoOption] {
        var options = Set<CameraVideoOption>()
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width >= 1_280, dimensions.width <= 4_096 else { continue }
            let aspect = Double(dimensions.width) / Double(dimensions.height)
            guard abs(aspect - (16.0 / 9.0)) < 0.08 else { continue }
            for fps in [24, 30, 60] where format.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps)
            }) {
                options.insert(CameraVideoOption(width: dimensions.width, height: dimensions.height, fps: fps))
            }
        }
        return options.sorted {
            if $0.width == $1.width { return $0.fps < $1.fps }
            return $0.width < $1.width
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        DispatchQueue.main.async { self.onPhoto?(data) }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        guard error == nil else { return }
        DispatchQueue.main.async { self.onVideo?(outputFileURL) }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onFocus: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) { }
    func makeCoordinator() -> Coordinator { Coordinator(onFocus: onFocus) }

    final class Coordinator: NSObject {
        let onFocus: (CGPoint) -> Void
        weak var view: PreviewView?
        init(onFocus: @escaping (CGPoint) -> Void) { self.onFocus = onFocus }
        @objc func tapped(_ sender: UITapGestureRecognizer) {
            guard let view else { return }
            onFocus(view.previewLayer.captureDevicePointConverted(fromLayerPoint: sender.location(in: view)))
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
