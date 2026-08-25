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

enum PremiumEntryPoint {
    case general
    case receiptReport
}

struct PremiumView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var purchases = PurchaseManager.shared
    @State private var selectedID = PurchaseManager.yearlyID
    @State private var showsComparison = false
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

            Text(L10n.text(
                entryPoint == .receiptReport
                    ? "영수증이 지출 리포트가 됩니다."
                    : "사진은 따로. 정리는 자동으로."
            ))
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Text(L10n.text(
                entryPoint == .receiptReport
                    ? "지출 흐름, 자주 결제한 곳, 큰 결제와 기간별 변화를 제한 없이 확인하세요."
                    : "자동 분류, 정리 센터, OCR 스마트 작업으로 쌓인 사진을 더 편하게 관리하세요."
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var benefits: some View {
        VStack(spacing: 0) {
            if entryPoint == .receiptReport {
                PremiumBenefitRow(
                    symbol: "chart.bar.xaxis",
                    title: "지출 리포트 무제한",
                    detail: "영수증으로 지출 흐름과 결제 패턴을 언제든 다시 확인합니다."
                )
                Divider().padding(.leading, 52)
            }
            PremiumBenefitRow(
                symbol: "wand.and.stars",
                title: "자동으로 분류",
                detail: "영수증, 문서, 임시 사진의 앨범과 보관 기간을 추천합니다."
            )
            Divider().padding(.leading, 52)
            PremiumBenefitRow(
                symbol: "tray.full.fill",
                title: "정리할 사진만 모아서",
                detail: "만료 예정과 완료 대기 사진을 한곳에서 빠르게 정리합니다."
            )
            Divider().padding(.leading, 52)
            PremiumBenefitRow(
                symbol: "text.viewfinder",
                title: "사진 속 정보를 바로 사용",
                detail: "금액, 날짜, 주소, QR 등을 인식해 바로 필요한 작업을 실행합니다."
            )
            Divider().padding(.leading, 52)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    supportingBenefit("icloud", "iCloud Sync")
                    supportingBenefit("camera.filters", "Capture Preset")
                    supportingBenefit("shield.lefthalf.filled", "개인정보 보호 내보내기")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func supportingBenefit(_ symbol: String, _ title: String) -> some View {
        Label(L10n.text(title), systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.1), in: Capsule())
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
    private let rows: [(String, Bool, Bool)] = [
        ("사진 앱과 별도 보관", true, true),
        ("촬영 및 가져오기", true, true),
        ("앨범과 보관 기간", true, true),
        ("PIN 잠금", true, true),
        ("OCR 텍스트 검색", true, true),
        ("일반 내보내기", true, true),
        ("스마트 자동 분류", false, true),
        ("앨범 자동 규칙", false, true),
        ("정리 센터", false, true),
        ("OCR 스마트 작업", false, true),
        ("영수증 정보 추출", false, true),
        ("iCloud 동기화", false, true),
        ("촬영 프리셋 설정", false, true),
        ("개인정보 보호 내보내기", false, true)
    ]

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

                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack {
                        Text(L10n.text(row.0))
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        availability(row.1).frame(width: 58)
                        availability(row.2).frame(width: 76)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    if index < rows.count - 1 { Divider().padding(.leading, 14) }
                }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.secondary.opacity(0.2)))
    }

    private func availability(_ available: Bool) -> some View {
        Image(systemName: available ? "checkmark.circle.fill" : "minus")
            .foregroundStyle(available ? Color.accentColor : Color.secondary.opacity(0.55))
            .accessibilityLabel(L10n.text(available ? "포함" : "포함되지 않음"))
    }
}
