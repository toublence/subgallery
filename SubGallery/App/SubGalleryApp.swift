import AppIntents
import AppTrackingTransparency
import CloudKit
import CoreData
import CryptoKit
import FirebaseAnalytics
import FirebaseCore
import Security
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

extension Notification.Name {
    static let openReminderMedia = Notification.Name("openReminderMedia")
    static let replayOnboarding = Notification.Name("replayOnboarding")
    static let smartClassificationSuggested = Notification.Name("smartClassificationSuggested")
    static let automaticClassificationApplied = Notification.Name("automaticClassificationApplied")
    static let premiumEntitlementDidChange = Notification.Name("premiumEntitlementDidChange")
    static let premiumBackfillRequested = Notification.Name("premiumBackfillRequested")
}

enum StoreScreenshotMode {
    #if DEBUG
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-store-screenshot")
    #else
    static let isEnabled = false
    #endif

    static var screen: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-store-screen"), arguments.indices.contains(index + 1) else {
            return "library"
        }
        return arguments[index + 1]
    }

    static var searchQuery: String {
        switch AppLanguage.selected.resolvedIdentifier {
        case "de": "Berlin"
        case "es": "Madrid"
        case "fr": "Paris"
        case "ja": "東京"
        case "zh-Hans": "上海"
        case "zh-Hant": "台北"
        case "ar": "دبي"
        case "ko": "제주"
        default: "Seattle"
        }
    }
}

@MainActor
enum ReviewPromptPolicy {
    private static let successfulSaveCountKey = "review.successfulSaveCount"
    private static let activeDaysKey = "review.activeDays"
    private static let lastRequestedVersionKey = "review.lastRequestedVersion"
    private static let lastRequestedDateKey = "review.lastRequestedDate"
    private static let requestCountForVersionKey = "review.requestCountForVersion"
    // iOS itself shows at most three prompts per year and silently drops the rest,
    // so this policy only decides which moments are worth spending an attempt on —
    // it is not the rate limit. Keeping it loose costs the user nothing, while a
    // dropped attempt still burns the cooldown, which is why the window is short.
    private static let minimumSuccessfulSaves = 3
    private static let minimumActiveDays = 2
    private static let maximumRequestsPerVersion = 2
    private static let requestCooldown: TimeInterval = 30 * 24 * 60 * 60

    static func recordActiveDay() {
        guard isEligibleEnvironment else { return }
        let defaults = UserDefaults.standard
        let today = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        var days = storedActiveDays
        guard !days.contains(today) else { return }
        days.append(today)
        defaults.set(Array(days.suffix(30)), forKey: activeDaysKey)
    }

    static func recordSuccessfulSave() {
        guard isEligibleEnvironment else { return }
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: successfulSaveCountKey) + 1, forKey: successfulSaveCountKey)
    }

    static var shouldRequest: Bool {
        guard isEligibleEnvironment,
              UserDefaults.standard.bool(forKey: "onboarding.completed"),
              UserDefaults.standard.integer(forKey: successfulSaveCountKey) >= minimumSuccessfulSaves,
              storedActiveDays.count >= minimumActiveDays,
              requestsForCurrentVersion < maximumRequestsPerVersion else {
            return false
        }
        let lastRequest = UserDefaults.standard.double(forKey: lastRequestedDateKey)
        return lastRequest == 0 || Date.now.timeIntervalSince1970 - lastRequest >= requestCooldown
    }

    static func markRequested() {
        let defaults = UserDefaults.standard
        // Read the tally before stamping the version, otherwise the first request
        // on a new version would immediately look like a repeat.
        let count = requestsForCurrentVersion + 1
        defaults.set(currentVersion, forKey: lastRequestedVersionKey)
        defaults.set(count, forKey: requestCountForVersionKey)
        defaults.set(Date.now.timeIntervalSince1970, forKey: lastRequestedDateKey)
        defaults.set(0, forKey: successfulSaveCountKey)
    }

    /// Resets to zero on a version change, so a new release always starts with a
    /// fresh allowance.
    private static var requestsForCurrentVersion: Int {
        guard UserDefaults.standard.string(forKey: lastRequestedVersionKey) == currentVersion else {
            return 0
        }
        return UserDefaults.standard.integer(forKey: requestCountForVersionKey)
    }

    private static var storedActiveDays: [TimeInterval] {
        UserDefaults.standard.array(forKey: activeDaysKey)?.compactMap {
            ($0 as? NSNumber)?.doubleValue
        } ?? []
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static var isEligibleEnvironment: Bool {
        !StoreScreenshotMode.isEnabled
            && !ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var cloudEventObserver: NSObjectProtocol?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        Analytics.setAnalyticsCollectionEnabled(true)
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        cloudEventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard PremiumAccess.isActive,
                  UserDefaults.standard.bool(forKey: "icloud.active"),
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
    @State private var captureContext: CaptureContext = .general
    @State private var obscuresContent = false
    @State private var isUnlocked = false
    @State private var deepLink: MediaDeepLink?
    @State private var requestedLibraryDestination: AlbumDestination?
    @State private var requestedOnboardingAction: OnboardingAction?
    @State private var isRequestingTrackingAuthorization = false
    @State private var didApplyInitialStartScreen = false
    @State private var showsOnboarding = !StoreScreenshotMode.isEnabled
        && !UserDefaults.standard.bool(forKey: "onboarding.completed")
    @AppStorage("privacy.pinLock") private var pinLock = false
    @AppStorage("privacy.appSwitcherProtection") private var appSwitcherProtection = true
    @AppStorage("app.language") private var appLanguageRaw = AppLanguage.system.rawValue
    @AppStorage("app.startScreen") private var startScreenRaw = AppStartScreen.library.rawValue
    @AppStorage("app.lastScreen") private var lastScreenRaw = AppStartScreen.library.rawValue
    @AppStorage("defaults.cameraDestination") private var defaultCameraDestination = StorageDestination.camera.token
    @AppStorage("camera.destinationAlbumID") private var currentCameraDestination = StorageDestination.camera.token
    @AppStorage("onboarding.completed") private var onboardingCompleted = false

    private let dataStore = DataStoreBootstrap.make(premiumActive: PremiumAccess.cachedIsActive)

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let errorMessage = dataStore.errorMessage {
                    DataStoreErrorView(message: errorMessage)
                } else if StoreScreenshotMode.isEnabled && StoreScreenshotMode.screen == "camera" {
                    CameraView(context: captureContext) { destination in
                        requestedLibraryDestination = destination
                    }
                } else if StoreScreenshotMode.isEnabled && StoreScreenshotMode.screen == "batch" {
                    NavigationStack {
                        AlbumView(destination: .smart(.all), isCameraPresented: $isCameraPresented)
                    }
                } else if StoreScreenshotMode.isEnabled && StoreScreenshotMode.screen == "albums" {
                    StoreAlbumScreenshotHost(isCameraPresented: $isCameraPresented)
                } else {
                    LibraryView(
                        isCameraPresented: $isCameraPresented,
                        captureContext: $captureContext,
                        requestedDestination: $requestedLibraryDestination,
                        requestedOnboardingAction: $requestedOnboardingAction
                    )
                        .blur(radius: obscuresContent ? 28 : 0)
                        .allowsHitTesting(!obscuresContent)
                }

                if pinLock && !isUnlocked {
                    PINLockView(unlock: unlock)
                }

                if StoreScreenshotMode.isEnabled && StoreScreenshotMode.screen == "security" {
                    PINLockView { _ in false }
                }
            }
            .environment(\.locale, (AppLanguage(rawValue: appLanguageRaw) ?? .system).locale)
            .environment(\.layoutDirection, (AppLanguage(rawValue: appLanguageRaw) ?? .system).resolvedIdentifier == "ar" ? .rightToLeft : .leftToRight)
            .fullScreenCover(isPresented: $showsOnboarding, onDismiss: performOnboardingAction) {
                OnboardingView(canDismiss: onboardingCompleted) { action in
                    requestTrackingAuthorization(after: action)
                }
                .environment(\.locale, (AppLanguage(rawValue: appLanguageRaw) ?? .system).locale)
            }
            .fullScreenCover(isPresented: $isCameraPresented) {
                CameraView(context: captureContext) { destination in
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
                    captureContext = .general
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
            .onReceive(NotificationCenter.default.publisher(for: .replayOnboarding)) { _ in
                showsOnboarding = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .premiumEntitlementDidChange)) { notification in
                guard let isActive = notification.userInfo?["isActive"] as? Bool else { return }
                Task { await handlePremiumEntitlementChange(isActive: isActive) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .premiumBackfillRequested)) { _ in
                Task {
                    guard PurchaseManager.shared.isPremium, dataStore.errorMessage == nil else { return }
                    await PremiumBackfillService.run(in: dataStore.container.mainContext)
                }
            }
            .task {
                if StoreScreenshotMode.isEnabled {
                    #if DEBUG
                    PurchaseManager.shared.configureForTesting(
                        productIDs: ProcessInfo.processInfo.arguments.contains("-store-premium")
                            ? [PurchaseManager.lifetimeID]
                            : []
                    )
                    #endif
                    isUnlocked = true
                    CapturePresetService.seedBuiltIns(in: dataStore.container.mainContext)
                    await prepareStoreScreenshotFixture()
                    applyStoreScreenshotRoute()
                    return
                }
                ReviewPromptPolicy.recordActiveDay()
                await PurchaseManager.shared.refreshEntitlements()
                updateCloudKitSessionStatus()
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
                    DefaultAlbumMigration.run(in: dataStore.container.mainContext)
                    // Free of charge and independent of the premium backfill: a
                    // receipt showing the wrong total is a defect, not a locked feature.
                    ReceiptAmountMigration.run(in: dataStore.container.mainContext)
                    if PurchaseManager.shared.isPremium {
                        await PremiumBackfillService.run(in: dataStore.container.mainContext)
                    }
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
                    ReviewPromptPolicy.recordActiveDay()
                    obscuresContent = false
                    openPendingReminderIfNeeded()
                    if dataStore.errorMessage == nil {
                        Task {
                            await PurchaseManager.shared.refreshEntitlements()
                            updateCloudKitSessionStatus()
                            if PurchaseManager.shared.isPremium && dataStore.usesCloudKit {
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

    @MainActor
    private func handlePremiumEntitlementChange(isActive: Bool) async {
        updateCloudKitSessionStatus()
        guard isActive, dataStore.errorMessage == nil else { return }
        await PremiumBackfillService.run(in: dataStore.container.mainContext)
    }

    @MainActor
    private func updateCloudKitSessionStatus() {
        let shouldUseCloudKit = DataStoreBootstrap.shouldUseCloudKit(
            premiumActive: PurchaseManager.shared.isPremium,
            syncRequested: UserDefaults.standard.bool(forKey: "icloud.sync")
        )
        guard dataStore.usesCloudKit != shouldUseCloudKit else { return }
        UserDefaults.standard.set("restartRequired", forKey: "icloud.syncStatus")
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
        guard onboardingCompleted || StoreScreenshotMode.isEnabled else { return }
        didApplyInitialStartScreen = true
        let start = AppStartScreen(rawValue: startScreenRaw) ?? .library
        let opensCamera = start == .camera || (start == .last && lastScreenRaw == AppStartScreen.camera.rawValue)
        if opensCamera {
            currentCameraDestination = defaultCameraDestination
            captureContext = .general
        }
        isCameraPresented = opensCamera
    }

    private func performOnboardingAction() {
        guard let action = requestedOnboardingAction else { return }
        didApplyInitialStartScreen = true
        switch action {
        case .camera:
            currentCameraDestination = defaultCameraDestination
            captureContext = .general
            isCameraPresented = true
            requestedOnboardingAction = nil
        case .importPhotos:
            break
        case .library:
            requestedOnboardingAction = nil
        }
    }

    private func requestTrackingAuthorization(after action: OnboardingAction) {
        guard !isRequestingTrackingAuthorization else { return }
        requestedOnboardingAction = action

        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else {
            finishOnboardingAfterTrackingRequest()
            return
        }

        isRequestingTrackingAuthorization = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            ATTrackingManager.requestTrackingAuthorization { _ in
                DispatchQueue.main.async {
                    finishOnboardingAfterTrackingRequest()
                }
            }
        }
    }

    private func finishOnboardingAfterTrackingRequest() {
        isRequestingTrackingAuthorization = false
        onboardingCompleted = true
        showsOnboarding = false
    }

    @MainActor
    private func applyStoreScreenshotRoute() {
        switch StoreScreenshotMode.screen {
        case "camera":
            isCameraPresented = true
        case "albums":
            requestedLibraryDestination = .template(.travel)
        case "batch":
            requestedLibraryDestination = .smart(.all)
        case "retention":
            requestedLibraryDestination = .smart(.temporary)
        default:
            break
        }
    }

    @MainActor
    private func prepareStoreScreenshotFixture() async {
        let context = dataStore.container.mainContext
        let calendar = Calendar(identifier: .gregorian)
        let baseDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 10)) ?? .now
        let names = localizedStoreFixtureNames()
        let fixtures: [(String, UIColor, UIColor, CapturePurpose, MediaSource, RetentionPolicy, Bool)] = [
            (names[0], .systemTeal, .systemBlue, .travel, .camera, .forever, false),
            (names[1], .systemGreen, .systemTeal, .travel, .camera, .forever, false),
            (names[2], .systemOrange, .systemPink, .travel, .camera, .forever, false),
            (names[3], .systemBrown, .systemOrange, .receipt, .camera, .thirtyDays, false),
            (names[4], .systemPurple, .systemIndigo, .document, .files, .untilComplete, false),
            (names[5], .systemGray, .systemPurple, .document, .photos, .today, false),
            (names[6], .systemMint, .systemGreen, .travel, .camera, .forever, false),
            (names[7], .systemPink, .systemPurple, .document, .photos, .sevenDays, false)
        ]

        for (index, fixture) in fixtures.enumerated() {
            let image = storeFixtureImage(title: fixture.0, primary: fixture.1, secondary: fixture.2, index: index)
            guard let data = image.jpegData(compressionQuality: 0.94),
                  let stored = try? await MediaStorage.shared.store(
                    data: data,
                    type: .jpeg,
                    preferredName: "__StoreShot_\(index + 1).jpg"
                  ) else { continue }
            let item = MediaItem(
                kind: .photo,
                source: fixture.4,
                localPath: stored.relativePath,
                thumbnailPath: stored.thumbnailRelativePath,
                fileName: "\(fixture.0).jpg",
                createdAt: calendar.date(byAdding: .hour, value: index * 7, to: baseDate) ?? baseDate,
                fileSize: stored.fileSize,
                width: stored.width,
                height: stored.height
            )
            item.purpose = fixture.3
            item.isPinned = fixture.6
            RetentionService.apply(fixture.5, to: item)
            item.ocrStatus = .completed
            item.recognizedText = fixture.0
            context.insert(item)
        }
        try? context.save()
    }

    private func localizedStoreFixtureNames() -> [String] {
        switch AppLanguage.selected.resolvedIdentifier {
        case "de":
            ["Berlin Reise", "Berlin Mitte", "Berlin Abend", "Café-Beleg", "Konferenzinfo", "Büronotiz", "Wochenendspaziergang", "Konzertinfo"]
        case "es":
            ["Viaje a Madrid", "Madrid Centro", "Atardecer en Madrid", "Recibo de cafetería", "Guía de conferencia", "Nota de oficina", "Paseo del fin de semana", "Entrada de concierto"]
        case "fr":
            ["Voyage à Paris", "Paris Centre", "Soirée à Paris", "Reçu du café", "Guide de conférence", "Note de bureau", "Promenade du week-end", "Billet de concert"]
        case "ja":
            ["東京旅行", "東京駅", "東京の夕景", "カフェのレシート", "会議案内", "仕事メモ", "週末の散歩", "コンサート案内"]
        case "zh-Hans":
            ["上海旅行", "上海市中心", "上海夜景", "咖啡店收据", "会议指南", "工作备忘", "周末散步", "演出门票"]
        case "zh-Hant":
            ["台北旅行", "台北車站", "台北夜景", "咖啡店收據", "會議指南", "工作備忘", "週末散步", "演唱會門票"]
        case "ar":
            ["رحلة دبي", "وسط دبي", "مساء دبي", "إيصال المقهى", "دليل المؤتمر", "ملاحظة العمل", "نزهة نهاية الأسبوع", "تذكرة الحفل"]
        case "ko":
            ["제주 바다", "제주 한라산", "제주 노을", "카페 영수증", "회의 안내", "업무 메모", "주말 산책", "공연 안내"]
        default:
            ["Seattle Trip", "Downtown Seattle", "Seattle Sunset", "Coffee Receipt", "Conference Guide", "Office Note", "Weekend Walk", "Concert Ticket"]
        }
    }

    private func storeFixtureImage(
        title: String,
        primary: UIColor,
        secondary: UIColor,
        index: Int
    ) -> UIImage {
        let size = CGSize(width: 1200, height: 1500)
        return UIGraphicsImageRenderer(size: size).image { renderer in
            let context = renderer.cgContext
            let colors = [primary.cgColor, secondary.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
            UIColor.white.withAlphaComponent(0.16).setFill()
            for offset in 0..<5 {
                let diameter = CGFloat(360 + offset * 90)
                let x = CGFloat((index * 137 + offset * 211) % 900) - 140
                let y = CGFloat((index * 251 + offset * 173) % 1200) - 120
                context.fillEllipse(in: CGRect(x: x, y: y, width: diameter, height: diameter))
            }
            let symbolNames = ["airplane", "mountain.2.fill", "sun.horizon.fill", "receipt.fill", "doc.text.fill"]
            let symbol = UIImage(systemName: symbolNames[index % symbolNames.count])?
                .withTintColor(.white.withAlphaComponent(0.9), renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: 430, y: 470, width: 340, height: 340))
            NSString(string: title).draw(
                in: CGRect(x: 90, y: 1250, width: 1020, height: 150),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 78, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
            )
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

    @MainActor
    private func reconcileCloudMediaAssets() async {
        guard PremiumAccess.isActive, dataStore.usesCloudKit else { return }
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
        guard PremiumAccess.isActive else { return }
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

private struct StoreAlbumScreenshotHost: View {
    @Binding var isCameraPresented: Bool

    var body: some View {
        NavigationStack {
            AlbumView(
                destination: .template(.travel),
                isCameraPresented: $isCameraPresented
            )
        }
    }
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

    static func shouldUseCloudKit(premiumActive: Bool, syncRequested: Bool) -> Bool {
        premiumActive && syncRequested
    }

    static func make(premiumActive: Bool) -> DataStoreBootstrap {
        let schema = Schema([MediaItem.self, Album.self, CapturePreset.self, Document.self])
        if StoreScreenshotMode.isEnabled {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            let container = try! ModelContainer(for: schema, configurations: [configuration])
            return DataStoreBootstrap(container: container, errorMessage: nil, usesCloudKit: false)
        }
        let cloudRequested = shouldUseCloudKit(
            premiumActive: premiumActive,
            syncRequested: UserDefaults.standard.bool(forKey: "icloud.sync")
        )
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
