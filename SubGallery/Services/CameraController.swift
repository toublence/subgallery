@preconcurrency import AVFoundation
import SwiftUI
import UIKit

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
                let zoom = min(max(1, device.videoZoomFactor * factor), device.activeFormat.videoMaxZoomFactor)
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
            self.session.sessionPreset = .high
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
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        recordingDuration = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.recordingDuration += 1 }
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
