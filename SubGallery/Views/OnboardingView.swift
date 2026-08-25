import SwiftUI

enum OnboardingAction: Equatable {
    case camera
    case importPhotos
    case library

}

enum OnboardingPage: Int, CaseIterable, Identifiable {
    case separate
    case workflows
    case outputs
    case automation

    var id: String {
        switch self {
        case .separate: "separate"
        case .workflows: "workflows"
        case .outputs: "outputs"
        case .automation: "automation"
        }
    }

    var index: Int { rawValue + 1 }

    var analyticsPage: SubGalleryAnalytics.OnboardingPage {
        SubGalleryAnalytics.OnboardingPage(rawValue: id)!
    }
}

struct OnboardingView: View {
    let canDismiss: Bool
    let onFinish: (OnboardingAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var page: OnboardingPage = .separate
    @State private var didLogPresentation = false

    static let pages = OnboardingPage.allCases

    private var analyticsContext: SubGalleryAnalytics.OnboardingContext {
        canDismiss ? .settings : .firstRun
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progress
                    .padding(.horizontal, 24)
                    .padding(.top, 10)

                TabView(selection: $page) {
                    ForEach(Self.pages) { page in
                        pageView(page)
                            .tag(page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.smooth, value: page)

                footer
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .toolbar {
                if canDismiss {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.text("닫기")) { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(!canDismiss)
        .sensoryFeedback(.selection, trigger: page)
        .onAppear {
            guard !didLogPresentation else { return }
            didLogPresentation = true
            SubGalleryAnalytics.onboardingStart(analyticsContext)
            SubGalleryAnalytics.onboardingPageView(page.analyticsPage, index: page.index, context: analyticsContext)
        }
        .onChange(of: page) { _, newPage in
            SubGalleryAnalytics.onboardingPageView(
                newPage.analyticsPage,
                index: newPage.index,
                context: analyticsContext
            )
        }
    }

    private var progress: some View {
        HStack(spacing: 7) {
            ForEach(Self.pages) { item in
                Capsule()
                    .fill(item.rawValue <= page.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
        }
        .frame(maxWidth: 680)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("%d/4단계", page.index))
    }

    @ViewBuilder
    private func pageView(_ page: OnboardingPage) -> some View {
        switch page {
        case .separate:
            onboardingPage(
                title: "필요한 사진만 따로 보관하세요",
                description: "기본 사진 앱에 섞고 싶지 않은 사진과 동영상을 SubGallery에 따로 보관하세요."
            ) { SeparateLibraryPreview() }
        case .workflows:
            onboardingPage(
                title: "사진의 목적에 맞게 관리하세요",
                description: "영수증 · 문서 · QR · 여행처럼 사진의 용도에 맞는 도구를 사용할 수 있어요."
            ) { WorkflowPreview() }
        case .outputs:
            onboardingPage(
                title: "사진을 보관하는 데서 끝나지 않아요",
                description: "사진의 목적에 맞게 필요한 결과로 활용할 수 있어요."
            ) { OutputPreview() }
        case .automation:
            onboardingPage(
                title: "필요한 동안만 보관하고 알아서 정리하세요",
                description: "보관 기간을 정하고 완료한 사진을 정리하세요. 내 앨범에는 관리 규칙도 설정할 수 있어요."
            ) { AutomationPreview() }
        }
    }

    private func onboardingPage<Visual: View>(
        title: String,
        description: String,
        @ViewBuilder visual: () -> Visual
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text(title))
                    .font(.largeTitle.bold())
                    .tracking(-0.6)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.text(description))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                visual()
                    .padding(.top, 10)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var footer: some View {
        if page != .automation {
            Button {
                guard let next = OnboardingPage(rawValue: page.rawValue + 1) else { return }
                withAnimation(.smooth) { page = next }
            } label: {
                Text(L10n.text("다음"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            VStack(spacing: 8) {
                Button { complete(.camera) } label: {
                    Label(L10n.text("카메라로 첫 사진 찍기"), systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.borderedProminent)

                Button { complete(.importPhotos) } label: {
                    Label(L10n.text("사진 가져오기"), systemImage: "photo.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)

                Button(L10n.text("보관함 먼저 보기")) { complete(.library) }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private func complete(_ action: OnboardingAction) {
        let analyticsAction: SubGalleryAnalytics.OnboardingAction = switch action {
        case .camera: .camera
        case .importPhotos: .import
        case .library: .library
        }
        SubGalleryAnalytics.onboardingComplete(analyticsAction, context: analyticsContext)
        onFinish(action)
    }
}

private struct SeparateLibraryPreview: View {
    var body: some View {
        HStack(spacing: 10) {
            MiniPanel(title: L10n.text("기본 사진 앱"), symbol: "photo.on.rectangle") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                    PreviewThumbnail(color: .orange, symbol: "sun.max.fill")
                    PreviewThumbnail(color: .blue, symbol: "cloud.fill")
                    PreviewThumbnail(color: .green, symbol: "leaf.fill")
                    PreviewThumbnail(color: .pink, symbol: "person.2.fill")
                }
            }

            Image(systemName: "arrow.forward")
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            MiniPanel(title: "SubGallery", symbol: "photo.on.rectangle.angled") {
                VStack(spacing: 7) {
                    MiniPurposeRow(title: L10n.text("영수증"), symbol: "receipt.fill")
                    MiniPurposeRow(title: L10n.text("문서"), symbol: "doc.fill")
                    MiniPurposeRow(title: L10n.text("여행"), symbol: "airplane")
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.separator.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}

private struct WorkflowPreview: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let cards: [(String, String, String)] = [
        ("영수증", "지출 리포트", "receipt.fill"),
        ("문서", "스캔 · PDF", "doc.viewfinder"),
        ("QR", "읽기 · 만들기", "qrcode.viewfinder"),
        ("여행", "사진 지도", "map.fill")
    ]

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 10),
                count: horizontalSizeClass == .regular ? 4 : 2
            ),
            spacing: 10
        ) {
            ForEach(cards, id: \.0) { card in
                WorkflowCard(title: L10n.text(card.0), detail: L10n.text(card.1), symbol: card.2)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.separator.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}

private struct WorkflowCard: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)")
    }
}

private struct OutputPreview: View {
    private let rows: [(String, String, String, String)] = [
        ("영수증", "지출 리포트", "receipt.fill", "chart.bar.fill"),
        ("문서", "PDF", "doc.fill", "doc.richtext.fill"),
        ("QR", "QR 코드", "qrcode.viewfinder", "qrcode"),
        ("여행", "지도", "airplane", "map.fill")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                OutputRow(
                    source: L10n.text(row.0),
                    result: L10n.text(row.1),
                    sourceSymbol: row.2,
                    resultSymbol: row.3
                )
                if index < rows.count - 1 {
                    Divider().padding(.horizontal, 14)
                }
            }
        }
        .padding(.vertical, 4)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.separator.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}

private struct OutputRow: View {
    let source: String
    let result: String
    let sourceSymbol: String
    let resultSymbol: String

    var body: some View {
        HStack(spacing: 10) {
            Label(source, systemImage: sourceSymbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.forward")
                .foregroundStyle(.secondary)

            Label(result, systemImage: resultSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(source), \(result)")
    }
}

private struct AutomationPreview: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: horizontalSizeClass == .regular ? 2 : 1
            ),
            alignment: .leading,
            spacing: 12
        ) {
            retentionCard
            albumRuleCard
        }
        .accessibilityElement(children: .contain)
    }

    private var retentionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(L10n.text("보관 기간"), systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .padding(.bottom, 8)

            RetentionChoice(title: L10n.text("계속 보관"), selected: true)
            RetentionChoice(title: L10n.text("완료할 때까지"), selected: false)
            RetentionChoice(title: L10n.text("7일"), selected: false)
            RetentionChoice(title: L10n.text("30일"), selected: false)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.separator.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }

    private var albumRuleCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.text("내 앨범 규칙"), systemImage: "rectangle.stack.badge.gearshape")
                .font(.headline)

            LabeledContent(L10n.text("보관 기간")) {
                Text(L10n.text("완료할 때까지"))
                    .foregroundStyle(.secondary)
            }
            Divider()
            LabeledContent(L10n.text("완료 후 정리")) {
                Label(L10n.text("켬"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.separator.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}

private struct RetentionChoice: View {
    let title: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
            Spacer()
        }
        .frame(minHeight: 34)
    }
}

private struct MiniPanel<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.caption.bold())
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PreviewThumbnail: View {
    let color: Color
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 61)
            .background(color.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct MiniPurposeRow: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(minHeight: 38)
            .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
