import AppIntents
import LocalAuthentication
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

extension Notification.Name {
    static let openReminderMedia = Notification.Name("openReminderMedia")
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
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
    @AppStorage("privacy.biometricLock") private var biometricLock = false
    @AppStorage("privacy.appSwitcherProtection") private var appSwitcherProtection = true
    @AppStorage("app.language") private var appLanguageRaw = AppLanguage.system.rawValue

    private let dataStore = DataStoreBootstrap.make()

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let errorMessage = dataStore.errorMessage {
                    DataStoreErrorView(message: errorMessage)
                } else {
                    LibraryView(isCameraPresented: $isCameraPresented)
                        .blur(radius: obscuresContent ? 28 : 0)
                        .allowsHitTesting(!obscuresContent)
                }

                if biometricLock && !isUnlocked {
                    LockView(unlock: authenticate)
                }
            }
            .environment(\.locale, (AppLanguage(rawValue: appLanguageRaw) ?? .system).locale)
            .fullScreenCover(isPresented: $isCameraPresented) {
                CameraView()
            }
            .fullScreenCover(item: $deepLink) { target in
                ReminderDestinationView(mediaID: target.id)
            }
            .onOpenURL { url in
                if url.host == "capture" {
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
                #endif
                if dataStore.errorMessage == nil {
                    await performExpirationSweep()
                    resumePendingOCR()
                }
                openPendingReminderIfNeeded()
                if biometricLock { authenticate() } else { isUnlocked = true }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    obscuresContent = false
                    openPendingReminderIfNeeded()
                    if dataStore.errorMessage == nil {
                        Task { await performExpirationSweep() }
                    }
                    if biometricLock && !isUnlocked { authenticate() }
                case .inactive, .background:
                    obscuresContent = appSwitcherProtection
                    if biometricLock { isUnlocked = false }
                @unknown default: break
                }
            }
        }
        .modelContainer(dataStore.container)
    }

    private func authenticate() {
        guard biometricLock else { isUnlocked = true; return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "보관함 잠금 해제") { success, _ in
            DispatchQueue.main.async {
                isUnlocked = success
                if success { openPendingReminderIfNeeded() }
            }
        }
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

    private func openPendingReminderIfNeeded() {
        guard (!biometricLock || isUnlocked),
              !isCameraPresented,
              deepLink == nil,
              let rawID = UserDefaults.standard.string(forKey: "navigation.pendingMediaID"),
              let id = UUID(uuidString: rawID) else { return }
        deepLink = MediaDeepLink(id: id)
        UserDefaults.standard.removeObject(forKey: "navigation.pendingMediaID")
    }

    #if DEBUG
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
                    description: Text("삭제되었거나 더 이상 이 기기에 없는 항목입니다.")
                )
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
            }
        }
    }
}

private struct DataStoreBootstrap {
    let container: ModelContainer
    let errorMessage: String?

    static func make() -> DataStoreBootstrap {
        let schema = Schema([MediaItem.self, Album.self, CapturePreset.self])
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
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            return DataStoreBootstrap(container: container, errorMessage: nil)
        } catch {
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
            return DataStoreBootstrap(container: container, errorMessage: error.localizedDescription)
        }
    }
}

private struct DataStoreErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("보관함을 열 수 없습니다", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("앱을 완전히 종료한 뒤 다시 실행해 주세요. 문제가 계속되면 아래 오류를 함께 알려주세요.\n\n\(message)")
        }
        .padding()
    }
}

struct LockView: View {
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.secondary)
            Text("SubGallery가 잠겨 있습니다")
                .font(.title3.weight(.semibold))
            Button("잠금 해제", action: unlock)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
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
