import CoreLocation
import LocalAuthentication
import StoreKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    @AppStorage("storage.defaultRetention") private var defaultRetention = RetentionPolicy.forever.rawValue
    @AppStorage("storage.defaultRetentionDate") private var defaultRetentionDate = 0.0
    @AppStorage("privacy.biometricLock") private var biometricLock = false
    @AppStorage("privacy.stripMetadata") private var stripsMetadata = false
    @AppStorage("privacy.appSwitcherProtection") private var appSwitcherProtection = true
    @AppStorage("icloud.sync") private var iCloudSync = false
    @AppStorage("icloud.syncStatus") private var iCloudStatus = "idle"
    @AppStorage("camera.saveLocation") private var savesLocation = false
    @AppStorage("app.language") private var appLanguage = AppLanguage.system.rawValue
    @AppStorage("app.startScreen") private var appStartScreen = AppStartScreen.library.rawValue
    @AppStorage("defaults.cameraDestination") private var defaultCameraDestination = StorageDestination.camera.token
    @AppStorage("defaults.importDestination") private var defaultImportDestination = StorageDestination.all.token
    @AppStorage("defaults.shareDestination") private var defaultShareDestination = StorageDestination.temporary.token
    @AppStorage("camera.destinationAlbumID") private var currentCameraDestination = StorageDestination.camera.token
    @StateObject private var locationPermission = LocationPermissionController()
    @State private var showsLocationSettingsAlert = false
    @State private var biometryType: LABiometryType = .none
    @State private var biometricsAvailable = false
    @State private var biometricError: String?

    private let retentionOptions: [RetentionPolicy] = [
        .forever, .untilComplete, .today, .oneDay, .sevenDays, .thirtyDays, .customDate
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("보관") {
                    Picker("기본 보관 기간", selection: $defaultRetention) {
                        ForEach(retentionOptions) { policy in
                            Text(policy.title).tag(policy.rawValue)
                        }
                    }

                    if defaultRetention == RetentionPolicy.customDate.rawValue {
                        DatePicker("날짜", selection: customRetentionDate, in: Date.now..., displayedComponents: .date)
                    }
                }

                Section {
                    Picker("카메라", selection: $defaultCameraDestination) {
                        Text("카메라").tag(StorageDestination.camera.token)
                        Text("임시 보관").tag(StorageDestination.temporary.token)
                        destinationAlbumOptions
                    }
                    Picker("가져오기", selection: $defaultImportDestination) {
                        Text("전체").tag(StorageDestination.all.token)
                        Text("임시 보관").tag(StorageDestination.temporary.token)
                        destinationAlbumOptions
                    }
                    Picker("공유로 가져오기", selection: $defaultShareDestination) {
                        Text("임시 보관").tag(StorageDestination.temporary.token)
                        destinationAlbumOptions
                    }
                } header: {
                    Text("기본 앨범")
                } footer: {
                    Text("사용자 앨범을 선택하면 해당 앨범의 기본 보관 기간도 자동으로 적용됩니다.")
                }

                Section {
                    Toggle(biometricLockTitle, isOn: biometricLockToggle)
                        .disabled(!biometricsAvailable && !biometricLock)
                    Toggle("앱 전환기에서 가리기", isOn: $appSwitcherProtection)
                    Toggle("내보낼 때 위치 정보 제거", isOn: $stripsMetadata)
                } header: {
                    Text("개인정보 보호")
                } footer: {
                    Text(biometricPrivacyDescription)
                }

                Section("iCloud") {
                    Toggle(isOn: $iCloudSync) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("iCloud 동기화")
                            Text(iCloudStatusText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("카메라") {
                    Picker("앱 시작 화면", selection: $appStartScreen) {
                        ForEach(AppStartScreen.allCases) { screen in
                            Text(screen.title).tag(screen.rawValue)
                        }
                    }
                    Toggle("위치 정보 저장", isOn: locationToggle)
                }

                Section("언어") {
                    Picker("앱 언어", selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }
                }

                Section {
                    NavigationLink("사용 방법") { UsageGuideView() }
                    Link(destination: URL(string: "https://apps.apple.com/app/id6804523282?action=write-review")!) {
                        Label("응원하기", systemImage: "heart.fill")
                    }
                    Button("앱 평가하기") { requestReview() }
                    Link("문의하기", destination: URL(string: "mailto:support@namslab.com")!)
                    Link("개인정보 처리방침", destination: URL(string: "https://namslab.com/privacy")!)
                    Link("서비스 약관", destination: URL(string: "https://namslab.com/terms")!)
                } header: {
                    Text("지원")
                } footer: {
                    Text("SubGallery \(appVersion)")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .onChange(of: defaultRetention) { _, value in
                guard value == RetentionPolicy.customDate.rawValue,
                      Date(timeIntervalSince1970: defaultRetentionDate) < .now else { return }
                defaultRetentionDate = Calendar.current.date(byAdding: .day, value: 1, to: .now)?.timeIntervalSince1970
                    ?? Date.now.timeIntervalSince1970
            }
            .onChange(of: defaultCameraDestination) { _, destination in
                currentCameraDestination = destination
            }
            .onAppear {
                validateDefaultDestinations()
                updateBiometricAvailability()
            }
            .alert("위치 접근이 필요합니다.", isPresented: $showsLocationSettingsAlert) {
                Button("취소", role: .cancel) { }
                Button("설정 열기") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
            .alert("Touch ID를 사용할 수 없음", isPresented: Binding(
                get: { biometricError != nil },
                set: { if !$0 { biometricError = nil } }
            )) {
                Button("확인", role: .cancel) { }
                Button("설정 열기") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            } message: {
                Text(biometricError ?? "Touch ID 설정을 확인해 주세요.")
            }
        }
    }

    private var biometricLockTitle: String {
        "Touch ID로 잠금"
    }

    private var biometricPrivacyDescription: String {
        if biometricsAvailable || biometricLock {
            return "앱을 다시 열거나 다른 앱에서 돌아오면 인증 후 보관함을 표시합니다."
        }
        return "이 기기에서 사용할 수 있는 Touch ID가 없습니다."
    }

    private var biometricLockToggle: Binding<Bool> {
        Binding(
            get: { biometricLock },
            set: { enabled in
                if enabled {
                    enableBiometricLock()
                } else {
                    biometricLock = false
                }
            }
        )
    }

    private func updateBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        biometricsAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            && context.biometryType == .touchID
        biometryType = context.biometryType
        if biometryType != .touchID { biometricLock = false }
    }

    private func enableBiometricLock() {
        let context = LAContext()
        context.localizedCancelTitle = L10n.text("취소")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
              context.biometryType == .touchID else {
            biometricLock = false
            biometricError = error?.localizedDescription ?? "Touch ID를 먼저 설정해 주세요."
            updateBiometricAvailability()
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Touch ID로 SubGallery의 비공개 보관함 잠금을 켭니다."
        ) { success, error in
            DispatchQueue.main.async {
                biometricLock = success
                if !success {
                    biometricError = error?.localizedDescription ?? "Touch ID 인증에 실패했습니다."
                }
                updateBiometricAvailability()
            }
        }
    }

    @ViewBuilder
    private var destinationAlbumOptions: some View {
        ForEach(albums) { album in
            Text(album.name).tag(StorageDestination.album(album.id).token)
        }
    }

    private func validateDefaultDestinations() {
        let validIDs = Set(albums.map(\.id))
        if case .album(let id) = StorageDestination(token: defaultCameraDestination), !validIDs.contains(id) {
            defaultCameraDestination = StorageDestination.camera.token
        }
        if case .album(let id) = StorageDestination(token: defaultImportDestination), !validIDs.contains(id) {
            defaultImportDestination = StorageDestination.all.token
        }
        if case .album(let id) = StorageDestination(token: defaultShareDestination), !validIDs.contains(id) {
            defaultShareDestination = StorageDestination.temporary.token
        }
    }

    private var customRetentionDate: Binding<Date> {
        Binding(
            get: {
                let stored = Date(timeIntervalSince1970: defaultRetentionDate)
                return stored >= .now ? stored : Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
            },
            set: { defaultRetentionDate = $0.timeIntervalSince1970 }
        )
    }

    private var locationToggle: Binding<Bool> {
        Binding(
            get: { savesLocation },
            set: { enabled in
                guard enabled else {
                    savesLocation = false
                    return
                }
                locationPermission.requestAccess { granted in
                    savesLocation = granted
                    showsLocationSettingsAlert = !granted
                }
            }
        )
    }

    private var iCloudStatusText: String {
        guard iCloudSync else { return L10n.text("현재 이 기기에만 저장됩니다.") }
        switch iCloudStatus {
        case "syncing": return L10n.text("iCloud 동기화 중…")
        case "error": return L10n.text("iCloud 동기화를 확인해주세요.")
        default: return L10n.text("iCloud에 동기화됩니다.")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

private struct UsageGuideView: View {
    private let guides: [(String, String, String)] = [
        ("camera", "사진 촬영하기", "보관함 아래의 카메라를 누르고 촬영하세요. 저장 대상 앨범과 보관 기간도 카메라에서 바꿀 수 있습니다."),
        ("photo.badge.plus", "Photos에서 가져오기", "보관함의 사진 가져오기를 눌러 여러 사진이나 동영상을 선택하세요."),
        ("rectangle.stack", "앨범에 사진 넣기", "사진의 … 메뉴 또는 선택 모드의 일괄 작업에서 앨범으로 이동을 사용하세요."),
        ("checkmark.circle", "전체 선택하기", "앨범에서 선택을 누른 다음 전체 선택을 누르세요. 같은 버튼으로 전체 선택을 해제할 수 있습니다."),
        ("square.and.arrow.up", "사진 한 번에 내보내기", "전체 선택 후 일괄 작업에서 Photos에 저장, Files로 내보내기 또는 공유를 선택하세요."),
        ("clock", "임시 보관 사용법", "보관 기간을 정하면 기한이 지난 항목은 최근 삭제로 이동하며 7일 뒤 완전히 삭제됩니다."),
        ("checkmark.circle.fill", "완료할 때까지 보관", "처리가 끝날 때까지 두고, 사진의 완료 버튼을 눌러 직접 정리할 수 있습니다."),
        ("pin", "고정 / 다시 알려주기", "꼭 남길 사진은 고정하고, 나중에 확인할 사진은 다시 알려주기로 알림을 설정하세요.")
    ]

    var body: some View {
        List(guides.indices, id: \.self) { index in
            guideRow(guides[index])
        }
        .navigationTitle("사용 방법")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guideRow(_ guide: (String, String, String)) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(guide.1).font(.headline)
                Text(guide.2).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } icon: {
            Image(systemName: guide.0).foregroundStyle(.tint)
        }
    }
}

@MainActor
private final class LocationPermissionController: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var completion: ((Bool) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            completion(true)
        case .notDetermined:
            self.completion = completion
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined, let completion else { return }
        self.completion = nil
        completion(manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse)
    }
}
