import StoreKit
import SwiftUI

@MainActor
final class PurchaseManager: ObservableObject {
    @Published var products: [Product] = []
    @Published var purchased = false
    private let identifiers = ["com.namslab.subgallery.premium.monthly", "com.namslab.subgallery.premium.yearly"]

    func load() async {
        products = (try? await Product.products(for: identifiers))?.sorted { $0.price < $1.price } ?? []
        await refresh()
    }

    func purchase(_ product: Product) async {
        guard let result = try? await product.purchase() else { return }
        if case .success(let verification) = result, case .verified(let transaction) = verification {
            await transaction.finish()
            await refresh()
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }

    private func refresh() async {
        purchased = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement, identifiers.contains(transaction.productID) { purchased = true }
        }
    }
}

struct PremiumView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var purchases = PurchaseManager()
    @State private var selectedID = "com.namslab.subgallery.premium.yearly"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.tint)
                    VStack(spacing: 8) {
                        Text("SubGallery Premium").font(.largeTitle.bold())
                        Text("보관 기한, 보안, 동기화를 제한 없이 사용하세요.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        FeatureRow("Temporary 자동 정리", symbol: "clock.arrow.circlepath")
                        FeatureRow("Face ID와 Fake PIN", symbol: "faceid")
                        FeatureRow("iCloud 동기화", symbol: "icloud")
                        FeatureRow("Capture Preset과 빠른 촬영", symbol: "camera.badge.clock")
                        FeatureRow("개인정보 보호 내보내기", symbol: "hand.raised")
                    }
                    .frame(maxWidth: 420)

                    if purchases.products.isEmpty {
                        ContentUnavailableView("상품을 불러올 수 없음", systemImage: "cart", description: Text("App Store Connect에서 구독 상품을 설정해 주세요."))
                    } else {
                        ForEach(purchases.products) { product in
                            Button { selectedID = product.id } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(product.id.hasSuffix("yearly") ? "연간" : "월간").font(.headline)
                                        if product.id.hasSuffix("yearly") { Text("추천").font(.caption).foregroundStyle(.tint) }
                                    }
                                    Spacer(); Text(product.displayPrice).font(.headline)
                                    Image(systemName: selectedID == product.id ? "checkmark.circle.fill" : "circle")
                                }
                                .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain)
                        }
                        Button("계속") {
                            if let product = purchases.products.first(where: { $0.id == selectedID }) { Task { await purchases.purchase(product) } }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                    }

                    Button("구매 복원") { Task { await purchases.restore() } }.font(.footnote)
                    Text("구매 시 Apple의 이용 약관과 개인정보 처리방침이 적용됩니다.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
        .task { await purchases.load() }
    }
}

private struct FeatureRow: View {
    let title: String
    let symbol: String
    init(_ title: String, symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View { Label(title, systemImage: symbol).font(.headline).frame(maxWidth: .infinity, alignment: .leading) }
}
