import CoreLocation
import SwiftData
import SwiftUI

struct QRCodeBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var purchases = PurchaseManager.shared
    @StateObject private var locationProvider = CaptureLocationProvider()

    @State private var kind: QRBuilderKind?
    @State private var urlText = ""
    @State private var ssid = ""
    @State private var wifiPassword = ""
    @State private var wifiSecurity = QRWiFiSecurity.wpa
    @State private var wifiIsHidden = false
    @State private var plainText = ""
    @State private var contactName = ""
    @State private var contactPhone = ""
    @State private var contactEmail = ""
    @State private var contactOrganization = ""
    @State private var phoneNumber = ""
    @State private var emailAddress = ""
    @State private var emailSubject = ""
    @State private var emailBody = ""
    @State private var latitudeText = ""
    @State private var longitudeText = ""

    @State private var preview: Preview?
    @State private var message: String?
    @State private var isSaving = false
    /// Guards against a second tap on Save spending another free use for the same
    /// generated code.
    @State private var didConsumeFreeUse = false
    @State private var savedItemID: UUID?
    @State private var showsFreeLimitNotice = false
    @State private var didLogOpen = false

    private struct Preview: Identifiable {
        let id = UUID()
        let payload: String
        let image: UIImage
        let kind: QRBuilderKind
    }

    init() {
        let usesStoreFixture = StoreScreenshotMode.isEnabled && StoreScreenshotMode.screen == "qr-builder"
        _kind = State(initialValue: usesStoreFixture ? .url : nil)
        _urlText = State(initialValue: usesStoreFixture ? "https://example.com/travel-notes" : "")
    }

    var body: some View {
        NavigationStack {
            Group {
                if let kind { form(for: kind) } else { kindPicker }
            }
            .navigationTitle(L10n.text("QR 만들기"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("취소")) { dismiss() }
                }
                if kind != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text("QR 만들기")) { generate() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { remainingFooter }
        }
        .sheet(item: $preview) { preview in
            QRCodePreviewView(
                payload: preview.payload,
                image: preview.image,
                kind: preview.kind,
                isSaving: isSaving,
                isSaved: savedItemID != nil,
                save: { save(preview) }
            )
        }
        .alert(L10n.text("QR 만들기"), isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button(L10n.text("확인"), role: .cancel) { }
        } message: {
            Text(message ?? "")
        }
        .alert(L10n.text("무료 QR 만들기를 모두 사용했습니다."), isPresented: $showsFreeLimitNotice) {
            Button(L10n.text("확인"), role: .cancel) { }
        } message: {
            Text(L10n.text("다음 QR부터 Premium이 필요합니다."))
        }
        .task {
            if !didLogOpen {
                didLogOpen = true
                SubGalleryAnalytics.qrBuilderOpen()
            }
            guard StoreScreenshotMode.isEnabled,
                  StoreScreenshotMode.screen == "qr-builder",
                  preview == nil else { return }
            await Task.yield()
            generate()
        }
    }

    // MARK: - Pickers and forms

    private var kindPicker: some View {
        List(QRBuilderKind.allCases) { option in
            Button {
                kind = option
            } label: {
                Label(option.title, systemImage: option.symbol)
            }
        }
    }

    @ViewBuilder
    private func form(for kind: QRBuilderKind) -> some View {
        Form {
            switch kind {
            case .url:
                Section(L10n.text("URL")) {
                    TextField("https://example.com", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            case .wifi:
                Section(L10n.text("Wi-Fi")) {
                    TextField(L10n.text("네트워크 이름"), text: $ssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if wifiSecurity != .none {
                        SecureField(L10n.text("비밀번호"), text: $wifiPassword)
                    }
                    Picker(L10n.text("보안"), selection: $wifiSecurity) {
                        ForEach(QRWiFiSecurity.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle(L10n.text("숨김 네트워크"), isOn: $wifiIsHidden)
                }
            case .text:
                Section(L10n.text("텍스트")) {
                    TextField(L10n.text("여기에 텍스트 입력"), text: $plainText, axis: .vertical)
                        .lineLimit(3...8)
                }
            case .contact:
                Section(L10n.text("연락처")) {
                    TextField(L10n.text("이름"), text: $contactName)
                    TextField(L10n.text("전화번호"), text: $contactPhone)
                        .keyboardType(.phonePad)
                    TextField(L10n.text("이메일"), text: $contactEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField(L10n.text("회사"), text: $contactOrganization)
                }
            case .phone:
                Section(L10n.text("전화번호")) {
                    TextField(L10n.text("전화번호"), text: $phoneNumber)
                        .keyboardType(.phonePad)
                }
            case .email:
                Section(L10n.text("이메일")) {
                    TextField(L10n.text("주소"), text: $emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.text("제목"), text: $emailSubject)
                    TextField(L10n.text("내용"), text: $emailBody, axis: .vertical)
                        .lineLimit(2...6)
                }
            case .location:
                Section(L10n.text("위치")) {
                    TextField(L10n.text("위도"), text: $latitudeText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField(L10n.text("경도"), text: $longitudeText)
                        .keyboardType(.numbersAndPunctuation)
                    // Permission is only requested when this is tapped, never on
                    // opening the builder.
                    Button(L10n.text("현재 위치 사용"), systemImage: "location") {
                        useCurrentLocation()
                    }
                }
            }
        }
    }

    private var remainingFooter: some View {
        Group {
            if !purchases.isPremium {
                Text(L10n.format("무료 QR 만들기 %d회 남음", QRBuilderUsageStore.remaining))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
    }

    // MARK: - Behaviour

    private func currentInput(for kind: QRBuilderKind) -> QRBuilderInput {
        switch kind {
        case .url: .url(urlText)
        case .wifi: .wifi(
            ssid: ssid,
            password: wifiPassword,
            security: wifiSecurity,
            isHidden: wifiIsHidden
        )
        case .text: .text(plainText)
        case .contact: .contact(
            name: contactName,
            phone: contactPhone,
            email: contactEmail,
            organization: contactOrganization
        )
        case .phone: .phone(phoneNumber)
        case .email: .email(address: emailAddress, subject: emailSubject, body: emailBody)
        case .location: .location(
            latitude: Double(latitudeText.trimmingCharacters(in: .whitespaces)) ?? .nan,
            longitude: Double(longitudeText.trimmingCharacters(in: .whitespaces)) ?? .nan
        )
        }
    }

    private func generate() {
        guard let kind else { return }
        do {
            let payload = try QRCodeBuilderService.payload(for: currentInput(for: kind))
            let image = try QRCodeBuilderService.image(for: payload)
            // A preview costs nothing: the free use is spent on saving, not here.
            savedItemID = nil
            didConsumeFreeUse = false
            preview = Preview(payload: payload, image: image, kind: kind)
        } catch {
            SubGalleryAnalytics.qrCreateFailed(qrFailureReason(error))
            message = error.localizedDescription
        }
    }

    private func useCurrentLocation() {
        locationProvider.requestCurrentLocation()
        Task {
            for _ in 0..<20 {
                if let location = locationProvider.latestLocation {
                    latitudeText = String(format: "%.6f", location.coordinate.latitude)
                    longitudeText = String(format: "%.6f", location.coordinate.longitude)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            message = L10n.text("현재 위치를 확인할 수 없습니다.")
        }
    }

    private func save(_ preview: Preview) {
        guard savedItemID == nil, !isSaving else { return }
        isSaving = true
        let qrType = SubGalleryAnalytics.qrType(preview.kind)
        SubGalleryAnalytics.mediaAddStart(
            source: .qrBuilder, destination: .qr, template: .qr, kind: .photo
        )
        Task {
            do {
                guard let data = preview.image.pngData() else {
                    throw QRCodeBuilderError.renderFailed
                }
                let stored = try await MediaStorage.shared.store(
                    data: data,
                    type: .png,
                    preferredName: QRCodeBuilderService.defaultFileName(for: preview.kind)
                )
                await MainActor.run {
                    let item = MediaItem(
                        kind: .photo,
                        source: .generated,
                        localPath: stored.relativePath,
                        thumbnailPath: stored.thumbnailRelativePath,
                        fileName: stored.fileName,
                        fileSize: stored.fileSize,
                        width: stored.width,
                        height: stored.height
                    )
                    // The payload is known at creation, so it is written directly
                    // instead of being re-read out of the image with Vision.
                    item.templatePurpose = .qr
                    item.classificationStatus = .applied
                    item.detectedQRCodes = [preview.payload]
                    if let url = OCRService.httpURLString(preview.payload) {
                        item.detectedURLs = [url]
                    }
                    item.analysisEnabled = false
                    item.ocrStatus = .notApplicable
                    item.primaryAction = .open
                    modelContext.insert(item)
                    do {
                        try modelContext.save()
                    } catch {
                        isSaving = false
                        message = L10n.text("QR을 저장할 수 없습니다.")
                        SubGalleryAnalytics.qrCreateFailed(.saveFailed)
                        SubGalleryAnalytics.mediaAddFailed(
                            source: .qrBuilder, destination: .qr,
                            template: .qr, kind: .photo, reason: .saveFailed
                        )
                        return
                    }

                    SubGalleryAnalytics.qrCreateSuccess(qrType)
                    SubGalleryAnalytics.mediaAddSuccess(
                        source: .qrBuilder, destination: .qr,
                        template: .qr, kind: .photo
                    )

                    let wasLastFreeUse = QRBuilderUsageStore.isLastFreeUse(
                        isPremium: purchases.isPremium
                    )
                    if !didConsumeFreeUse {
                        let remaining = QRBuilderUsageStore.recordSuccessfulSave(
                            isPremium: purchases.isPremium
                        )
                        if !purchases.isPremium {
                            PremiumAnalytics.trialUsed(.qrBuilder, remaining: remaining)
                        }
                        didConsumeFreeUse = true
                    }
                    savedItemID = item.id
                    isSaving = false
                    self.preview = nil
                    if wasLastFreeUse && !purchases.isPremium {
                        showsFreeLimitNotice = true
                    } else {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    message = error.localizedDescription
                    SubGalleryAnalytics.qrCreateFailed(qrFailureReason(error))
                    SubGalleryAnalytics.mediaAddFailed(
                        source: .qrBuilder, destination: .qr,
                        template: .qr, kind: .photo, reason: .storageFailed
                    )
                }
            }
        }
    }

    private func qrFailureReason(_ error: Error) -> SubGalleryAnalytics.BuilderFailureReason {
        guard let error = error as? QRCodeBuilderError else { return .unknown }
        switch error {
        case .invalidURL, .emptyValue, .invalidEmail, .invalidCoordinate: .invalidInput
        case .renderFailed: .renderFailed
        }
    }
}

// MARK: - Preview

struct QRCodePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let payload: String
    let image: UIImage
    let kind: QRBuilderKind
    let isSaving: Bool
    let isSaved: Bool
    let save: () -> Void

    @State private var showsShare = false
    @State private var showsFullScreen = false

    private var info: QRContentInfo { QRContentService.parse(payload) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 280)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .onTapGesture { showsFullScreen = true }

                VStack(spacing: 4) {
                    Text(kind.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(info.title)
                        .font(.headline)
                    if !info.subtitle.isEmpty {
                        Text(info.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }

                VStack(spacing: 10) {
                    Button(L10n.text("저장"), systemImage: "square.and.arrow.down") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || isSaved)
                    Button(L10n.text("공유"), systemImage: "square.and.arrow.up") { showsShare = true }
                    Button(L10n.text("크게 보기"), systemImage: "arrow.up.left.and.arrow.down.right") {
                        showsFullScreen = true
                    }
                }
                .controlSize(.large)
                Spacer()
            }
            .padding(24)
            .navigationTitle(L10n.text("미리 보기"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("닫기")) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showsShare) { QRImageShareSheet(image: image, payload: payload) }
        .fullScreenCover(isPresented: $showsFullScreen) {
            QRFullScreenView(image: image, title: info.title)
        }
    }
}

// MARK: - Full screen

/// Shown so someone else can scan it: maximum size, white ground, and the screen
/// kept awake because a code that sleeps mid-scan is useless.
struct QRFullScreenView: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let title: String

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(24)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.center)
                Spacer()
                Button(L10n.text("닫기")) { dismiss() }
                    .buttonStyle(.bordered)
                    .tint(.black)
                    .padding(.bottom, 24)
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.light)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// Shares the QR as a PNG image, with the payload text alongside so a recipient can
/// paste the value instead of scanning.
struct QRImageShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    let payload: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image, payload], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
