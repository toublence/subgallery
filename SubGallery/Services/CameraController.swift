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

    var onPhoto: ((Data) -> Void)?
    var onVideo: ((URL) -> Void)?

    private let queue = DispatchQueue(label: "com.namslab.subgallery.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var currentInput: AVCaptureDeviceInput?
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
                    DispatchQueue.main.async { self.selectedLensID = device.uniqueID }
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
                device.videoZoomFactor = min(max(1, device.videoZoomFactor * factor), device.activeFormat.videoMaxZoomFactor)
                device.unlockForConfiguration()
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
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
            let lenses = discovery.devices
            guard let device = lenses.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? lenses.first,
                  let input = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            if self.session.canAddInput(input) { self.session.addInput(input); self.currentInput = input }
            if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
            if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async {
                self.availableLenses = lenses
                self.selectedLensID = device.uniqueID
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
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
            movieOutput.startRecording(to: url, recordingDelegate: self)
            isRecording = true
            recordingDuration = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.recordingDuration += 1 }
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
