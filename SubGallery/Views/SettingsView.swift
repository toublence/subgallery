import CloudKit
import CoreLocation
import StoreKit
import SwiftData
import SwiftUI

enum SettingsPendingPremiumAction: Equatable {
    case enableICloud
    case enableMetadataRemoval
    case openCapturePresets
}

enum SettingsPremiumResumePolicy {
    static func actionToResume(
        wasPremium: Bool,
        isPremium: Bool,
        pendingAction: SettingsPendingPremiumAction?
    ) -> SettingsPendingPremiumAction? {
        guard !wasPremium, isPremium else { return nil }
        return pendingAction
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    @AppStorage("storage.defaultRetention") private var defaultRetention = RetentionPolicy.forever.rawValue
    @AppStorage("storage.defaultRetentionDate") private var defaultRetentionDate = 0.0
    @AppStorage("privacy.pinLock") private var pinLock = false
    @AppStorage("privacy.stripMetadata") private var stripsMetadata = false
    @AppStorage("privacy.appSwitcherProtection") private var appSwitcherProtection = true
    @AppStorage("icloud.sync") private var iCloudSync = false
    @AppStorage("icloud.active") private var iCloudActive = false
    @AppStorage("icloud.syncStatus") private var iCloudStatus = "idle"
    @AppStorage("camera.saveLocation") private var savesLocation = false
    @AppStorage("app.language") private var appLanguage = AppLanguage.system.rawValue
    @AppStorage("app.startScreen") private var appStartScreen = AppStartScreen.library.rawValue
    @AppStorage("defaults.cameraDestination") private var defaultCameraDestination = StorageDestination.camera.token
    @AppStorage("defaults.importDestination") private var defaultImportDestination = StorageDestination.all.token
    @AppStorage("camera.destinationAlbumID") private var currentCameraDestination = StorageDestination.camera.token
    @StateObject private var purchases = PurchaseManager.shared
    @StateObject private var locationPermission = LocationPermissionController()
    @State private var showsLocationSettingsAlert = false
    @State private var showsPINSetup = false
    @State private var showsPINVerification = false
    @State private var showsPremium = false
    @State private var premiumEntryPoint = PremiumEntryPoint.general
    @State private var pendingPremiumAction: SettingsPendingPremiumAction?
    @State private var showsCapturePresets = false
    @State private var iCloudError: String?

    private let retentionOptions: [RetentionPolicy] = [
        .forever, .untilComplete, .today, .oneDay, .sevenDays, .thirtyDays, .customDate
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("보관")) {
                    Picker(L10n.text("기본 보관 기간"), selection: $defaultRetention) {
                        ForEach(retentionOptions) { policy in
                            Text(policy.title).tag(policy.rawValue)
                        }
                    }

                    if defaultRetention == RetentionPolicy.customDate.rawValue {
                        DatePicker(L10n.text("날짜"), selection: customRetentionDate, in: Date.now..., displayedComponents: .date)
                    }
                }

                Section {
                    Picker(L10n.text("카메라"), selection: $defaultCameraDestination) {
                        Text(L10n.text("카메라")).tag(StorageDestination.camera.token)
                        Text(L10n.text("임시 보관")).tag(StorageDestination.temporary.token)
                        destinationAlbumOptions
                    }
                    Picker(L10n.text("가져오기"), selection: $defaultImportDestination) {
                        Text(L10n.text("전체")).tag(StorageDestination.all.token)
                        Text(L10n.text("임시 보관")).tag(StorageDestination.temporary.token)
                        destinationAlbumOptions
                    }
                } header: {
                    Text(L10n.text("기본 앨범"))
                } footer: {
                    Text(L10n.text("사용자 앨범을 선택하면 해당 앨범의 기본 보관 기간도 자동으로 적용됩니다."))
                }

                Section {
                    Toggle(L10n.text("PIN 잠금"), isOn: pinLockToggle)
                    if pinLock {
                        Button(L10n.text("PIN 변경")) { showsPINSetup = true }
                    }
                    Toggle(L10n.text("앱 전환기에서 가리기"), isOn: $appSwitcherProtection)
                    Toggle(L10n.text("내보낼 때 메타데이터 제거"), isOn: metadataRemovalToggle)
                } header: {
                    Text(L10n.text("개인정보 보호"))
                } footer: {
                    Text(L10n.text("PIN 잠금을 사용하면 앱을 다시 열거나 다른 앱에서 돌아올 때 PIN을 입력해야 합니다.") + " " + L10n.text("메타데이터 제거를 켜면 Photos, Files와 공유로 내보낼 때 위치·기기·촬영 정보를 제거합니다."))
                }

                Section {
                    Toggle(isOn: iCloudSyncToggle) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.text("iCloud 동기화"))
                            Text(iCloudStatusText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("iCloud")
                } footer: {
                    Text(L10n.text("사진과 동영상은 같은 Apple 계정으로 로그인한 기기 사이에서 동기화됩니다."))
                }

                Section(L10n.text("카메라")) {
                    Picker(L10n.text("앱 시작 화면"), selection: $appStartScreen) {
                        ForEach(AppStartScreen.allCases) { screen in
                            Text(screen.title).tag(screen.rawValue)
                        }
                    }
                    Toggle(L10n.text("위치 정보 저장"), isOn: locationToggle)
                    if purchases.isPremium {
                        NavigationLink(L10n.text("촬영 프리셋")) { CapturePresetListView() }
                    } else {
                        Button {
                            pendingPremiumAction = .openCapturePresets
                            premiumEntryPoint = .capturePreset
                            showsPremium = true
                        } label: {
                            HStack {
                                Text(L10n.text("촬영 프리셋"))
                                Spacer()
                                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }

                Section(L10n.text("언어")) {
                    Picker(L10n.text("앱 언어"), selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }
                }

                Section {
                    Button(L10n.text("사용 방법 다시 보기")) {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            NotificationCenter.default.post(name: .replayOnboarding, object: nil)
                        }
                    }
                    Link(destination: URL(string: "https://apps.apple.com/app/id6804523282?action=write-review")!) {
                        Label(L10n.text("응원하기"), systemImage: "heart.fill")
                    }
                    Button(L10n.text("앱 평가하기")) { requestReview() }
                    Link(L10n.text("개인정보 처리방침"), destination: URL(string: "https://motionfit.fit/subgallery/privacy/")!)
                } header: {
                    Text(L10n.text("지원"))
                } footer: {
                    Text("SubGallery \(appVersion)")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .navigationDestination(isPresented: $showsCapturePresets) {
                CapturePresetListView()
            }
            .navigationTitle(L10n.text("설정"))
            .id(appLanguage)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("완료")) { dismiss() }
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
                refreshICloudAccountStatus()
            }
            .task { await purchases.prepare() }
            .sheet(isPresented: $showsPINSetup) {
                PINSetupView { saved in
                    if saved { pinLock = true }
                }
            }
            .sheet(isPresented: $showsPINVerification) {
                PINVerificationView(title: L10n.text("PIN 잠금 해제")) { verified in
                    if verified {
                        PINCredentialStore.remove()
                        pinLock = false
                    }
                }
            }
            .sheet(isPresented: $showsPremium, onDismiss: {
                if !purchases.isPremium { pendingPremiumAction = nil }
            }) {
                PremiumView(entryPoint: premiumEntryPoint).presentationDetents([.large])
            }
            .onChange(of: purchases.isPremium) { wasPremium, isPremium in
                guard let action = SettingsPremiumResumePolicy.actionToResume(
                    wasPremium: wasPremium,
                    isPremium: isPremium,
                    pendingAction: pendingPremiumAction
                ) else { return }
                pendingPremiumAction = nil
                showsPremium = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    resumePremiumAction(action)
                }
            }
            .alert(L10n.text("iCloud를 사용할 수 없음"), isPresented: Binding(
                get: { iCloudError != nil },
                set: { if !$0 { iCloudError = nil } }
            )) {
                Button(L10n.text("확인"), role: .cancel) { }
            } message: {
                Text(iCloudError ?? L10n.text("iCloud 동기화를 확인해주세요."))
            }
            .alert(L10n.text("위치 접근이 필요합니다."), isPresented: $showsLocationSettingsAlert) {
                Button(L10n.text("취소"), role: .cancel) { }
                Button(L10n.text("설정 열기")) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    private var pinLockToggle: Binding<Bool> {
        Binding(
            get: { pinLock },
            set: { enabled in
                if enabled {
                    showsPINSetup = true
                } else {
                    showsPINVerification = true
                }
            }
        )
    }

    private var metadataRemovalToggle: Binding<Bool> {
        Binding(
            get: { stripsMetadata },
            set: { enabled in
                guard !enabled || purchases.isPremium else {
                    pendingPremiumAction = .enableMetadataRemoval
                    premiumEntryPoint = .privacyExport
                    showsPremium = true
                    return
                }
                stripsMetadata = enabled
            }
        )
    }

    @ViewBuilder
    private var destinationAlbumOptions: some View {
        ForEach(albums) { album in
            Text(album.displayName).tag(StorageDestination.album(album.id).token)
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
        if iCloudStatus == "restartRequired" {
            return L10n.text("iCloud 설정을 적용하려면 앱을 완전히 종료한 뒤 다시 실행해 주세요.")
        }
        guard iCloudSync else { return L10n.text("현재 이 기기에만 저장됩니다.") }
        switch iCloudStatus {
        case "checking": return L10n.text("iCloud 계정을 확인하는 중…")
        case "syncing": return L10n.text("iCloud 동기화 중…")
        case "error": return L10n.text("iCloud 동기화를 확인해주세요.")
        default: return L10n.text("iCloud에 동기화됩니다.")
        }
    }

    private var iCloudSyncToggle: Binding<Bool> {
        Binding(
            get: { iCloudSync },
            set: { enabled in
                if enabled {
                    guard purchases.isPremium else {
                        pendingPremiumAction = .enableICloud
                        premiumEntryPoint = .iCloudSync
                        showsPremium = true
                        return
                    }
                    enableICloudSync()
                } else {
                    iCloudSync = false
                    iCloudStatus = iCloudActive ? "restartRequired" : "idle"
                }
            }
        )
    }

    private func enableICloudSync() {
        iCloudStatus = "checking"
        Task {
            do {
                let status = try await CKContainer(
                    identifier: DataStoreBootstrap.cloudContainerIdentifier
                ).accountStatus()
                guard purchases.isPremium, status == .available else {
                    iCloudSync = false
                    iCloudStatus = "error"
                    iCloudError = L10n.text("iCloud 동기화를 확인해주세요.")
                    return
                }
                iCloudSync = true
                iCloudStatus = "restartRequired"
            } catch {
                iCloudSync = false
                iCloudStatus = "error"
                iCloudError = error.localizedDescription
            }
        }
    }

    private func resumePremiumAction(_ action: SettingsPendingPremiumAction) {
        switch action {
        case .enableICloud:
            enableICloudSync()
        case .enableMetadataRemoval:
            stripsMetadata = true
        case .openCapturePresets:
            showsCapturePresets = true
        }
    }

    private func refreshICloudAccountStatus() {
        guard purchases.isPremium, iCloudSync else { return }
        Task {
            do {
                let status = try await CKContainer(
                    identifier: DataStoreBootstrap.cloudContainerIdentifier
                ).accountStatus()
                if iCloudSync != iCloudActive {
                    iCloudStatus = "restartRequired"
                } else {
                    iCloudStatus = status == .available ? "ready" : "error"
                }
            } catch {
                iCloudStatus = "error"
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

private struct CapturePresetListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CapturePreset.sortOrder) private var presets: [CapturePreset]
    @StateObject private var purchases = PurchaseManager.shared
    @State private var editingPreset: CapturePreset?
    @State private var createsPreset = false

    var body: some View {
        List {
            ForEach(presets) { preset in
                Button {
                    guard purchases.isPremium else { return }
                    editingPreset = preset
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.displayName).foregroundStyle(.primary)
                            Text(summary(preset)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    if purchases.isPremium && !preset.isBuiltIn {
                        Button(L10n.text("삭제"), role: .destructive) {
                            modelContext.delete(preset)
                            try? modelContext.save()
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.text("촬영 프리셋"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { createsPreset = true } label: { Label(L10n.text("프리셋 추가"), systemImage: "plus") }
                    .disabled(!purchases.isPremium)
            }
        }
        .sheet(item: $editingPreset) { preset in
            CapturePresetEditorView(preset: preset)
        }
        .sheet(isPresented: $createsPreset) {
            CapturePresetEditorView(preset: nil)
        }
    }

    private func summary(_ preset: CapturePreset) -> String {
        var values = [preset.retention.title]
        if preset.ocrEnabled { values.append(L10n.text("OCR 켬")) }
        if preset.savesLocation { values.append(L10n.text("위치 저장")) }
        if preset.autoPins { values.append(L10n.text("자동 고정")) }
        return values.joined(separator: " · ")
    }
}

private struct CapturePresetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    @StateObject private var purchases = PurchaseManager.shared
    let preset: CapturePreset?
    @State private var name: String
    @State private var albumToken: String
    @State private var retention: RetentionPolicy
    @State private var ocrEnabled: Bool
    @State private var savesLocation: Bool
    @State private var autoPins: Bool
    @State private var primaryAction: PrimaryMediaAction

    init(preset: CapturePreset?) {
        self.preset = preset
        _name = State(initialValue: preset?.name ?? "")
        _albumToken = State(initialValue: preset?.albumID?.uuidString ?? "")
        _retention = State(initialValue: preset?.retention ?? .untilComplete)
        _ocrEnabled = State(initialValue: preset?.ocrEnabled ?? true)
        _savesLocation = State(initialValue: preset?.savesLocation ?? false)
        _autoPins = State(initialValue: preset?.autoPins ?? false)
        _primaryAction = State(initialValue: preset?.primaryAction ?? .automatic)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("프리셋")) {
                    TextField(L10n.text("이름"), text: $name)
                    Picker(L10n.text("저장 앨범"), selection: $albumToken) {
                        Text(L10n.text("기존 기본 앨범")).tag("")
                        ForEach(albums) { album in Text(album.displayName).tag(album.id.uuidString) }
                    }
                    Picker(L10n.text("보관 기간"), selection: $retention) {
                        ForEach(RetentionPolicy.allCases.filter { $0 != .customDate }) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    Picker(L10n.text("대표 Action"), selection: $primaryAction) {
                        ForEach(PrimaryMediaAction.allCases) { action in Text(action.title).tag(action) }
                    }
                }
                Section(L10n.text("촬영 및 분석")) {
                    Toggle(L10n.text("텍스트·QR 분석"), isOn: $ocrEnabled)
                    Toggle(L10n.text("촬영 위치 저장"), isOn: $savesLocation)
                    Toggle(L10n.text("촬영 후 자동 고정"), isOn: $autoPins)
                }
            }
            .navigationTitle(L10n.text(preset == nil ? "프리셋 추가" : "프리셋 수정"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("취소")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("저장")) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        guard purchases.isPremium else {
            dismiss()
            return
        }
        let target: CapturePreset
        if let preset {
            target = preset
        } else {
            target = CapturePreset(name: name)
            target.purpose = .custom
            target.sortOrder = ((try? modelContext.fetch(FetchDescriptor<CapturePreset>()))?.count ?? 0)
            modelContext.insert(target)
        }
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        target.albumID = UUID(uuidString: albumToken)
        target.retention = retention
        target.ocrEnabled = ocrEnabled
        target.savesLocation = savesLocation
        target.autoPins = autoPins
        target.primaryAction = primaryAction
        try? modelContext.save()
        dismiss()
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
        .navigationTitle(L10n.text("사용 방법"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guideRow(_ guide: (String, String, String)) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(guide.1)).font(.headline)
                Text(L10n.text(guide.2)).font(.subheadline).foregroundStyle(.secondary)
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
