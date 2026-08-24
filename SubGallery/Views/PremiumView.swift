import StoreKit
import SwiftUI

@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()

    static let monthlyID = "com.namslab.subgallery.premium.monthly"
    static let yearlyID = "com.namslab.subgallery.premium.yearly"
    static let lifetimeID = "com.namslab.subgallery.premium.lifetime"
    static let productIDs = [monthlyID, yearlyID, lifetimeID]

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
                   Self.productIDs.contains(transaction.productID) {
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
            message = isPremium
                ? L10n.text("구매가 복원되었습니다.")
                : L10n.text("복원할 구매가 없습니다.")
        } catch {
            message = error.localizedDescription
        }
    }

    private func refreshEntitlements() async {
        var activeIDs: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID) else { continue }
            activeIDs.insert(transaction.productID)
        }
        purchasedProductIDs = activeIDs
        UserDefaults.standard.set(isPremium, forKey: "premium.active")
    }
}

struct PremiumView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var purchases = PurchaseManager.shared
    @State private var selectedID = PurchaseManager.yearlyID

    private let privacyURL = URL(string: "https://motionfit.fit/subgallery/privacy/")!
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    private var selectedProduct: Product? {
        purchases.products.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    hero
                    PlanComparisonView()
                    productSection
                    purchaseSection
                    legalSection
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
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
        VStack(spacing: 12) {
            Image(systemName: purchases.isPremium ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 68, height: 68)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            Text(purchases.isPremium ? L10n.text("Premium을 사용 중입니다") : "SubGallery Premium")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text(L10n.text("핵심 기능은 무료로, 더 편리한 관리는 Premium으로 이용하세요."))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var productSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("플랜 선택"))
                .font(.title2.bold())

            FreePlanCard(isCurrent: !purchases.isPremium)

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
                ForEach(purchases.products) { product in
                    PremiumProductCard(
                        product: product,
                        isSelected: selectedID == product.id,
                        isPurchased: purchases.purchasedProductIDs.contains(product.id),
                        select: { selectedID = product.id }
                    )
                }
            }
        }
    }

    private var purchaseSection: some View {
        VStack(spacing: 12) {
            if purchases.purchasedProductIDs.contains(PurchaseManager.lifetimeID)
                || selectedProduct.map({ purchases.purchasedProductIDs.contains($0.id) }) == true {
                Button(L10n.text("완료")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            } else if let selectedProduct {
                Button {
                    Task { await purchases.purchase(selectedProduct) }
                } label: {
                    Group {
                        if purchases.isPurchasing {
                            ProgressView().tint(.white)
                        } else {
                            Text(L10n.text(selectedProduct.id == PurchaseManager.lifetimeID
                                ? "평생 이용권 구매"
                                : "구독 시작하기"))
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(purchases.isPurchasing || !purchases.canMakePayments)

                Text(L10n.text(selectedProduct.id == PurchaseManager.lifetimeID
                    ? "한 번 결제하면 계속 이용할 수 있습니다."
                    : "언제든지 취소할 수 있습니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await purchases.restore() }
            } label: {
                if purchases.isRestoring {
                    ProgressView()
                } else {
                    Text(L10n.text("구매 복원"))
                }
            }
            .font(.subheadline.weight(.semibold))
            .disabled(purchases.isRestoring)
        }
    }

    private var legalSection: some View {
        VStack(spacing: 10) {
            if selectedProduct?.subscription != nil {
                Text(L10n.text("구독은 현재 기간이 끝나기 최소 24시간 전에 취소하지 않으면 자동으로 갱신됩니다."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 18) {
                Link(L10n.text("이용 약관"), destination: termsURL)
                Link(L10n.text("개인정보 처리방침"), destination: privacyURL)
            }
            .font(.caption.weight(.medium))
        }
    }

    private func chooseAvailableDefault() {
        if let lifetime = purchases.products.first(where: {
            $0.id == PurchaseManager.lifetimeID && purchases.purchasedProductIDs.contains($0.id)
        }) {
            selectedID = lifetime.id
            return
        }
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

private struct FreePlanCard: View {
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("무료"))
                    .font(.headline)
                Text([
                    L10n.text("사진 앱과 별도 보관"),
                    L10n.text("촬영 및 가져오기"),
                    L10n.text("앨범과 보관 기간")
                ].joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer()
            if isCurrent {
                Text(L10n.text("현재 플랜"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.secondary.opacity(0.2)))
    }
}

private struct PremiumProductCard: View {
    let product: Product
    let isSelected: Bool
    let isPurchased: Bool
    let select: () -> Void

    private var isYearly: Bool { product.id == PurchaseManager.yearlyID }
    private var isLifetime: Bool { product.id == PurchaseManager.lifetimeID }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(product.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if isYearly {
                            Text(L10n.text("추천"))
                                .font(.caption2.bold())
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        } else if isLifetime {
                            Text(L10n.text("한 번 구매"))
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !product.description.isEmpty {
                        Text(product.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(product.displayPrice)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if isPurchased {
                        Label(L10n.text("구매됨"), systemImage: "checkmark")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
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
        ("iCloud 동기화", false, true),
        ("PIN 잠금", false, true),
        ("촬영 프리셋 설정", false, true),
        ("개인정보 보호 내보내기", false, true)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("플랜 비교"))
                .font(.title2.bold())

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
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.secondary.opacity(0.2)))
        }
    }

    private func availability(_ available: Bool) -> some View {
        Image(systemName: available ? "checkmark.circle.fill" : "minus")
            .foregroundStyle(available ? Color.accentColor : Color.secondary.opacity(0.55))
            .accessibilityLabel(L10n.text(available ? "포함" : "포함되지 않음"))
    }
}
