import AVFoundation
import CoreLocation
import Photos
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("camera.defaultMode") private var defaultMode = "photo"
    @AppStorage("camera.aspectRatio") private var aspectRatio = "4:3"
    @AppStorage("camera.saveLocation") private var savesLocation = false
    @AppStorage("camera.rememberSettings") private var remembersSettings = true
    @AppStorage("storage.defaultRetention") private var defaultRetention = RetentionPolicy.forever.rawValue
    @AppStorage("privacy.biometricLock") private var biometricLock = false
    @AppStorage("privacy.stripMetadata") private var stripsMetadata = false
    @AppStorage("privacy.appSwitcherProtection") private var appSwitcherProtection = true
    @AppStorage("watermark.enabled") private var watermarkEnabled = false
    @AppStorage("icloud.sync") private var iCloudSync = false
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        NavigationStack {
            Form {
                Section("카메라") {
                    Picker("기본 모드", selection: $defaultMode) { Text("사진").tag("photo"); Text("동영상").tag("video") }
                    Picker("기본 화면비", selection: $aspectRatio) { Text("4:3").tag("4:3"); Text("1:1").tag("1:1"); Text("16:9").tag("16:9") }
                    Toggle("위치 저장", isOn: $savesLocation)
                    Toggle("마지막 설정 기억", isOn: $remembersSettings)
                }

                Section("저장") {
                    Picker("기본 보관 기간", selection: $defaultRetention) {
                        ForEach(RetentionPolicy.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    LabeledContent("저장 위치", value: "이 기기")
                }

                Section("개인정보") {
                    Toggle("Face ID / 기기 암호", isOn: $biometricLock)
                    Toggle("개인정보 보호 내보내기", isOn: $stripsMetadata)
                    Toggle("앱 전환기에서 가리기", isOn: $appSwitcherProtection)
                }

                Section("워터마크") {
                    Toggle("워터마크", isOn: $watermarkEnabled)
                    if watermarkEnabled { TextField("사용자 지정 문구", text: .constant("SubGallery")) }
                }

                Section {
                    Toggle("iCloud 동기화", isOn: $iCloudSync)
                    LabeledContent("현재 상태", value: iCloudSync ? "설정 필요" : "이 기기에만 저장됨")
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("CloudKit 컨테이너를 Apple Developer 계정에서 활성화하면 기기 간 동기화를 사용할 수 있습니다.")
                }

                Section("권한") {
                    PermissionRow(title: "카메라", status: cameraStatus)
                    PermissionRow(title: "마이크", status: microphoneStatus)
                    PermissionRow(title: "사진 추가", status: photoStatus)
                    PermissionRow(title: "위치", status: locationStatus)
                }

                Section("앱") {
                    Picker("화면 모드", selection: $appearance) {
                        Text("시스템 설정").tag("system"); Text("라이트").tag("light"); Text("다크").tag("dark")
                    }
                    LabeledContent("버전", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }

                Section("지원") {
                    Link("문의하기", destination: URL(string: "mailto:support@namslab.com")!)
                    Link("개인정보 처리방침", destination: URL(string: "https://namslab.com/privacy")!)
                    Link("서비스 약관", destination: URL(string: "https://namslab.com/terms")!)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
    }

    private var cameraStatus: String { authorizationText(AVCaptureDevice.authorizationStatus(for: .video)) }
    private var microphoneStatus: String { authorizationText(AVCaptureDevice.authorizationStatus(for: .audio)) }
    private var photoStatus: String {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited: "허용됨"
        case .denied, .restricted: "허용 안 됨"
        default: "요청 전"
        }
    }
    private var locationStatus: String {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: "허용됨"
        case .denied, .restricted: "허용 안 됨"
        default: "요청 전"
        }
    }
    private func authorizationText(_ status: AVAuthorizationStatus) -> String {
        switch status { case .authorized: "허용됨"; case .denied, .restricted: "허용 안 됨"; default: "요청 전" }
    }
}

private struct PermissionRow: View {
    let title: String
    let status: String
    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
            LabeledContent(title, value: status)
        }
        .foregroundStyle(.primary)
    }
}
