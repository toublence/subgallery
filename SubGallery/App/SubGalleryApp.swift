import AppIntents
import LocalAuthentication
import SwiftData
import SwiftUI

@main
struct SubGalleryApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isCameraPresented = false
    @State private var obscuresContent = false
    @State private var isUnlocked = false
    @AppStorage("privacy.biometricLock") private var biometricLock = false
    @AppStorage("privacy.appSwitcherProtection") private var appSwitcherProtection = true

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
            .fullScreenCover(isPresented: $isCameraPresented) {
                CameraView()
            }
            .onOpenURL { url in
                if url.host == "capture" { isCameraPresented = true }
            }
            .task {
                if dataStore.errorMessage == nil {
                    await performExpirationSweep()
                }
                if biometricLock { authenticate() } else { isUnlocked = true }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    obscuresContent = false
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
            DispatchQueue.main.async { isUnlocked = success }
        }
    }

    @MainActor
    private func performExpirationSweep() async {
        let context = dataStore.container.mainContext
        let now = Date.now
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        for item in items where item.deletedAt == nil && (item.expirationDate.map { $0 <= now } ?? false) {
            item.deletedAt = now
            item.expirationDate = nil
        }
        let purgeBefore = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        for item in items where (item.deletedAt ?? .distantFuture) < purgeBefore {
            try? await MediaStorage.shared.remove(item)
            context.delete(item)
        }
        try? context.save()
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
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
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
