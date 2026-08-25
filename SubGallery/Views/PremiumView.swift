import FirebaseAnalytics
import StoreKit
import SwiftUI

enum PremiumAccess {
    private static let entitlementKey = "premium.active"
    private static var verifiedActive: Bool?

    static var isActive: Bool {
        verifiedActive == true
    }

    static var cachedIsActive: Bool {
        UserDefaults.standard.bool(forKey: entitlementKey)
    }

    static func updateVerified(isActive: Bool) {
        verifiedActive = isActive
        let defaults = UserDefaults.standard
        defaults.set(isActive, forKey: entitlementKey)
        guard !isActive else { return }

        defaults.set(false, forKey: "privacy.stripMetadata")
        defaults.set(false, forKey: "icloud.sync")
        defaults.set(
            defaults.bool(forKey: "icloud.active") ? "restartRequired" : "idle",
            forKey: "icloud.syncStatus"
        )
    }

    #if DEBUG
    static func configureForTesting(isActive: Bool) {
        updateVerified(isActive: isActive)
    }
    #endif
}

@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()

    static let monthlyID = "com.namslab.subgallery.premium.monthly"
    static let yearlyID = "com.namslab.subgallery.premium.yearly"
    static let lifetimeID = "com.namslab.subgallery.premium.lifetime"
    /// Only subscriptions are offered. Lifetime remains in entitlement lookup so
    /// existing owners keep Premium after it disappears from the paywall.
    static let productIDs = [monthlyID, yearlyID]
    static let entitlementProductIDs = [monthlyID, yearlyID, lifetimeID]

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published var message: String?

    var isPremium: Bool { !purchasedProductIDs.isEmpty }
    var canMakePayments: Bool { AppStore.canMakePayments }

    private var hasLoadedProducts = false
    private var transactionUpdates: Task<Void, Never>?

    private init() {
        transactionUpdates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result,
                   Self.entitlementProductIDs.contains(transaction.productID) {
                    await transaction.finish()
                    await self.refreshEntitlements()
                }
            }
        }
    }

    func prepare() async {
        await refreshEntitlements()
        guard !hasLoadedProducts else { return }

        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            products = fetched.sorted { lhs, rhs in
                (Self.productIDs.firstIndex(of: lhs.id) ?? .max)
                    < (Self.productIDs.firstIndex(of: rhs.id) ?? .max)
            }
            hasLoadedProducts = true
            if products.isEmpty {
                message = L10n.text("App Store에서 상품을 찾을 수 없습니다.")
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func reloadProducts() async {
        hasLoadedProducts = false
        await prepare()
    }

    func purchase(_ product: Product) async {
        guard canMakePayments, !isPurchasing else { return }
        PremiumAnalytics.purchaseStarted(productID: product.id)
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    message = L10n.text("구매를 확인할 수 없습니다.")
                    return
                }
                await transaction.finish()
                await refreshEntitlements()
                if isPremium {
                    PremiumAnalytics.purchaseSucceeded(productID: product.id)
                    NotificationCenter.default.post(name: .premiumBackfillRequested, object: nil)
                }
                message = L10n.text("구매가 완료되었습니다.")
            case .pending:
                message = L10n.text("구매 승인 대기 중입니다.")
            case .userCancelled:
                break
            @unknown default:
                message = L10n.text("구매를 완료할 수 없습니다.")
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if isPremium {
                PremiumAnalytics.restoreSucceeded()
                NotificationCenter.default.post(name: .premiumBackfillRequested, object: nil)
            }
            message = isPremium
                ? L10n.text("구매가 복원되었습니다.")
                : L10n.text("복원할 구매가 없습니다.")
        } catch {
            message = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        let wasPremium = PremiumAccess.isActive
        var activeIDs: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.entitlementProductIDs.contains(transaction.productID) else { continue }
            activeIDs.insert(transaction.productID)
        }
        purchasedProductIDs = activeIDs
        PremiumAccess.updateVerified(isActive: isPremium)
        if wasPremium != isPremium {
            NotificationCenter.default.post(
                name: .premiumEntitlementDidChange,
                object: nil,
                userInfo: ["isActive": isPremium]
            )
        }
    }

    #if DEBUG
    func configureForTesting(productIDs: Set<String>) {
        let wasPremium = PremiumAccess.isActive
        purchasedProductIDs = productIDs.intersection(Set(Self.entitlementProductIDs))
        PremiumAccess.configureForTesting(isActive: isPremium)
        if wasPremium != isPremium {
            NotificationCenter.default.post(
                name: .premiumEntitlementDidChange,
                object: nil,
                userInfo: ["isActive": isPremium]
            )
        }
    }
    #endif
}

enum PremiumEntryPoint: String {
    case general
    case receiptReport
    case travelMap
    case documentBuilder
    case qrBuilder
    case albumAutomation
    case cleanupCenter
    case iCloudSync
    case capturePreset
    case privacyExport
    case ocrSmartActions

    var featureID: PremiumFeatureID? {
        switch self {
        case .general: nil
        case .receiptReport: .receiptReport
        case .travelMap: .travelMap
        case .documentBuilder: .documentBuilder
        case .qrBuilder: .qrBuilder
        case .albumAutomation: .advancedAlbumAutomation
        case .cleanupCenter: .cleanupCenter
        case .iCloudSync: .iCloudSync
        case .capturePreset: .capturePresets
        case .privacyExport: .privacyExport
        case .ocrSmartActions: .ocrSmartActions
        }
    }
}

enum PremiumFeatureID: String, CaseIterable, Hashable {
    case receiptReport
    case travelMap
    case documentBuilder
    case qrBuilder
    case advancedAlbumAutomation
    case cleanupCenter
    case iCloudSync
    case capturePresets
    case privacyExport
    case ocrSmartActions
}

enum PremiumAccessPolicy: Equatable {
    case free
    case trial(limit: Int)
    case premium
    case freeBasicPremiumAdvanced

    var paywallCaption: String? {
        switch self {
        case .free: nil
        case .trial(let limit): L10n.format("Free %d회 · Premium 무제한", limit)
        case .premium: L10n.text("Premium 포함")
        case .freeBasicPremiumAdvanced: L10n.text("Free 기본 · Premium 고급")
        }
    }
}

struct PremiumFeatureDescriptor: Identifiable {
    let id: PremiumFeatureID
    let symbol: String
    let titleKey: String
    let detailKey: String
    let accessPolicy: PremiumAccessPolicy
}

enum FeatureAvailability: Equatable {
    case included
    case unavailable
    case trial(Int)
    case basic
    case unlimited
    case advanced

    var title: String {
        switch self {
        case .included: L10n.text("포함")
        case .unavailable: "—"
        case .trial(let limit): L10n.format("%d회", limit)
        case .basic: L10n.text("기본")
        case .unlimited: L10n.text("무제한")
        case .advanced: L10n.text("고급")
        }
    }
}

struct PlanComparisonItem: Identifiable {
    let id: String
    let titleKey: String
    let free: FeatureAvailability
    let premium: FeatureAvailability
}

struct PremiumBenefitGroup: Identifiable {
    let id: String
    let featureIDs: Set<PremiumFeatureID>
    let symbol: String
    let titleKey: String
    let detailKey: String
}

private struct PremiumPaywallBenefit: Identifiable {
    let id: String
    let symbol: String
    let titleKey: String
    let detailKey: String
    let accessCaption: String?
}

/// Product policy source of truth. Trial counters keep their existing Keychain
/// stores, while limits, paywall copy and the comparison table read from here.
enum PremiumFeatureCatalog {
    static func trialLimit(for id: PremiumFeatureID) -> Int {
        switch feature(id).accessPolicy {
        case .trial(let limit): limit
        default: 0
        }
    }

    static func feature(_ id: PremiumFeatureID) -> PremiumFeatureDescriptor {
        switch id {
        case .receiptReport:
            PremiumFeatureDescriptor(
                id: id, symbol: "chart.bar.xaxis", titleKey: "지출 리포트 무제한",
                detailKey: "영수증으로 지출 흐름과 결제 패턴을 언제든 다시 확인합니다.",
                accessPolicy: .trial(limit: 3)
            )
        case .travelMap:
            PremiumFeatureDescriptor(
                id: id, symbol: "map.fill", titleKey: "여행 지도 무제한",
                detailKey: "사진 위치와 방문 지역, 여행 타임라인을 연도별로 계속 확인합니다.",
                accessPolicy: .trial(limit: 5)
            )
        case .documentBuilder:
            PremiumFeatureDescriptor(
                id: id, symbol: "doc.badge.plus", titleKey: "문서 만들기 무제한",
                detailKey: "여러 장의 문서 사진을 정리해 하나의 PDF로 만들고, OCR로 문서 내용을 인식합니다.",
                accessPolicy: .trial(limit: 3)
            )
        case .qrBuilder:
            PremiumFeatureDescriptor(
                id: id, symbol: "qrcode", titleKey: "QR 만들기 무제한",
                detailKey: "Wi-Fi, 연락처, 링크를 QR로 만들어 보관하고 바로 보여줍니다.",
                accessPolicy: .trial(limit: 5)
            )
        case .advancedAlbumAutomation:
            PremiumFeatureDescriptor(
                id: id, symbol: "slider.horizontal.3", titleKey: "고급 앨범 자동화",
                detailKey: "완료된 사진을 자동 정리하고 정리가 필요한 사진을 앨범마다 확인합니다.",
                accessPolicy: .freeBasicPremiumAdvanced
            )
        case .cleanupCenter:
            PremiumFeatureDescriptor(
                id: id, symbol: "tray.full.fill", titleKey: "정리 센터",
                detailKey: "만료 예정과 완료 대기 사진을 한곳에서 빠르게 정리합니다.",
                accessPolicy: .premium
            )
        case .iCloudSync:
            PremiumFeatureDescriptor(
                id: id, symbol: "icloud", titleKey: "iCloud 동기화",
                detailKey: "사진과 동영상을 같은 Apple 계정의 기기 사이에서 동기화합니다.",
                accessPolicy: .premium
            )
        case .capturePresets:
            PremiumFeatureDescriptor(
                id: id, symbol: "camera.filters", titleKey: "고급 촬영 프리셋",
                detailKey: "사용자 정의 저장 위치와 보관·분석 설정을 촬영 프리셋으로 만듭니다.",
                accessPolicy: .premium
            )
        case .privacyExport:
            PremiumFeatureDescriptor(
                id: id, symbol: "shield.lefthalf.filled", titleKey: "개인정보 보호 내보내기",
                detailKey: "위치와 기기 정보를 제거한 사본을 안전하게 내보냅니다.",
                accessPolicy: .premium
            )
        case .ocrSmartActions:
            PremiumFeatureDescriptor(
                id: id, symbol: "text.viewfinder", titleKey: "OCR 스마트 작업",
                detailKey: "사진 속 날짜, 주소와 링크를 인식해 바로 필요한 작업을 실행합니다.",
                accessPolicy: .premium
            )
        }
    }

    static let generalBenefitGroups: [PremiumBenefitGroup] = [
        PremiumBenefitGroup(
            id: "templateTools",
            featureIDs: [.receiptReport, .travelMap, .documentBuilder, .qrBuilder],
            symbol: "square.grid.2x2.fill",
            titleKey: "템플릿 기능 무제한",
            detailKey: "지출 리포트 · 여행 지도 · 문서 만들기 · QR 만들기를 제한 없이 사용하세요."
        ),
        PremiumBenefitGroup(
            id: "albumAutomation",
            featureIDs: [.advancedAlbumAutomation],
            symbol: "slider.horizontal.3",
            titleKey: "고급 앨범 자동화",
            detailKey: "사용자가 만든 앨범도 보관·완료·정리 규칙에 따라 자동으로 관리합니다."
        ),
        PremiumBenefitGroup(
            id: "smartManagement",
            featureIDs: [.cleanupCenter, .ocrSmartActions],
            symbol: "wand.and.stars",
            titleKey: "Smart 관리",
            detailKey: "정리 센터와 사진 속 스마트 작업으로 관리할 사진만 빠르게 확인합니다."
        ),
        PremiumBenefitGroup(
            id: "advancedTools",
            featureIDs: [.iCloudSync, .capturePresets, .privacyExport],
            symbol: "icloud.and.arrow.up",
            titleKey: "동기화와 고급 도구",
            detailKey: "iCloud, 사용자 촬영 프리셋과 개인정보 보호 내보내기를 사용합니다."
        )
    ]

    static let comparisonItems: [PlanComparisonItem] = [
        PlanComparisonItem(id: "separateStorage", titleKey: "사진 앱과 별도 보관", free: .included, premium: .included),
        PlanComparisonItem(id: "captureImport", titleKey: "사진/동영상 촬영·가져오기", free: .included, premium: .included),
        PlanComparisonItem(id: "albums", titleKey: "내 앨범", free: .included, premium: .included),
        PlanComparisonItem(id: "retention", titleKey: "기본 보관 기간", free: .included, premium: .included),
        PlanComparisonItem(id: "ocrSearch", titleKey: "OCR 텍스트 검색", free: .included, premium: .included),
        PlanComparisonItem(id: "receiptRecognition", titleKey: "영수증 자동 인식·정보 추출", free: .included, premium: .included),
        PlanComparisonItem(id: "qrRecognition", titleKey: "QR 자동 인식", free: .included, premium: .included),
        PlanComparisonItem(id: "documentScan", titleKey: "문서 스캔", free: .included, premium: .included),
        PlanComparisonItem(id: "travelLocation", titleKey: "여행 위치 저장", free: .included, premium: .included),
        PlanComparisonItem(id: "receiptReport", titleKey: "지출 리포트", free: .trial(trialLimit(for: .receiptReport)), premium: .unlimited),
        PlanComparisonItem(id: "travelMap", titleKey: "여행 지도", free: .trial(trialLimit(for: .travelMap)), premium: .unlimited),
        PlanComparisonItem(id: "documentBuilder", titleKey: "문서 만들기", free: .trial(trialLimit(for: .documentBuilder)), premium: .unlimited),
        PlanComparisonItem(id: "qrBuilder", titleKey: "QR 만들기", free: .trial(trialLimit(for: .qrBuilder)), premium: .unlimited),
        PlanComparisonItem(id: "albumAutomation", titleKey: "앨범 자동화", free: .basic, premium: .advanced),
        PlanComparisonItem(id: "cleanupCenter", titleKey: "정리 센터", free: .unavailable, premium: .included),
        PlanComparisonItem(id: "ocrActions", titleKey: "OCR 스마트 작업", free: .unavailable, premium: .included),
        PlanComparisonItem(id: "icloud", titleKey: "iCloud 동기화", free: .unavailable, premium: .included),
        PlanComparisonItem(id: "capturePresets", titleKey: "고급 촬영 프리셋", free: .unavailable, premium: .included),
        PlanComparisonItem(id: "privacyExport", titleKey: "개인정보 보호 내보내기", free: .unavailable, premium: .included)
    ]
}

enum PremiumAnalytics {
    static func paywallViewed(entryPoint: PremiumEntryPoint) {
        Analytics.logEvent("premium_paywall_view", parameters: ["entry_point": entryPoint.rawValue])
    }

    static func purchaseStarted(productID: String) {
        Analytics.logEvent("premium_purchase_start", parameters: ["plan": plan(productID)])
    }

    static func purchaseSucceeded(productID: String) {
        Analytics.logEvent("premium_purchase_success", parameters: ["plan": plan(productID)])
    }

    static func restoreSucceeded() {
        Analytics.logEvent("premium_restore_success", parameters: nil)
    }

    static func trialUsed(_ feature: PremiumFeatureID, remaining: Int) {
        Analytics.logEvent("premium_feature_trial_used", parameters: [
            "feature": feature.rawValue,
            "remaining": remaining
        ])
    }

    static func limitReached(_ feature: PremiumFeatureID) {
        Analytics.logEvent("premium_feature_limit_reached", parameters: ["feature": feature.rawValue])
    }

    private static func plan(_ productID: String) -> String {
        switch productID {
        case PurchaseManager.monthlyID: "monthly"
        case PurchaseManager.yearlyID: "yearly"
        case PurchaseManager.lifetimeID: "legacy_lifetime"
        default: "unknown"
        }
    }
}

struct PremiumView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var purchases = PurchaseManager.shared
    @State private var selectedID = PurchaseManager.yearlyID
    @State private var showsComparison = false
    @State private var didLogPaywallView = false
    let entryPoint: PremiumEntryPoint

    init(entryPoint: PremiumEntryPoint = .general) {
        self.entryPoint = entryPoint
    }

    private let privacyURL = URL(string: "https://motionfit.fit/subgallery/privacy/")!
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    private var selectedProduct: Product? {
        purchases.products.first { $0.id == selectedID }
    }

    private var yearlyProduct: Product? {
        purchases.products.first { $0.id == PurchaseManager.yearlyID }
    }

    private var secondaryProducts: [Product] {
        purchases.products.filter { $0.id == PurchaseManager.monthlyID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    benefits
                    productSection
                    legalSection
                    comparisonSection
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { purchaseBar }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("닫기")) { dismiss() }
                }
            }
        }
        .task {
            await purchases.prepare()
            chooseAvailableDefault()
        }
        .onAppear {
            guard !didLogPaywallView else { return }
            didLogPaywallView = true
            PremiumAnalytics.paywallViewed(entryPoint: entryPoint)
        }
        .onChange(of: purchases.products.map(\.id)) { _, _ in chooseAvailableDefault() }
        .alert("SubGallery Premium", isPresented: Binding(
            get: { purchases.message != nil },
            set: { if !$0 { purchases.message = nil } }
        )) {
            Button(L10n.text("확인"), role: .cancel) { purchases.message = nil }
        } message: {
            Text(purchases.message ?? "")
        }
    }

    private var hero: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: purchases.isPremium ? "checkmark.seal.fill" : "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text("SubGallery Premium")
                    .font(.headline.bold())
            }

            Text(L10n.text(headlineKey))
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Text(L10n.text(subheadlineKey))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headlineKey: String {
        switch entryPoint {
        case .receiptReport: "영수증이 지출 리포트가 됩니다."
        case .travelMap: "여행 사진이 지도가 됩니다."
        case .documentBuilder: "사진을 하나의 문서로 만드세요."
        case .qrBuilder: "QR을 직접 만들어 보관하세요."
        case .albumAutomation: "앨범이 사진을 대신 관리합니다."
        case .cleanupCenter, .iCloudSync, .capturePreset, .privacyExport, .ocrSmartActions:
            entryPoint.featureID.map { PremiumFeatureCatalog.feature($0).titleKey } ?? "SubGallery Premium"
        case .general: "사진은 따로. 쌓인 사진은 더 유용하게."
        }
    }

    private var subheadlineKey: String {
        switch entryPoint {
        case .receiptReport: "지출 흐름, 자주 결제한 곳, 큰 결제와 기간별 변화를 제한 없이 확인하세요."
        case .travelMap: "촬영한 장소와 여행의 흐름을 지도와 타임라인으로 계속 확인하세요."
        case .documentBuilder: "여러 장의 문서 사진을 정리해 하나의 PDF로 만들고, OCR로 문서 내용을 인식합니다."
        case .qrBuilder: "웹사이트, Wi-Fi, 연락처, 위치 등 자주 쓰는 정보를 QR로 만들고 언제든 바로 보여주세요."
        case .albumAutomation: "완료된 사진과 오래된 사진을 자동으로 관리하고, 정리가 필요한 항목을 한눈에 확인하세요."
        case .cleanupCenter, .iCloudSync, .capturePreset, .privacyExport, .ocrSmartActions:
            entryPoint.featureID.map { PremiumFeatureCatalog.feature($0).detailKey } ?? ""
        case .general: "기본 보관과 인식은 자유롭게 사용하고, 쌓인 사진에서 더 큰 결과를 만드세요."
        }
    }

    private var benefits: some View {
        VStack(spacing: 0) {
            ForEach(Array(paywallBenefits.enumerated()), id: \.element.id) { index, benefit in
                PremiumBenefitRow(
                    symbol: benefit.symbol,
                    title: benefit.titleKey,
                    detail: benefit.detailKey,
                    accessCaption: benefit.accessCaption
                )
                if index < paywallBenefits.count - 1 {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var paywallBenefits: [PremiumPaywallBenefit] {
        var result: [PremiumPaywallBenefit] = []
        let primaryID = entryPoint.featureID
        if let primaryID {
            let feature = PremiumFeatureCatalog.feature(primaryID)
            result.append(PremiumPaywallBenefit(
                id: feature.id.rawValue,
                symbol: feature.symbol,
                titleKey: feature.titleKey,
                detailKey: feature.detailKey,
                accessCaption: feature.accessPolicy.paywallCaption
            ))
        }

        let groups = PremiumFeatureCatalog.generalBenefitGroups.filter { group in
            guard let primaryID else { return true }
            return !group.featureIDs.contains(primaryID)
        }
        let remainingCount = primaryID == nil ? 4 : 3
        result.append(contentsOf: groups.prefix(remainingCount).map { group in
            PremiumPaywallBenefit(
                id: group.id,
                symbol: group.symbol,
                titleKey: group.titleKey,
                detailKey: group.detailKey,
                accessCaption: nil
            )
        })
        return result
    }

    @ViewBuilder
    private var productSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("플랜 선택"))
                .font(.headline.bold())

            if purchases.isLoading {
                ProgressView(L10n.text("상품을 불러오는 중…"))
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if purchases.products.isEmpty {
                ContentUnavailableView {
                    Label(L10n.text("상품을 불러올 수 없음"), systemImage: "cart")
                } description: {
                    Text(L10n.text("App Store에서 상품을 찾을 수 없습니다."))
                } actions: {
                    Button(L10n.text("다시 시도")) {
                        Task { await purchases.reloadProducts() }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                if let yearlyProduct {
                    YearlyProductCard(
                        product: yearlyProduct,
                        isSelected: selectedID == yearlyProduct.id,
                        isPurchased: purchases.purchasedProductIDs.contains(yearlyProduct.id),
                        select: { selectedID = yearlyProduct.id }
                    )
                }

                HStack(alignment: .top, spacing: 10) {
                    ForEach(secondaryProducts) { product in
                        SecondaryProductCard(
                            product: product,
                            isSelected: selectedID == product.id,
                            isPurchased: purchases.purchasedProductIDs.contains(product.id),
                            select: { selectedID = product.id }
                        )
                    }
                }
            }
        }
    }

    private var purchaseBar: some View {
        VStack(spacing: 7) {
            if purchases.isPremium {
                Button(L10n.text("완료")) { dismiss() }
                    .prominentPurchaseButton()
            } else if let selectedProduct {
                Button {
                    Task { await purchases.purchase(selectedProduct) }
                } label: {
                    Group {
                        if purchases.isPurchasing {
                            ProgressView().tint(.white)
                        } else {
                            Text(purchaseButtonTitle(for: selectedProduct))
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(purchases.isPurchasing || !purchases.canMakePayments)
            }

            if selectedProduct?.subscription != nil {
                Text(L10n.text("언제든지 취소할 수 있습니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Button {
                    Task { await purchases.restore() }
                } label: {
                    if purchases.isRestoring { ProgressView() }
                    else { Text(L10n.text("구매 복원")) }
                }
                .disabled(purchases.isRestoring)
                Link(L10n.text("이용 약관"), destination: termsURL)
                Link(L10n.text("개인정보 처리방침"), destination: privacyURL)
            }
            .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var legalSection: some View {
        VStack(spacing: 10) {
            if selectedProduct?.subscription != nil {
                Text(L10n.text("구독은 현재 기간이 끝나기 최소 24시간 전에 취소하지 않으면 자동으로 갱신됩니다."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

        }
    }

    private var comparisonSection: some View {
        DisclosureGroup(isExpanded: $showsComparison) {
            PlanComparisonView()
                .padding(.top, 10)
        } label: {
            Text(L10n.text("Premium 기능 전체 보기"))
                .font(.subheadline.weight(.semibold))
        }
        .tint(.primary)
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func purchaseButtonTitle(for product: Product) -> String {
        switch product.id {
        case PurchaseManager.yearlyID: L10n.text("연간으로 Premium 시작하기")
        case PurchaseManager.monthlyID: L10n.text("월간으로 Premium 시작하기")
        default: L10n.text("구독 시작하기")
        }
    }

    private func chooseAvailableDefault() {
        if let purchased = purchases.products.first(where: { purchases.purchasedProductIDs.contains($0.id) }) {
            selectedID = purchased.id
            return
        }
        guard !purchases.products.contains(where: { $0.id == selectedID }) else { return }
        selectedID = purchases.products.first(where: { $0.id == PurchaseManager.yearlyID })?.id
            ?? purchases.products.first?.id
            ?? PurchaseManager.yearlyID
    }
}

private extension Product {
    /// App Store Connect 제품명은 한국어로만 등록되어 있어 앱 언어 설정을 따르지 않는다. 알려진 플랜은 직접 번역해 보여준다.
    var localizedPlanName: String {
        switch id {
        case PurchaseManager.yearlyID: L10n.text("SubGallery Premium 연간")
        case PurchaseManager.monthlyID: L10n.text("SubGallery Premium 월간")
        default: displayName
        }
    }
}

private extension View {
    func prominentPurchaseButton() -> some View {
        self
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
    }
}

private struct PremiumBenefitRow: View {
    let symbol: String
    let title: String
    let detail: String
    let accessCaption: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(title)).font(.subheadline.bold())
                Text(L10n.text(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let accessCaption {
                    Text(accessCaption)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct YearlyProductCard: View {
    let product: Product
    let isSelected: Bool
    let isPurchased: Bool
    let select: () -> Void

    private var monthlyEquivalent: String {
        (product.price / Decimal(12)).formatted(product.priceFormatStyle)
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(product.localizedPlanName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(L10n.text("추천"))
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                    }
                    Text(L10n.text("가장 인기 있는 플랜"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(product.displayPrice)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    Text(L10n.format("월 약 %@", monthlyEquivalent))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if isPurchased {
                        Label(L10n.text("구매됨"), systemImage: "checkmark")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(15)
            .background(Color.accentColor.opacity(isSelected ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.accentColor.opacity(isSelected ? 1 : 0.35), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SecondaryProductCard: View {
    let product: Product
    let isSelected: Bool
    let isPurchased: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    Spacer()
                    Text(product.displayPrice)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                }
                Text(product.localizedPlanName)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(L10n.text("언제든지 취소할 수 있습니다."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if isPurchased {
                    Label(L10n.text("구매됨"), systemImage: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .padding(13)
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct PlanComparisonView: View {
    private let rows = PremiumFeatureCatalog.comparisonItems

    var body: some View {
        VStack(spacing: 0) {
                HStack {
                    Text(L10n.text("기능")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L10n.text("무료")).frame(width: 58)
                    Text("Premium").frame(width: 76)
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(height: 42)

                Divider()

                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack {
                        Text(L10n.text(row.titleKey))
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        availability(row.free).frame(width: 58)
                        availability(row.premium).frame(width: 76)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    if index < rows.count - 1 { Divider().padding(.leading, 14) }
                }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.secondary.opacity(0.2)))
    }

    @ViewBuilder
    private func availability(_ availability: FeatureAvailability) -> some View {
        switch availability {
        case .included:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(L10n.text("포함"))
        case .unavailable:
            Text(availability.title).foregroundStyle(.secondary)
        case .trial, .basic, .unlimited, .advanced:
            Text(availability.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(availability == .unlimited || availability == .advanced
                    ? Color.accentColor : Color.primary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
        }
    }
}
