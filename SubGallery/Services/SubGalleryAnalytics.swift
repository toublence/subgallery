import FirebaseAnalytics
import Foundation

/// Product analytics has one privacy-reviewed entry point. Callers only pass
/// fixed enums, counts and booleans; user content never crosses this boundary.
enum SubGalleryAnalytics {
    enum Source: String {
        case camera, photos, files, documentScan = "document_scan", qrBuilder = "qr_builder", exif
    }

    enum Destination: String {
        case general, temporary, userAlbum = "user_album", receipt, document, qr, travel
    }

    enum Template: String {
        case receipt, document, qr, travel

        init?(_ purpose: CapturePurpose) {
            guard [.receipt, .document, .qr, .travel].contains(purpose) else { return nil }
            self.init(rawValue: purpose.rawValue)
        }
    }

    enum AddedMediaKind: String { case photo, video, mixed }
    enum AddFailureReason: String {
        case permissionDenied = "permission_denied", storageFailed = "storage_failed"
        case decodeFailed = "decode_failed", unsupported, saveFailed = "save_failed"
        case locationUnavailable = "location_unavailable", unknown
    }
    enum OnboardingContext: String { case firstRun = "first_run", settings }
    enum OnboardingPage: String, CaseIterable { case separate, workflows, outputs, automation }
    enum OnboardingAction: String { case camera, `import`, library }
    enum MeaningfulAction: String {
        case mediaAdd = "media_add", mediaOpen = "media_open", search
        case templateOpen = "template_open", complete, export, albumOpen = "album_open"
    }
    enum ReceiptResult: String { case success, partial, unreadable }
    enum ReportRange: String { case thisMonth = "this_month", lastMonth = "last_month", threeMonths = "three_months", all, custom }
    enum QRType: String { case url, wifi, contact, phone, email, location, text, unknown }
    enum BuilderFailureReason: String { case invalidInput = "invalid_input", renderFailed = "render_failed", saveFailed = "save_failed", unknown }
    enum TravelFailureReason: String { case permissionDenied = "permission_denied", locationUnavailable = "location_unavailable", metadataMissing = "metadata_missing", unknown }
    enum AlbumType: String { case user, smart }
    enum AutomationLevel: String { case basic, advanced }
    enum AutomationRule: String { case retention, ocr, location, pin, completion, cleanup, multiCondition = "multi_condition" }
    enum ExportDestination: String { case photos, files, share }

    private static let firstRunStartedAtKey = "analytics.firstRunStartedAt"
    private static let firstValueReachedKey = "analytics.firstValueReached"
    private static let successfulMediaAddCountKey = "analytics.successfulMediaAddCount"

    #if DEBUG
    /// Unit tests inspect sanitized output here; Firebase itself is not mocked.
    static var eventObserver: ((String, [String: Any]) -> Void)?
    #endif

    static var isEnabled: Bool {
        shouldRecord(
            arguments: ProcessInfo.processInfo.arguments,
            storeScreenshot: StoreScreenshotMode.isEnabled
        )
    }

    static func shouldRecord(arguments: [String], storeScreenshot: Bool) -> Bool {
        !storeScreenshot && !arguments.contains("-ui-testing")
    }

    static func prepareFirstRunTiming(defaults: UserDefaults = .standard, now: Date = .now) {
        guard isEnabled, defaults.object(forKey: firstRunStartedAtKey) == nil else { return }
        defaults.set(now.timeIntervalSince1970, forKey: firstRunStartedAtKey)
    }

    static func onboardingStart(_ context: OnboardingContext) {
        prepareFirstRunTiming()
        log("onboarding_start", ["context": context.rawValue])
    }

    static func onboardingPageView(_ page: OnboardingPage, index: Int, context: OnboardingContext) {
        log("onboarding_page_view", [
            "context": context.rawValue,
            "page_index": index,
            "page_id": page.rawValue
        ])
    }

    static func onboardingComplete(_ action: OnboardingAction, context: OnboardingContext) {
        log("onboarding_complete", ["context": context.rawValue, "action": action.rawValue])
    }

    static func mediaAddStart(source: Source, destination: Destination, template: Template?, kind: AddedMediaKind) {
        prepareFirstRunTiming()
        log("media_add_start", mediaParameters(source: source, destination: destination, template: template, kind: kind))
    }

    static func mediaAddSuccess(
        source: Source,
        destination: Destination,
        template: Template?,
        kind: AddedMediaKind,
        defaults: UserDefaults = .standard,
        now: Date = .now
    ) {
        let parameters = mediaParameters(source: source, destination: destination, template: template, kind: kind)
        log("media_add_success", parameters)
        meaningfulAction(.mediaAdd)

        prepareFirstRunTiming(defaults: defaults, now: now)
        let count = defaults.integer(forKey: successfulMediaAddCountKey) + 1
        defaults.set(count, forKey: successfulMediaAddCountKey)
        let elapsed = elapsedSeconds(defaults: defaults, now: now)

        if !defaults.bool(forKey: firstValueReachedKey) {
            defaults.set(true, forKey: firstValueReachedKey)
            log("first_value_reached", parameters.merging(["elapsed_seconds": elapsed]) { current, _ in current })
        }
        if count == 2 {
            log("activation_complete", ["elapsed_seconds": elapsed])
        }
    }

    static func mediaAddFailed(source: Source, destination: Destination, template: Template?, kind: AddedMediaKind, reason: AddFailureReason) {
        var parameters = mediaParameters(source: source, destination: destination, template: template, kind: kind)
        parameters["reason"] = reason.rawValue
        log("media_add_failed", parameters)
    }

    static func meaningfulAction(_ action: MeaningfulAction) {
        log("meaningful_action", ["action": action.rawValue])
    }

    static func templateOpen(_ template: Template) {
        log("template_open", ["template": template.rawValue])
        meaningfulAction(.templateOpen)
    }

    static func searchPerformed(resultCount: Int) {
        log("search_performed", ["result_bucket": countBucket(resultCount)])
        meaningfulAction(.search)
    }

    static func receiptAnalysisComplete(result: ReceiptResult, merchantDetected: Bool, amountDetected: Bool, dateDetected: Bool) {
        log("receipt_analysis_complete", [
            "result": result.rawValue,
            "merchant_detected": merchantDetected,
            "amount_detected": amountDetected,
            "date_detected": dateDetected
        ])
    }

    static func receiptReportOpen() { log("receipt_report_open") }
    static func receiptReportRendered(range: ReportRange) {
        log("receipt_report_rendered", ["range": range.rawValue, "has_data": true])
    }

    static func documentScanSuccess(pageCount: Int) {
        log("document_scan_success", ["page_count_bucket": pageCountBucket(pageCount)])
    }
    static func pdfCreateSuccess(pageCount: Int) {
        log("pdf_create_success", ["page_count_bucket": pageCountBucket(pageCount)])
    }
    static func pdfCreateFailed(_ reason: BuilderFailureReason) { log("pdf_create_failed", ["reason": reason.rawValue]) }
    static func pdfOpen() { log("pdf_open") }

    static func qrDetected(_ type: QRType) { log("qr_detected", ["qr_type": type.rawValue]) }
    static func qrBuilderOpen() { log("qr_builder_open") }
    static func qrCreateSuccess(_ type: QRType) { log("qr_create_success", ["qr_type": type.rawValue]) }
    static func qrCreateFailed(_ reason: BuilderFailureReason) { log("qr_create_failed", ["reason": reason.rawValue]) }

    static func travelLocationSaved(source: Source) { log("travel_location_saved", ["source": source.rawValue]) }
    static func travelLocationFailed(_ reason: TravelFailureReason) { log("travel_location_failed", ["reason": reason.rawValue]) }
    static func travelMapOpen() { log("travel_map_open") }
    static func travelMapRendered() { log("travel_map_rendered") }

    static func albumCreated() { log("album_created") }
    static func albumOpen(_ type: AlbumType) {
        log("album_open", ["album_type": type.rawValue])
        meaningfulAction(.albumOpen)
    }
    static func albumAutomationOpen() { log("album_automation_open") }
    static func albumAutomationChanged(level: AutomationLevel, rule: AutomationRule) {
        log("album_automation_changed", ["level": level.rawValue, "rule_type": rule.rawValue])
    }

    static func mediaOpened() { meaningfulAction(.mediaOpen) }
    static func mediaCompleted() {
        log("media_completed")
        meaningfulAction(.complete)
    }
    static func mediaRestored() { log("media_restored") }
    static func mediaExported(destination: ExportDestination, metadataRemoved: Bool) {
        log("media_exported", ["destination": destination.rawValue, "metadata_removed": metadataRemoved])
        meaningfulAction(.export)
    }

    static func premiumPlanSelected(plan: String, entryPoint: String) {
        log("premium_plan_selected", ["plan": plan, "entry_point": entryPoint])
    }
    static func premiumPaywallDismissed(entryPoint: String, selectedPlan: String) {
        log("premium_paywall_dismissed", ["entry_point": entryPoint, "selected_plan": selectedPlan])
    }
    static func updatePremiumUserProperty(isPremium: Bool) {
        guard isEnabled else { return }
        Analytics.setUserProperty(isPremium ? "premium" : "free", forName: "premium_status")
    }

    /// Preserves historical Premium event names while routing them through the
    /// same environment guard and privacy boundary as all new product events.
    static func logExisting(_ name: String, parameters: [String: Any] = [:]) {
        log(name, parameters)
    }

    static func qrType(_ contentType: QRContentType) -> QRType {
        switch contentType {
        case .url: .url
        case .wifi: .wifi
        case .contact: .contact
        case .phone, .sms: .phone
        case .email: .email
        case .location: .location
        case .text: .text
        case .unknown: .unknown
        }
    }

    static func qrType(_ kind: QRBuilderKind) -> QRType {
        QRType(rawValue: kind.rawValue) ?? .unknown
    }

    private static func log(_ name: String, _ parameters: [String: Any] = [:]) {
        guard isEnabled else { return }
        var safeParameters = parameters
        safeParameters["premium_status"] = PremiumAccess.isActive ? "premium" : "free"
        #if DEBUG
        eventObserver?(name, safeParameters)
        #endif
        Analytics.logEvent(name, parameters: safeParameters)
    }

    private static func mediaParameters(source: Source, destination: Destination, template: Template?, kind: AddedMediaKind) -> [String: Any] {
        [
            "source": source.rawValue,
            "destination": destination.rawValue,
            "template": template?.rawValue ?? "none",
            "media_kind": kind.rawValue
        ]
    }

    private static func elapsedSeconds(defaults: UserDefaults, now: Date) -> Int {
        let started = defaults.double(forKey: firstRunStartedAtKey)
        return max(0, Int(now.timeIntervalSince1970 - started))
    }

    private static func countBucket(_ count: Int) -> String {
        switch count { case 0: "0"; case 1: "1"; case 2...5: "2_5"; default: "6_plus" }
    }

    private static func pageCountBucket(_ count: Int) -> String {
        switch count { case ...1: "1"; case 2...5: "2_5"; default: "6_plus" }
    }
}
