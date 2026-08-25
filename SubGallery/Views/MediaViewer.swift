import AVKit
import Photos
import SwiftData
import SwiftUI

private enum RepresentativeMediaAction {
    case shareAndComplete
    case copyAndComplete
    case openURL
    case openQR
    case addEvent
    case call
}

struct MediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    @StateObject private var purchases = PurchaseManager.shared
    let items: [MediaItem]
    let initialID: UUID
    let isRecentlyDeleted: Bool
    @AppStorage("privacy.stripMetadata") private var stripsMetadata = false
    @State private var selectedID: UUID
    @State private var showsInfo = false
    @State private var showsDelete = false
    @State private var showsRetention = false
    @State private var showsReminder = false
    @State private var showsAlbumMove = false
    @State private var showsEditor = false
    @State private var showsShareSheet = false
    @State private var preparedShareURLs: [URL] = []
    @State private var completesAfterShare = false
    @State private var shareTargetID: UUID?
    @State private var actionMessage: String?
    @State private var showsCompleteConfirmation = false
    @State private var showsPremium = false
    @State private var showsReceiptEditor = false

    init(items: [MediaItem], initialID: UUID, isRecentlyDeleted: Bool) {
        self.items = items
        self.initialID = initialID
        self.isRecentlyDeleted = isRecentlyDeleted
        _selectedID = State(initialValue: initialID)
    }

    private var current: MediaItem? { items.first { $0.id == selectedID } }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedID) {
                ForEach(items) { item in
                    ViewerPage(item: item).tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(.black)
            .overlay(alignment: .bottom) {
                if let current,
                   purchases.isPremium,
                   !isRecentlyDeleted,
                   hasReceiptDetails(current) {
                    receiptSummary(for: current)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 54)
                }
            }
            .toolbarBackground(.black.opacity(0.55), for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L10n.text("닫기")) { dismiss() } }
                ToolbarItem(placement: .principal) {
                    if let current, !isRecentlyDeleted {
                        Text(RetentionService.statusText(for: current))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let current {
                        if isRecentlyDeleted {
                            Button(L10n.text("복구")) { MediaLifecycleService.restore(current); dismiss() }
                            Spacer()
                            Button(role: .destructive) { showsDelete = true } label: { Label(L10n.text("영구 삭제"), systemImage: "trash") }
                        } else {
                            if current.waitingForCompletion {
                                Button { showsCompleteConfirmation = true } label: {
                                    Label(L10n.text("완료"), systemImage: "checkmark.circle.fill")
                                }
                            } else {
                                representativeActionButton(for: current)
                            }
                            Spacer()
                            actionsMenu(for: current)
                        }
                    }
                }
            }
        }
        .statusBarHidden()
        .sheet(isPresented: $showsInfo) { if let current { MediaInfoView(item: current) } }
        .sheet(isPresented: $showsRetention) { if let current { RetentionPickerView(item: current) } }
        .sheet(isPresented: $showsReminder) { if let current { ReminderPickerView(item: current) } }
        .sheet(isPresented: $showsAlbumMove) { albumMovePicker }
        .sheet(isPresented: $showsPremium) { PremiumView() }
        .sheet(isPresented: $showsReceiptEditor) {
            if let current { ReceiptDetailsEditorView(item: current) }
        }
        .sheet(isPresented: $showsShareSheet, onDismiss: cleanupPreparedShare) {
            ActivityShareSheet(urls: preparedShareURLs) { completed in
                guard completed, completesAfterShare,
                      let id = shareTargetID,
                      let item = items.first(where: { $0.id == id }) else { return }
                finish(item)
            }
        }
        .fullScreenCover(isPresented: $showsEditor) {
            if let current {
                if current.kind == .photo {
                    PhotoEditorView(item: current) { _ in }
                } else {
                    VideoEditorView(item: current) { _ in }
                }
            }
        }
        .confirmationDialog(L10n.text("이 항목을 삭제할까요?"), isPresented: $showsDelete) {
            Button(L10n.text(isRecentlyDeleted ? "영구 삭제" : "삭제"), role: .destructive) { deleteCurrent() }
        }
        .confirmationDialog(L10n.text("이 사진을 완료 처리할까요?"), isPresented: $showsCompleteConfirmation) {
            Button(L10n.text("완료 처리")) { completeCurrent() }
            Button(L10n.text("취소"), role: .cancel) { }
        } message: {
            Text(L10n.text("완료한 사진은 최근 삭제로 이동하며 7일 동안 복구할 수 있습니다."))
        }
        .alert(L10n.text("사진 작업"), isPresented: Binding(
            get: { actionMessage != nil },
            set: { if !$0 { actionMessage = nil } }
        )) {
            Button(L10n.text("확인"), role: .cancel) { }
        } message: {
            Text(actionMessage ?? "")
        }
    }

    @ViewBuilder
    private func actionsMenu(for item: MediaItem) -> some View {
        Menu {
            if item.waitingForCompletion {
                Button { showsCompleteConfirmation = true } label: {
                    Label(L10n.text("완료"), systemImage: "checkmark.circle.fill")
                }
                Divider()
            }
            contentActions(for: item)
            Divider()
            Button { showsEditor = true } label: { Label(L10n.text("편집"), systemImage: "slider.horizontal.3") }
            Divider()
            Button {
                item.isPinned.toggle()
                if !item.isPinned && RetentionService.shouldMoveToRecentlyDeleted(item) {
                    Task {
                        await MediaLifecycleService.moveToRecentlyDeleted(item)
                        dismiss()
                    }
                }
                try? modelContext.save()
            } label: {
                Label(L10n.text(item.isPinned ? "고정 해제" : "고정"), systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            Button { showsReminder = true } label: {
                Label(L10n.text(item.reminderDate == nil ? "다시 알려주기" : "알림 변경"), systemImage: "bell")
            }
            Button { showsRetention = true } label: { Label(L10n.text("보관 기간"), systemImage: "clock") }
            Button { showsAlbumMove = true } label: { Label(L10n.text("앨범으로 이동"), systemImage: "folder") }
                .disabled(albums.isEmpty)
            Button { prepareShare(for: item, completeAfter: false) } label: { Label(L10n.text("공유"), systemImage: "square.and.arrow.up") }
            Button { prepareShare(for: item, completeAfter: true) } label: {
                Label(L10n.text("공유하고 완료"), systemImage: "checkmark.circle")
            }
            Button { exportToPhotos(item, completeAfter: false) } label: {
                Label(L10n.text("Photos로 내보내기"), systemImage: "photo.badge.arrow.down")
            }
            Button { exportToPhotos(item, completeAfter: true) } label: {
                Label(L10n.text("내보내고 완료"), systemImage: "checkmark.circle")
            }
            Button { showsInfo = true } label: { Label(L10n.text("정보"), systemImage: "info.circle") }
            Divider()
            Button(role: .destructive) { showsDelete = true } label: { Label(L10n.text("삭제"), systemImage: "trash") }
        } label: {
            Label(L10n.text("사진 동작"), systemImage: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private func contentActions(for item: MediaItem) -> some View {
        if !item.recognizedText.isEmpty {
            Menu(L10n.text("텍스트")) {
                Button { MediaActionService.copy(item.recognizedText) } label: { Label(L10n.text("텍스트 복사"), systemImage: "doc.on.doc") }
                Button { copyAndFinish(item.recognizedText, item: item) } label: {
                    Label(L10n.text("복사하고 완료"), systemImage: "checkmark.circle")
                }
            }
        }
        qrContentActions(for: item)
        if hasPremiumSmartContent(item), !purchases.isPremium {
            Button { showsPremium = true } label: {
                Label(L10n.text("사진 속 정보 사용"), systemImage: "lock.fill")
            }
        }
        if purchases.isPremium {
            premiumContentActions(for: item)
        }
    }

    /// QR is SubGallery's baseline value, not an upsell: reading a code and acting
    /// on it works without Premium. Premium differentiates on the workflow built
    /// around QR, not on access to the payload.
    @ViewBuilder
    private func qrContentActions(for item: MediaItem) -> some View {
        ForEach(item.qrContents) { info in
            Menu(info.type.title) {
                Button {
                    if let error = QRActionRunner.perform(info, for: item, in: modelContext) {
                        actionMessage = error
                    }
                } label: {
                    Label(info.primaryAction.title, systemImage: info.primaryAction.symbol)
                }
                Button {
                    if let error = QRActionRunner.perform(info, for: item, in: modelContext) {
                        actionMessage = error
                    } else {
                        finish(item)
                    }
                } label: {
                    Label(L10n.format("%@ 후 완료", info.primaryAction.title), systemImage: "checkmark.circle")
                }
                Button { MediaActionService.copy(info.rawValue) } label: {
                    Label(L10n.text("내용 복사"), systemImage: "doc.on.doc")
                }
                Button { copyAndFinish(info.rawValue, item: item) } label: {
                    Label(L10n.text("복사하고 완료"), systemImage: "checkmark.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func premiumContentActions(for item: MediaItem) -> some View {
        if hasReceiptDetails(item) {
            Menu(L10n.text("영수증 정보")) {
                if !item.receiptAmount.isEmpty {
                    Button { MediaActionService.copy(item.receiptAmount) } label: {
                        Label(L10n.text("금액 복사"), systemImage: "doc.on.doc")
                    }
                }
                Button { showsReceiptEditor = true } label: {
                    Label(L10n.text("정보 수정"), systemImage: "pencil")
                }
            }
        }
        if let value = item.detectedURLs.first {
            Menu(L10n.text("URL")) {
                Button { openURL(value, item: item, completeAfter: false) } label: { Label(L10n.text("Safari에서 열기"), systemImage: "safari") }
                Button { openURL(value, item: item, completeAfter: true) } label: { Label(L10n.text("열고 완료"), systemImage: "checkmark.circle") }
            }
        }
        if let value = item.detectedPhoneNumbers.first {
            Menu(L10n.text("전화번호")) {
                Button { call(value) } label: { Label(L10n.text("전화"), systemImage: "phone") }
                Button { MediaActionService.copy(value) } label: { Label(L10n.text("번호 복사"), systemImage: "doc.on.doc") }
                Button { copyAndFinish(value, item: item) } label: { Label(L10n.text("복사하고 완료"), systemImage: "checkmark.circle") }
            }
        }
        if let value = item.detectedAddresses.first {
            Menu(L10n.text("주소")) {
                Button { openAddress(value, item: item, completeAfter: false) } label: { Label(L10n.text("지도에서 열기"), systemImage: "map") }
                Button { MediaActionService.copy(value) } label: { Label(L10n.text("주소 복사"), systemImage: "doc.on.doc") }
                Button { openAddress(value, item: item, completeAfter: true) } label: {
                    Label(L10n.text("지도에서 열고 완료"), systemImage: "checkmark.circle")
                }
            }
        }
        if let date = item.detectedDates.first {
            Menu(L10n.text("날짜 및 시간")) {
                Button { addCalendarEvent(date, item: item, completeAfter: false) } label: {
                    Label(L10n.text("캘린더에 추가"), systemImage: "calendar.badge.plus")
                }
                Button { addReminder(date, item: item) } label: { Label(L10n.text("미리알림 생성"), systemImage: "list.bullet") }
                Button { addCalendarEvent(date, item: item, completeAfter: true) } label: {
                    Label(L10n.text("일정 추가하고 완료"), systemImage: "checkmark.circle")
                }
            }
        }
        if hasPremiumSmartContent(item) {
            Button { showsCompleteConfirmation = true } label: {
                Label(L10n.text("처리 완료"), systemImage: "checkmark.circle.fill")
            }
        }
    }

    private func prepareShare(for item: MediaItem, completeAfter: Bool) {
        Task {
            do {
                let urls = try await MediaExportService.preparedURLs(for: [item], strippingMetadata: stripsMetadata)
                await MainActor.run {
                    preparedShareURLs = urls
                    completesAfterShare = completeAfter
                    shareTargetID = item.id
                    showsShareSheet = true
                }
            } catch {
                await MainActor.run { actionMessage = error.localizedDescription }
            }
        }
    }

    private func cleanupPreparedShare() {
        MediaExportService.cleanupPreparedURLs(preparedShareURLs)
        preparedShareURLs = []
        completesAfterShare = false
        shareTargetID = nil
    }

    @ViewBuilder
    private func representativeActionButton(for item: MediaItem) -> some View {
        let action = representativeAction(for: item)
        // A QR's button names what will actually happen — 전화, 지도, 복사 — rather
        // than a generic "QR 열기" that may not be an open at all.
        let qr = action == .openQR ? item.primaryQRContent : nil
        return Button { perform(action, for: item) } label: {
            Label(
                qr?.primaryAction.title ?? representativeTitle(action),
                systemImage: qr?.primaryAction.symbol ?? representativeSymbol(action)
            )
        }
    }

    private func representativeAction(for item: MediaItem) -> RepresentativeMediaAction {
        switch item.primaryAction {
        case .shareAndComplete: return .shareAndComplete
        case .copyAndComplete where purchases.isPremium && !item.recognizedText.isEmpty: return .copyAndComplete
        case .open where !item.detectedQRCodes.isEmpty: return .openQR
        case .open where purchases.isPremium && !item.detectedURLs.isEmpty: return .openURL
        case .addEvent where purchases.isPremium && !item.detectedDates.isEmpty: return .addEvent
        default: break
        }
        if item.purpose == .receipt { return .shareAndComplete }
        if !item.detectedQRCodes.isEmpty { return .openQR }
        guard purchases.isPremium else { return .shareAndComplete }
        if !item.detectedURLs.isEmpty { return .openURL }
        if !item.detectedDates.isEmpty { return .addEvent }
        if !item.detectedPhoneNumbers.isEmpty { return .call }
        if !item.recognizedText.isEmpty { return .copyAndComplete }
        return .shareAndComplete
    }

    /// QR is deliberately absent here: it is free, so a QR-only photo must not
    /// show the Premium upsell.
    private func hasPremiumSmartContent(_ item: MediaItem) -> Bool {
        hasReceiptDetails(item)
            || !item.detectedURLs.isEmpty
            || !item.detectedPhoneNumbers.isEmpty
            || !item.detectedAddresses.isEmpty
            || !item.detectedDates.isEmpty
    }

    private func hasReceiptDetails(_ item: MediaItem) -> Bool {
        !item.receiptMerchant.isEmpty || !item.receiptAmount.isEmpty || item.receiptDate != nil
    }

    private func receiptSummary(for item: MediaItem) -> some View {
        Button { showsReceiptEditor = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "receipt.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.receiptMerchant.isEmpty ? L10n.text("영수증 정보") : item.receiptMerchant)
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        if let date = item.receiptDate {
                            Text(L10n.date(date, dateStyle: .numeric, timeStyle: .omitted))
                        }
                        if !item.receiptAmount.isEmpty { Text(item.receiptAmount) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func representativeTitle(_ action: RepresentativeMediaAction) -> String {
        switch action {
        case .shareAndComplete: L10n.text("공유하고 완료")
        case .copyAndComplete: L10n.text("복사하고 완료")
        case .openURL: L10n.text("Safari에서 열기")
        case .openQR: L10n.text("QR 열기")
        case .addEvent: L10n.text("일정 추가")
        case .call: L10n.text("전화")
        }
    }

    private func representativeSymbol(_ action: RepresentativeMediaAction) -> String {
        switch action {
        case .shareAndComplete: "square.and.arrow.up"
        case .copyAndComplete: "doc.on.doc"
        case .openURL: "safari"
        case .openQR: "qrcode"
        case .addEvent: "calendar.badge.plus"
        case .call: "phone.fill"
        }
    }

    private func perform(_ action: RepresentativeMediaAction, for item: MediaItem) {
        switch action {
        case .shareAndComplete: prepareShare(for: item, completeAfter: true)
        case .copyAndComplete: copyAndFinish(item.recognizedText, item: item)
        case .openURL:
            if let value = item.detectedURLs.first { openURL(value, item: item, completeAfter: false) }
        case .openQR:
            // Routed through the parser so a Wi-Fi or contact payload copies instead
            // of being handed to Safari as if it were a link.
            if let info = item.primaryQRContent,
               let error = QRActionRunner.perform(info, for: item, in: modelContext) {
                actionMessage = error
            }
        case .addEvent:
            if let date = item.detectedDates.first { addCalendarEvent(date, item: item, completeAfter: false) }
        case .call:
            if let value = item.detectedPhoneNumbers.first { call(value) }
        }
    }

    private func copyAndFinish(_ value: String, item: MediaItem) {
        MediaActionService.copy(value)
        finish(item)
    }

    private func openURL(_ value: String, item: MediaItem, completeAfter: Bool) {
        do {
            try MediaActionService.openURL(value)
            if completeAfter { finish(item) }
        } catch { actionMessage = error.localizedDescription }
    }

    private func call(_ value: String) {
        do { try MediaActionService.call(value) }
        catch { actionMessage = error.localizedDescription }
    }

    private func openAddress(_ value: String, item: MediaItem, completeAfter: Bool) {
        do {
            try MediaActionService.openAddress(value)
            if completeAfter { finish(item) }
        } catch { actionMessage = error.localizedDescription }
    }

    private func addCalendarEvent(_ date: Date, item: MediaItem, completeAfter: Bool) {
        Task {
            do {
                try await MediaActionService.addCalendarEvent(title: actionTitle(for: item), date: date)
                if completeAfter { finish(item) }
                else { actionMessage = L10n.text("캘린더에 일정을 추가했습니다.") }
            } catch { actionMessage = error.localizedDescription }
        }
    }

    private func addReminder(_ date: Date, item: MediaItem) {
        Task {
            do {
                try await MediaActionService.addReminder(title: actionTitle(for: item), date: date)
                actionMessage = L10n.text("미리알림을 추가했습니다.")
            } catch { actionMessage = error.localizedDescription }
        }
    }

    private func actionTitle(for item: MediaItem) -> String {
        if !item.receiptMerchant.isEmpty { return item.receiptMerchant }
        return item.recognizedText.split(separator: "\n").first.map(String.init) ?? L10n.text("SubGallery 사진")
    }

    private func exportToPhotos(_ item: MediaItem, completeAfter: Bool) {
        Task {
            do {
                try await MediaExportService.saveToPhotos([item])
                if completeAfter { finish(item) }
                else { actionMessage = L10n.text("Photos에 저장했습니다.") }
            } catch { actionMessage = error.localizedDescription }
        }
    }

    private func finish(_ item: MediaItem) {
        Task {
            await MediaLifecycleService.complete(item)
            try? modelContext.save()
            dismiss()
        }
    }

    private var albumMovePicker: some View {
        NavigationStack {
            List(albums) { album in
                Button {
                    current?.albumID = album.id
                    try? modelContext.save()
                    showsAlbumMove = false
                } label: {
                    HStack {
                        Text(album.displayName).foregroundStyle(.primary)
                        Spacer()
                        if current?.albumID == album.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
            }
            .navigationTitle(L10n.text("앨범으로 이동"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("취소")) { showsAlbumMove = false } }
            }
        }
        .presentationDetents([.large])
    }

    private func completeCurrent() {
        guard let current else { return }
        finish(current)
    }

    private func deleteCurrent() {
        guard let current else { return }
        if isRecentlyDeleted {
            Task {
                await MediaLifecycleService.permanentlyDelete(current, from: modelContext)
                try? modelContext.save()
                dismiss()
            }
        } else {
            Task {
                await MediaLifecycleService.moveToRecentlyDeleted(current)
                try? modelContext.save()
                dismiss()
            }
        }
    }
}

private struct ViewerPage: View {
    let item: MediaItem
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        Group {
            if item.kind == .video {
                VideoPlayer(player: AVPlayer(url: item.mediaURL))
            } else if let image = UIImage(contentsOfFile: item.mediaURL.path) {
                Image(uiImage: image)
                    .resizable().scaledToFit().scaleEffect(scale)
                    .gesture(MagnifyGesture().onChanged { value in scale = min(max(lastScale * value.magnification, 1), 6) }
                        .onEnded { _ in lastScale = scale })
                    .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2; lastScale = scale } }
            } else {
                ContentUnavailableView(L10n.text("파일을 열 수 없음"), systemImage: "exclamationmark.triangle")
            }
        }
    }
}

/// Shared with the receipt template: OCR is fallible, so correcting it must be one
/// tap from wherever the wrong value is shown.
struct ReceiptDetailsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem
    @State private var merchant: String
    @State private var amount: String
    @State private var includesDate: Bool
    @State private var date: Date

    init(item: MediaItem) {
        self.item = item
        _merchant = State(initialValue: item.receiptMerchant)
        _amount = State(initialValue: item.receiptAmount)
        _includesDate = State(initialValue: item.receiptDate != nil)
        _date = State(initialValue: item.receiptDate ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.text("상호명"), text: $merchant)
                    TextField(L10n.text("금액"), text: $amount)
                        .keyboardType(.decimalPad)
                    Toggle(L10n.text("날짜"), isOn: $includesDate)
                    if includesDate {
                        DatePicker(L10n.text("날짜"), selection: $date, displayedComponents: .date)
                    }
                } footer: {
                    Text(L10n.text("인식 결과가 정확하지 않으면 직접 수정할 수 있습니다."))
                }
            }
            .navigationTitle(L10n.text("영수증 정보"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("취소")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("저장")) {
                        let newMerchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
                        let newAmount = amount.trimmingCharacters(in: .whitespacesAndNewlines)
                        let newDate = includesDate ? date : nil
                        // Only fields the user actually changed become protected, so
                        // opening the editor and cancelling out does not freeze values
                        // that automatic extraction could still improve.
                        if newMerchant != item.receiptMerchant { item.receiptMerchantManuallyEdited = true }
                        if newAmount != item.receiptAmount { item.receiptAmountManuallyEdited = true }
                        if newDate != item.receiptDate { item.receiptDateManuallyEdited = true }
                        item.receiptMerchant = newMerchant
                        item.receiptAmount = newAmount
                        item.receiptDate = newDate
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct MediaInfoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem
    @State private var metadataEntries: [MediaMetadataEntry] = []
    @State private var isCreatingCleanCopy = false
    @State private var metadataMessage: String?
    @StateObject private var purchases = PurchaseManager.shared
    @State private var showsPremium = false

    var body: some View {
        NavigationStack {
            List {
                LabeledContent(L10n.text("촬영 날짜"), value: L10n.date(item.createdAt))
                LabeledContent(L10n.text("가져온 날짜"), value: L10n.date(item.importedAt))
                LabeledContent("크기", value: ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                LabeledContent("해상도", value: "\(item.width) × \(item.height)")
                LabeledContent("파일 형식", value: URL(fileURLWithPath: item.localPath).pathExtension.uppercased())
                if item.kind == .video { LabeledContent("길이", value: Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))) }
                LabeledContent("보관 상태", value: RetentionService.statusText(for: item))
                if item.isPinned { LabeledContent("고정", value: L10n.text("켜짐")) }
                if let reminder = item.reminderDate { LabeledContent(L10n.text("다시 알림"), value: L10n.date(reminder)) }
                if item.kind == .photo {
                    LabeledContent("텍스트 인식", value: ocrStatusText)
                    if !item.recognizedText.isEmpty {
                        Section(L10n.text("인식된 텍스트")) { Text(item.recognizedText).textSelection(.enabled) }
                    }
                    Button(L10n.text("텍스트 다시 인식")) {
                        OCRService.enqueue(item, in: modelContext, force: true)
                    }
                    .disabled(item.ocrStatus == .processing)
                }
                if !metadataEntries.isEmpty {
                    Section(L10n.text("촬영 메타데이터")) {
                        ForEach(metadataEntries) { entry in
                            LabeledContent(L10n.text(entry.title), value: entry.value)
                        }
                    }
                }
                Section(L10n.text("개인정보 보호")) {
                    Button {
                        if purchases.isPremium { createMetadataFreeCopy() }
                        else { showsPremium = true }
                    } label: {
                        Label(
                            L10n.text("메타데이터 제거본 만들기"),
                            systemImage: purchases.isPremium ? "shield.lefthalf.filled" : "lock.fill"
                        )
                    }
                    .disabled(isCreatingCleanCopy)
                    if isCreatingCleanCopy { ProgressView("제거본 만드는 중…") }
                    Text(L10n.text("위치, 카메라, 렌즈와 촬영 정보를 제거한 새 파일을 만듭니다. 원본은 유지됩니다."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.text("정보"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("완료")) { dismiss() } } }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showsPremium) { PremiumView() }
        .task {
            guard item.kind == .photo else { return }
            metadataEntries = await MediaStorage.shared.detailedMetadata(for: item.localPath)
        }
        .alert(L10n.text("개인정보 보호"), isPresented: Binding(
            get: { metadataMessage != nil },
            set: { if !$0 { metadataMessage = nil } }
        )) {
            Button(L10n.text("확인"), role: .cancel) { }
        } message: {
            Text(metadataMessage ?? "")
        }
    }

    private func createMetadataFreeCopy() {
        isCreatingCleanCopy = true
        Task {
            do {
                let stored = try await MediaExportService.metadataFreeCopy(of: item)
                await MainActor.run {
                    let copy = MediaItem(
                        kind: item.kind,
                        source: item.source,
                        localPath: stored.relativePath,
                        thumbnailPath: stored.thumbnailRelativePath,
                        fileName: stored.fileName,
                        createdAt: .now,
                        albumID: item.albumID,
                        expirationDate: item.expirationDate,
                        fileSize: stored.fileSize,
                        width: stored.width,
                        height: stored.height,
                        duration: stored.duration
                    )
                    copy.expirationTypeRaw = item.expirationTypeRaw
                    copy.waitingForCompletion = item.waitingForCompletion
                    copy.isPinned = item.isPinned
                    copy.note = item.note
                    copy.latitude = nil
                    copy.longitude = nil
                    modelContext.insert(copy)
                    try? modelContext.save()
                    if copy.kind == .photo { OCRService.enqueue(copy, in: modelContext) }
                    isCreatingCleanCopy = false
                    metadataMessage = L10n.text("메타데이터를 제거한 새 파일을 저장했습니다.")
                }
            } catch {
                await MainActor.run {
                    isCreatingCleanCopy = false
                    metadataMessage = error.localizedDescription
                }
            }
        }
    }

    private var ocrStatusText: String {
        switch item.ocrStatus {
        case .pending: L10n.text("대기 중")
        case .processing: L10n.text("처리 중")
        case .completed: L10n.text(item.recognizedText.isEmpty ? "인식된 글자 없음" : "완료")
        case .failed: L10n.text("인식 안 됨")
        case .notApplicable: L10n.text("해당 없음")
        }
    }
}

struct RetentionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem
    @State private var customDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(RetentionPolicy.allCases.filter { $0 != .customDate }) { policy in
                        Button {
                            RetentionService.apply(policy, to: item)
                            try? modelContext.save()
                            dismiss()
                        } label: {
                            HStack {
                                Text(policy.title).foregroundStyle(.primary)
                                Spacer()
                                if item.expirationType == policy { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }

                Section(L10n.text("날짜 지정")) {
                    DatePicker(L10n.text("보관 기한"), selection: $customDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    Button(L10n.text("이 날짜까지 보관")) {
                        RetentionService.apply(.customDate, customDate: customDate, to: item)
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
            .navigationTitle(L10n.text("보관 기간"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("취소")) { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

struct ReminderPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem
    @State private var customDate = Date.now.addingTimeInterval(60 * 60)
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
                        Button(L10n.text("5초 후 (테스트)")) { schedule(at: .now.addingTimeInterval(5)) }
                    }
                    #endif
                    ForEach(ReminderDateOption.allCases) { option in
                        Button(option.title) { schedule(at: option.date()) }
                    }
                } footer: {
                    Text(L10n.text("처음 사용할 때만 알림 권한을 요청합니다. 알림을 누르면 이 사진이 바로 열립니다."))
                }

                Section(L10n.text("날짜 및 시간 선택")) {
                    DatePicker(L10n.text("알림 시간"), selection: $customDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    Button(L10n.text("이 시간에 알리기")) { schedule(at: customDate) }
                }

                if item.reminderDate != nil {
                    Section {
                        Button(L10n.text("알림 취소"), role: .destructive) { cancel() }
                    }
                }
            }
            .navigationTitle(L10n.text("다시 알려주기"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("취소")) { dismiss() } } }
        }
        .presentationDetents([.large])
        .alert(L10n.text("알림을 설정할 수 없음"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.text("확인"), role: .cancel) { }
            Button(L10n.text("설정 열기")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        } message: { Text(errorMessage ?? L10n.text("알 수 없는 오류")) }
    }

    private func schedule(at date: Date) {
        Task {
            do {
                let identifier = try await ReminderService.shared.schedule(for: item, at: date)
                item.reminderDate = date
                item.reminderIdentifier = identifier
                try? modelContext.save()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancel() {
        Task {
            await ReminderService.shared.cancel(for: item)
            item.reminderDate = nil
            item.reminderIdentifier = nil
            try? modelContext.save()
            dismiss()
        }
    }
}
