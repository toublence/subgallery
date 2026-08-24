import CoreLocation
import StoreKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @AppStorage("storage.defaultRetention") private var defaultRetention = RetentionPolicy.forever.rawValue
    @AppStorage("storage.defaultRetentionDate") private var defaultRetentionDate = 0.0
    @AppStorage("privacy.biometricLock") private var biometricLock = false
    @AppStorage("privacy.stripMetadata") private var stripsMetadata = false
    @AppStorage("privacy.appSwitcherProtection") private var appSwitcherProtection = true
    @AppStorage("icloud.sync") private var iCloudSync = false
    @AppStorage("icloud.syncStatus") private var iCloudStatus = "idle"
    @AppStorage("camera.saveLocation") private var savesLocation = false
    @AppStorage("app.language") private var appLanguage = AppLanguage.system.rawValue
    @StateObject private var locationPermission = LocationPermissionController()
    @State private var showsLocationSettingsAlert = false

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

                Section("개인정보 보호") {
                    Toggle("Face ID로 잠금", isOn: $biometricLock)
                    Toggle("앱 전환기에서 가리기", isOn: $appSwitcherProtection)
                    Toggle("내보낼 때 위치 정보 제거", isOn: $stripsMetadata)
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
            .alert("위치 접근이 필요합니다.", isPresented: $showsLocationSettingsAlert) {
                Button("취소", role: .cancel) { }
                Button("설정 열기") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
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
