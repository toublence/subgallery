import SwiftUI

enum OnboardingAction: Equatable {
    case camera
    case importPhotos
    case library
}

struct OnboardingView: View {
    let canDismiss: Bool
    let onFinish: (OnboardingAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private let pageCount = 3

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progress
                    .padding(.horizontal, 24)
                    .padding(.top, 10)

                TabView(selection: $page) {
                    onboardingPage(
                        title: "사진첩과 따로 보관하세요",
                        description: "기본 사진 앱에 섞고 싶지 않은 사진과 동영상을 SubGallery에 따로 촬영하고 보관할 수 있어요.",
                        visual: AnyView(SeparateLibraryPreview())
                    )
                    .tag(0)

                    onboardingPage(
                        title: "찍거나 가져오면 바로 정리",
                        description: "카메라로 바로 촬영하거나 사진 앱에서 가져오세요. 원하는 앨범에 바로 저장할 수 있어요.",
                        visual: AnyView(CaptureFlowPreview())
                    )
                    .tag(1)

                    onboardingPage(
                        title: "필요한 만큼만 보관하세요",
                        description: "계속 간직할 사진은 그대로, 잠깐 필요한 사진은 필요한 동안만 보관하세요.",
                        visual: AnyView(RetentionPreview())
                    )
                    .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.smooth, value: page)

                footer
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
    }

    private var progress: some View {
        HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index <= page ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("%d/3단계", page + 1))
    }

    private func onboardingPage(title: String, description: String, visual: AnyView) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text(title))
                    .font(.largeTitle.bold())
                    .tracking(-0.6)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.text(description))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                visual
                    .padding(.top, 10)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var footer: some View {
        if page < pageCount - 1 {
            Button {
                withAnimation(.smooth) { page += 1 }
            } label: {
                Text(L10n.text("다음"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            VStack(spacing: 10) {
                Button { onFinish(.camera) } label: {
                    Label(L10n.text("카메라로 첫 사진 찍기"), systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)

                Button { onFinish(.importPhotos) } label: {
                    Label(L10n.text("사진 가져오기"), systemImage: "photo.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.bordered)

                Button(L10n.text("보관함 먼저 보기")) { onFinish(.library) }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
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

            Image(systemName: "arrow.right")
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            MiniPanel(title: "SubGallery", symbol: "photo.on.rectangle.angled") {
                VStack(spacing: 6) {
                    MiniAlbumCard(title: L10n.text("영수증"), detail: L10n.text("30일"), color: .orange, symbol: "receipt.fill")
                    MiniAlbumCard(title: L10n.text("여행"), detail: L10n.text("계속 보관"), color: .blue, symbol: "airplane")
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.separator.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}

private struct CaptureFlowPreview: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                SourceButton(title: L10n.text("카메라"), symbol: "camera.fill")
                SourceButton(title: L10n.text("사진 가져오기"), symbol: "photo.badge.plus")
            }

            Image(systemName: "arrow.down")
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                DestinationRow(title: L10n.text("영수증"), retention: L10n.text("30일"), symbol: "receipt.fill", color: .orange)
                Divider().padding(.leading, 48)
                DestinationRow(title: L10n.text("여행"), retention: L10n.text("계속 보관"), symbol: "airplane", color: .blue)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.separator.opacity(0.35)))
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct RetentionPreview: View {
    private let options: [(String, String)] = [
        ("infinity", "계속 보관"),
        ("checkmark.circle", "완료할 때까지"),
        ("clock", "24시간"),
        ("calendar", "7일"),
        ("calendar.badge.clock", "30일")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                HStack(spacing: 12) {
                    Image(systemName: option.0)
                        .foregroundStyle(index == 0 ? Color.accentColor : Color.secondary)
                        .frame(width: 24)
                    Text(L10n.text(option.1))
                        .font(.body.weight(index == 0 ? .semibold : .regular))
                    Spacer()
                    if index == 0 {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                if index < options.count - 1 { Divider().padding(.leading, 52) }
            }

            Divider()

            Label(L10n.text("고정하거나 다시 알림을 받을 수도 있어요."), systemImage: "pin.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.separator.opacity(0.35)))
        .accessibilityElement(children: .combine)
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
                .lineLimit(1)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
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
            .frame(height: 62)
            .background(color.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MiniAlbumCard: View {
    let title: String
    let detail: String
    let color: Color
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.white)
                .frame(width: 42, height: 54)
                .background(color.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.bold()).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct SourceButton: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.accentColor.opacity(0.3)))
    }
}

private struct DestinationRow: View {
    let title: String
    let retention: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).fontWeight(.semibold)
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(retention).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
    }
}
