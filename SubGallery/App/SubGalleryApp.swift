import AppIntents
import CloudKit
import CoreData
import CryptoKit
import Security
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

extension Notification.Name {
    static let openReminderMedia = Notification.Name("openReminderMedia")
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var cloudEventObserver: NSObjectProtocol?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        cloudEventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard UserDefaults.standard.bool(forKey: "icloud.active"),
                  let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let eventType: String
            switch event.type {
            case .setup: eventType = "setup"
            case .import: eventType = "import"
            case .export: eventType = "export"
            @unknown default: eventType = "unknown"
            }
            UserDefaults.standard.set(eventType, forKey: "icloud.lastEventType")
            let status: String
            if event.endDate == nil {
                status = "syncing"
            } else {
                status = event.succeeded ? "ready" : "error"
                if let error = event.error {
                    let nsError = error as NSError
                    let details = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription) \(nsError.userInfo)"
                    UserDefaults.standard.set(details, forKey: "icloud.lastError")
                    #if DEBUG
                    print("CloudKit \(eventType) error: \(details)")
                    #endif
                } else {
                    UserDefaults.standard.removeObject(forKey: "icloud.lastError")
                }
            }
            UserDefaults.standard.set(status, forKey: "icloud.syncStatus")
        }
        return true
    }

    deinit {
        if let cloudEventObserver {
            NotificationCenter.default.removeObserver(cloudEventObserver)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let rawID = response.notification.request.content.userInfo["mediaID"] as? String,
              UUID(uuidString: rawID) != nil else { return }
        UserDefaults.standard.set(rawID, forKey: "navigation.pendingMediaID")
        await MainActor.run {
            NotificationCenter.default.post(name: .openReminderMedia, object: rawID)
        }
    }
}

@main
struct SubGalleryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var isCameraPresented = false
    @State private var obscuresContent = false
    @State private var isUnlocked = false
    @State private var deepLink: MediaDeepLink?
    @State private var requestedLibraryDestination: AlbumDestination?
    @State private var didApplyInitialStartScreen = false
    @AppStorage("privacy.pinLock") private var pinLock = false
    @AppStorage("privacy.appSwitcherProtection") private var appSwitcherProtection = true
    @AppStorage("app.language") private var appLanguageRaw = AppLanguage.system.rawValue
    @AppStorage("app.startScreen") private var startScreenRaw = AppStartScreen.library.rawValue
    @AppStorage("app.lastScreen") private var lastScreenRaw = AppStartScreen.library.rawValue
    @AppStorage("defaults.cameraDestination") private var defaultCameraDestination = StorageDestination.camera.token
    @AppStorage("camera.destinationAlbumID") private var currentCameraDestination = StorageDestination.camera.token

    private let dataStore = DataStoreBootstrap.make()

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let errorMessage = dataStore.errorMessage {
                    DataStoreErrorView(message: errorMessage)
                } else {
                    LibraryView(
                        isCameraPresented: $isCameraPresented,
                        requestedDestination: $requestedLibraryDestination
                    )
                        .blur(radius: obscuresContent ? 28 : 0)
                        .allowsHitTesting(!obscuresContent)
                }

                if pinLock && !isUnlocked {
                    PINLockView(unlock: unlock)
                }
            }
            .environment(\.locale, (AppLanguage(rawValue: appLanguageRaw) ?? .system).locale)
            .fullScreenCover(isPresented: $isCameraPresented) {
                CameraView { destination in
                    requestedLibraryDestination = destination
                    isCameraPresented = false
                }
                .overlay {
                    if pinLock && !isUnlocked {
                        PINLockView(unlock: unlock)
                    }
                }
            }
            .fullScreenCover(item: $deepLink) { target in
                ReminderDestinationView(mediaID: target.id)
                    .overlay {
                        if pinLock && !isUnlocked {
                            PINLockView(unlock: unlock)
                        }
                    }
            }
            .onOpenURL { url in
                if url.host == "capture" {
                    currentCameraDestination = defaultCameraDestination
                    isCameraPresented = true
                } else if url.host == "media",
                          let id = UUID(uuidString: url.pathComponents.last ?? "") {
                    UserDefaults.standard.set(id.uuidString, forKey: "navigation.pendingMediaID")
                    openPendingReminderIfNeeded()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openReminderMedia)) { notification in
                guard let rawID = notification.object as? String, UUID(uuidString: rawID) != nil else { return }
                UserDefaults.standard.set(rawID, forKey: "navigation.pendingMediaID")
                openPendingReminderIfNeeded()
            }
            .task {
                #if DEBUG
                await prepareUITestFixtureIfNeeded()
                if ProcessInfo.processInfo.arguments.contains("-cloudkit-diagnostic") {
                    await runCloudKitDiagnostic()
                }
                #endif
                if dataStore.errorMessage == nil {
                    if dataStore.usesCloudKit {
                        await reconcileCloudMediaAssets()
                    }
                    CapturePresetService.seedBuiltIns(in: dataStore.container.mainContext)
                    SharedInboxService.publishConfiguration(
                        albums: (try? dataStore.container.mainContext.fetch(FetchDescriptor<Album>())) ?? []
                    )
                    await SharedInboxService.ingestPendingItems(in: dataStore.container.mainContext)
                    await performExpirationSweep()
                    resumePendingOCR()
                }
                openPendingReminderIfNeeded()
                UserDefaults.standard.removeObject(forKey: "privacy.biometricLock")
                if pinLock && !PINCredentialStore.hasPIN {
                    pinLock = false
                }
                if !pinLock {
                    isUnlocked = true
                    applyInitialStartScreenIfNeeded()
                }
            }
            .onChange(of: isCameraPresented) { _, isPresented in
                guard didApplyInitialStartScreen else { return }
                lastScreenRaw = isPresented ? AppStartScreen.camera.rawValue : AppStartScreen.library.rawValue
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    obscuresContent = false
                    openPendingReminderIfNeeded()
                    if dataStore.errorMessage == nil {
                        Task {
                            if dataStore.usesCloudKit {
                                await reconcileCloudMediaAssets()
                            }
                            await SharedInboxService.ingestPendingItems(in: dataStore.container.mainContext)
                            await performExpirationSweep()
                        }
                    }
                case .inactive, .background:
                    obscuresContent = appSwitcherProtection
                    if pinLock { isUnlocked = false }
                @unknown default: break
                }
            }
        }
        .modelContainer(dataStore.container)
    }

    private func unlock(with pin: String) -> Bool {
        guard PINCredentialStore.verify(pin) else { return false }
        isUnlocked = true
        openPendingReminderIfNeeded()
        applyInitialStartScreenIfNeeded()
        return true
    }

    private func applyInitialStartScreenIfNeeded() {
        guard !didApplyInitialStartScreen else { return }
        didApplyInitialStartScreen = true
        let start = AppStartScreen(rawValue: startScreenRaw) ?? .library
        let opensCamera = start == .camera || (start == .last && lastScreenRaw == AppStartScreen.camera.rawValue)
        if opensCamera { currentCameraDestination = defaultCameraDestination }
        isCameraPresented = opensCamera
    }

    @MainActor
    private func performExpirationSweep() async {
        let context = dataStore.container.mainContext
        let now = Date.now
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        for item in items where item.deletedAt == nil && (item.expirationDate.map { $0 <= now } ?? false) {
            if item.isPinned {
                if let identifier = await ReminderService.shared.schedulePinnedExpirationSafetyIfAuthorized(for: item) {
                    item.reminderIdentifier = identifier
                    item.reminderDate = now
                }
            } else if RetentionService.shouldMoveToRecentlyDeleted(item, now: now) {
                await MediaLifecycleService.moveToRecentlyDeleted(item)
            }
        }
        let purgeBefore = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        for item in items where (item.deletedAt ?? .distantFuture) < purgeBefore {
            await MediaLifecycleService.permanentlyDelete(item, from: context)
        }
        try? context.save()
    }

    @MainActor
    private func resumePendingOCR() {
        let context = dataStore.container.mainContext
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        for item in items where item.deletedAt == nil && item.kind == .photo
            && (item.ocrStatus == .pending || item.ocrStatus == .processing) {
            item.ocrStatus = .pending
            OCRService.enqueue(item, in: context)
        }
    }

    @MainActor
    private func reconcileCloudMediaAssets() async {
        let context = dataStore.container.mainContext
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        var changed = false

        for item in items {
            let localMediaURL = MediaStorage.url(for: item.localPath)
            if item.cloudMediaData == nil,
               FileManager.default.fileExists(atPath: localMediaURL.path),
               let data = try? Data(contentsOf: localMediaURL, options: .mappedIfSafe) {
                item.cloudMediaData = data
                changed = true
            } else if !FileManager.default.fileExists(atPath: localMediaURL.path) {
                _ = item.mediaURL
            }

            if let thumbnailPath = item.thumbnailPath {
                let localThumbnailURL = MediaStorage.url(for: thumbnailPath)
                if item.cloudThumbnailData == nil,
                   FileManager.default.fileExists(atPath: localThumbnailURL.path),
                   let data = try? Data(contentsOf: localThumbnailURL, options: .mappedIfSafe) {
                    item.cloudThumbnailData = data
                    changed = true
                } else if !FileManager.default.fileExists(atPath: localThumbnailURL.path) {
                    _ = item.thumbnailURL
                }
            }
            await Task.yield()
        }
        if changed { try? context.save() }
    }

    private func openPendingReminderIfNeeded() {
        guard (!pinLock || isUnlocked),
              !isCameraPresented,
              deepLink == nil,
              let rawID = UserDefaults.standard.string(forKey: "navigation.pendingMediaID"),
              let id = UUID(uuidString: rawID) else { return }
        deepLink = MediaDeepLink(id: id)
        UserDefaults.standard.removeObject(forKey: "navigation.pendingMediaID")
    }

    #if DEBUG
    private func runCloudKitDiagnostic() async {
        let database = CKContainer(identifier: DataStoreBootstrap.cloudContainerIdentifier).privateCloudDatabase
        let record = CKRecord(recordType: "SubGalleryDiagnostic")
        record["createdAt"] = Date.now as CKRecordValue
        do {
            let saved = try await database.save(record)
            try await database.deleteRecord(withID: saved.recordID)
            print("CloudKit direct diagnostic: success")
        } catch {
            let nsError = error as NSError
            print("CloudKit direct diagnostic error: \(nsError.domain) \(nsError.code) \(nsError.userInfo)")
        }
    }

    @MainActor
    private func prepareUITestFixtureIfNeeded() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), dataStore.errorMessage == nil else { return }
        let context = dataStore.container.mainContext
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        for item in items where item.fileName == "__SubGalleryUITest.jpg" {
            await MediaLifecycleService.permanentlyDelete(item, from: context)
        }
        try? context.save()
        guard !arguments.contains("-ui-test-cleanup-only") else { return }

        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            NSString(string: "B3 142\n스타벅스").draw(
                in: CGRect(x: 80, y: 160, width: 1040, height: 480),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 120, weight: .bold),
                    .foregroundColor: UIColor.black
                ]
            )
        }
        guard let data = image.jpegData(compressionQuality: 0.95),
              let stored = try? await MediaStorage.shared.store(
                data: data,
                type: .jpeg,
                preferredName: "__SubGalleryUITest.jpg"
              ) else { return }
        let item = MediaItem(
            kind: .photo,
            source: .files,
            localPath: stored.relativePath,
            thumbnailPath: stored.thumbnailRelativePath,
            fileName: "__SubGalleryUITest.jpg",
            fileSize: stored.fileSize,
            width: stored.width,
            height: stored.height
        )
        RetentionService.apply(.untilComplete, to: item)
        item.recognizedText = "B3 142\n스타벅스"
        item.ocrStatus = .completed
        context.insert(item)
        try? context.save()
    }
    #endif
}

private struct MediaDeepLink: Identifiable {
    let id: UUID
}

private struct ReminderDestinationView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var items: [MediaItem]
    let mediaID: UUID

    var body: some View {
        if let item = items.first(where: { $0.id == mediaID && $0.deletedAt == nil }) {
            MediaViewer(items: [item], initialID: item.id, isRecentlyDeleted: false)
        } else {
            NavigationStack {
                ContentUnavailableView(
                    "사진을 찾을 수 없습니다",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text(L10n.text("삭제되었거나 더 이상 이 기기에 없는 항목입니다."))
                )
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("닫기")) { dismiss() } } }
            }
        }
    }
}

struct DataStoreBootstrap {
    static let cloudContainerIdentifier = "iCloud.com.namslab.subgallery"

    let container: ModelContainer
    let errorMessage: String?
    let usesCloudKit: Bool

    static func make() -> DataStoreBootstrap {
        let schema = Schema([MediaItem.self, Album.self, CapturePreset.self])
        let cloudRequested = UserDefaults.standard.bool(forKey: "icloud.sync")
        do {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            try FileManager.default.createDirectory(
                at: applicationSupport,
                withIntermediateDirectories: true
            )
            let configuration = ModelConfiguration(
                "LocalLibrary",
                schema: schema,
                url: applicationSupport.appending(path: "default.store"),
                allowsSave: true,
                cloudKitDatabase: cloudRequested ? .private(cloudContainerIdentifier) : .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            UserDefaults.standard.set(cloudRequested, forKey: "icloud.active")
            UserDefaults.standard.set(cloudRequested ? "ready" : "idle", forKey: "icloud.syncStatus")
            return DataStoreBootstrap(container: container, errorMessage: nil, usesCloudKit: cloudRequested)
        } catch {
            if cloudRequested {
                UserDefaults.standard.set(error.localizedDescription, forKey: "icloud.lastError")
                #if DEBUG
                print("CloudKit store initialization error: \(error)")
                #endif
                do {
                    let applicationSupport = FileManager.default.urls(
                        for: .applicationSupportDirectory,
                        in: .userDomainMask
                    )[0]
                    let localConfiguration = ModelConfiguration(
                        "LocalLibrary",
                        schema: schema,
                        url: applicationSupport.appending(path: "default.store"),
                        allowsSave: true,
                        cloudKitDatabase: .none
                    )
                    let localContainer = try ModelContainer(for: schema, configurations: [localConfiguration])
                    UserDefaults.standard.set(false, forKey: "icloud.active")
                    UserDefaults.standard.set("error", forKey: "icloud.syncStatus")
                    return DataStoreBootstrap(container: localContainer, errorMessage: nil, usesCloudKit: false)
                } catch {
                    // Continue to the recovery store below.
                }
            }
            // A temporary container lets SwiftUI render a useful recovery screen
            // instead of leaving the system launch screen visible indefinitely.
            let fallback = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            guard let container = try? ModelContainer(for: schema, configurations: [fallback]) else {
                fatalError("Both persistent and recovery stores failed: \(error)")
            }
            UserDefaults.standard.set(false, forKey: "icloud.active")
            UserDefaults.standard.set("error", forKey: "icloud.syncStatus")
            return DataStoreBootstrap(
                container: container,
                errorMessage: error.localizedDescription,
                usesCloudKit: false
            )
        }
    }
}

private struct DataStoreErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(L10n.text("보관함을 열 수 없습니다"), systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("앱을 완전히 종료한 뒤 다시 실행해 주세요. 문제가 계속되면 아래 오류를 함께 알려주세요.\n\n\(message)")
        }
        .padding()
    }
}

enum PINCredentialStore {
    private static let service = "com.namslab.subgallery.pin"
    private static let account = "primary"

    static var hasPIN: Bool { credentialData() != nil }

    @discardableResult
    static func set(_ pin: String) -> Bool {
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else { return false }
        var salt = Data(count: 16)
        let result = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard result == errSecSuccess else { return false }
        let digest = Data(SHA256.hash(data: salt + Data(pin.utf8)))
        let value = salt + digest
        remove()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: value
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func verify(_ pin: String) -> Bool {
        guard let value = credentialData(), value.count == 48 else { return false }
        let salt = value.prefix(16)
        let storedHash = value.suffix(32)
        let enteredHash = Data(SHA256.hash(data: salt + Data(pin.utf8)))
        return zip(storedHash, enteredHash).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func credentialData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

struct PINLockView: View {
    let unlock: (String) -> Bool
    @State private var pin = ""
    @State private var showsError = false

    var body: some View {
        PINEntryPad(
            title: L10n.text("PIN 입력"),
            message: showsError
                ? L10n.text("PIN이 올바르지 않습니다.")
                : L10n.text("잠금을 해제하려면 PIN을 입력하세요."),
            pin: $pin,
            showsError: showsError
        ) { enteredPIN in
            if unlock(enteredPIN) {
                showsError = false
            } else {
                showsError = true
                pin = ""
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .privacySensitive()
    }
}

struct PINSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let completion: (Bool) -> Void
    @State private var pin = ""
    @State private var firstPIN: String?
    @State private var showsError = false

    var body: some View {
        NavigationStack {
            PINEntryPad(
                title: L10n.text(firstPIN == nil ? "새 PIN 입력" : "PIN 다시 입력"),
                message: showsError ? L10n.text("PIN이 일치하지 않습니다.") : L10n.text("4자리 PIN을 입력하세요."),
                pin: $pin,
                showsError: showsError
            ) { enteredPIN in
                if let firstPIN {
                    guard firstPIN == enteredPIN else {
                        self.firstPIN = nil
                        pin = ""
                        showsError = true
                        return
                    }
                    let saved = PINCredentialStore.set(enteredPIN)
                    completion(saved)
                    dismiss()
                } else {
                    firstPIN = enteredPIN
                    pin = ""
                    showsError = false
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("취소")) {
                        completion(false)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct PINVerificationView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let completion: (Bool) -> Void
    @State private var pin = ""
    @State private var showsError = false

    var body: some View {
        NavigationStack {
            PINEntryPad(
                title: title,
                message: showsError ? L10n.text("PIN이 올바르지 않습니다.") : L10n.text("현재 PIN을 입력하세요."),
                pin: $pin,
                showsError: showsError
            ) { enteredPIN in
                guard PINCredentialStore.verify(enteredPIN) else {
                    pin = ""
                    showsError = true
                    return
                }
                completion(true)
                dismiss()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("취소")) {
                        completion(false)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct PINEntryPad: View {
    let title: String
    let message: String
    @Binding var pin: String
    let showsError: Bool
    let completion: (String) -> Void

    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(showsError ? .red : .secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? Color.primary : Color.secondary.opacity(0.2))
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.bottom, 18)
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 36) {
                    ForEach(row, id: \.self) { digit in digitButton(digit) }
                }
            }
            HStack(spacing: 36) {
                Color.clear.frame(width: 72, height: 58)
                digitButton("0")
                Button {
                    if !pin.isEmpty { pin.removeLast() }
                } label: {
                    Image(systemName: "delete.left").font(.title2)
                }
                .buttonStyle(.plain)
                .frame(width: 72, height: 58)
                .accessibilityLabel(L10n.text("지우기"))
            }
            Spacer()
        }
        .padding()
    }

    private func digitButton(_ digit: String) -> some View {
        Button {
            guard pin.count < 4 else { return }
            pin.append(digit)
            if pin.count == 4 { completion(pin) }
        } label: {
            Text(digit).font(.title.weight(.medium)).frame(width: 72, height: 58)
        }
        .buttonStyle(.plain)
    }
}

struct QuickCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "SubGallery 빠른 촬영"
    static let description = IntentDescription("기본 사진 앱에 남기지 않고 SubGallery 카메라를 엽니다.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "subgallery://capture")!))
    }
}

struct SubGalleryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickCaptureIntent(),
            phrases: ["\(.applicationName)에서 빠르게 촬영", "\(.applicationName) 카메라 열기"],
            shortTitle: "빠른 촬영",
            systemImageName: "camera.fill"
        )
    }
}
