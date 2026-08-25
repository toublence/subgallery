import PhotosUI
import SwiftData
import SwiftUI

enum ReceiptPeriod: String, CaseIterable, Identifiable {
    case all, thisMonth, lastMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.text("전체")
        case .thisMonth: L10n.text("이번 달")
        case .lastMonth: L10n.text("지난달")
        }
    }

    func contains(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch self {
        case .all: true
        case .thisMonth: calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .lastMonth:
            calendar.date(byAdding: .month, value: -1, to: now).map {
                calendar.isDate(date, equalTo: $0, toGranularity: .month)
            } ?? false
        }
    }
}

enum ReceiptSort: String, CaseIterable, Identifiable {
    case newest, oldest, amountHigh, amountLow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: L10n.text("최신순")
        case .oldest: L10n.text("오래된순")
        case .amountHigh: L10n.text("금액 높은순")
        case .amountLow: L10n.text("금액 낮은순")
        }
    }
}

struct ReceiptTemplateView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var allMedia: [MediaItem]
    @StateObject private var purchases = PurchaseManager.shared
    @Binding var isCameraPresented: Bool

    @AppStorage("receipt.sort") private var sortRaw = ReceiptSort.newest.rawValue
    @AppStorage("receipt.pinnedOnly") private var showsPinnedOnly = false

    @State private var searchText = ""
    @State private var detailItem: MediaItem?
    @State private var viewerItem: MediaItem?
    @State private var photosSelection: [PhotosPickerItem] = []
    @State private var showsPremium = false
    @State private var showsReport = false
    @State private var message: String?

    private var sort: ReceiptSort { ReceiptSort(rawValue: sortRaw) ?? .newest }

    private var allReceipts: [MediaItem] {
        allMedia.filter { $0.deletedAt == nil && $0.templatePurpose == .receipt }
    }

    /// The first screen is for finding a receipt, so it shows all of them; period
    /// analysis lives in the report.
    private var items: [MediaItem] {
        allReceipts
            .filter { !showsPinnedOnly || $0.isPinned }
            .filter(matchesSearch)
            .sorted(by: isOrderedBefore)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: TemplateGridLayout.columns, spacing: 12) {
                ForEach(items) { item in
                    ReceiptRow(item: item)
                        .padding(10)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    .contentShape(Rectangle())
                    .onTapGesture { detailItem = item }
                    .swipeActions(edge: .leading) {
                        Button {
                            item.isPinned.toggle()
                            try? modelContext.save()
                        } label: {
                            Label(
                                L10n.text(item.isPinned ? "고정 해제" : "고정"),
                                systemImage: item.isPinned ? "pin.slash" : "pin"
                            )
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing) {
                        Button { complete(item) } label: {
                            Label(L10n.text("완료"), systemImage: "checkmark.circle")
                        }
                        .tint(.green)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: L10n.text("상호, 금액, 사진 속 글자")
        )
        .navigationTitle(CapturePurpose.receipt.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { openReport() } label: {
                    Label(L10n.text("지출 리포트"), systemImage: "chart.bar.xaxis")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { optionsMenu }
        }
        .overlay { if allReceipts.isEmpty { emptyState } else if items.isEmpty { noResults } }
        .sheet(item: $detailItem) { item in
            ReceiptDetailView(item: item) { viewerItem = item }
        }
        .sheet(isPresented: $showsReport) {
            ReceiptReportView(receipts: allReceipts)
        }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewer(items: items, initialID: item.id, isRecentlyDeleted: false)
        }
        .sheet(isPresented: $showsPremium) {
            PremiumView(entryPoint: .receiptReport).presentationDetents([.large])
        }
        .onChange(of: purchases.isPremium) { _, isPremium in
            guard isPremium, showsPremium else { return }
            showsPremium = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showsReport = true
            }
        }
        .onChange(of: photosSelection) { _, selection in importPhotos(selection) }
        .alert(L10n.text("사진 작업"), isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button(L10n.text("확인"), role: .cancel) { }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: - Toolbar

    private var optionsMenu: some View {
        Menu {
            Picker(L10n.text("정렬"), selection: Binding(
                get: { sort },
                set: { sortRaw = $0.rawValue }
            )) {
                ForEach(ReceiptSort.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Toggle(L10n.text("고정만 보기"), isOn: Binding(
                get: { showsPinnedOnly },
                set: { showsPinnedOnly = $0 }
            ))
        } label: {
            Label(L10n.text("보기 옵션"), systemImage: "ellipsis.circle")
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.text("아직 저장된 영수증이 없습니다."), systemImage: "receipt")
        } description: {
            Text(L10n.text("영수증을 촬영하거나 가져오면 자동으로 정리됩니다."))
        } actions: {
            Button(L10n.text("영수증 촬영")) { isCameraPresented = true }
                .buttonStyle(.borderedProminent)
            PhotosPicker(
                selection: $photosSelection,
                maxSelectionCount: 0,
                matching: .images
            ) {
                Text(L10n.text("사진 가져오기"))
            }
        }
    }

    private var noResults: some View {
        ContentUnavailableView.search(text: searchText)
    }

    // MARK: - Behaviour

    private func matchesSearch(_ item: MediaItem) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return item.receiptMerchant.localizedCaseInsensitiveContains(query)
            || item.receiptAmount.localizedCaseInsensitiveContains(query)
            || item.recognizedText.localizedCaseInsensitiveContains(query)
            || L10n.date(item.receiptDisplayDate, dateStyle: .long, timeStyle: .omitted)
                .localizedCaseInsensitiveContains(query)
    }

    private func isOrderedBefore(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        switch sort {
        case .newest: lhs.receiptDisplayDate > rhs.receiptDisplayDate
        case .oldest: lhs.receiptDisplayDate < rhs.receiptDisplayDate
        case .amountHigh, .amountLow:
            orderedByAmount(lhs, rhs, ascending: sort == .amountLow)
        }
    }

    /// Receipts with no readable amount sort last in both directions — they are
    /// unknown, not zero.
    private func orderedByAmount(_ lhs: MediaItem, _ rhs: MediaItem, ascending: Bool) -> Bool {
        let left = ReceiptSummaryService.amount(for: lhs)?.value
        let right = ReceiptSummaryService.amount(for: rhs)?.value
        switch (left, right) {
        case let (leftValue?, rightValue?):
            return ascending ? leftValue < rightValue : leftValue > rightValue
        case (nil, _?): return false
        case (_?, nil): return true
        default: return lhs.receiptDisplayDate > rhs.receiptDisplayDate
        }
    }

    private func complete(_ item: MediaItem) {
        Task {
            await MediaLifecycleService.complete(item)
            try? modelContext.save()
        }
    }

    private func openReport() {
        if ReceiptReportUsageStore.canOpen(
            isPremium: purchases.isPremium,
            hasReceiptData: !allReceipts.isEmpty
        ) {
            showsReport = true
        } else {
            showsPremium = true
        }
    }

    private func importPhotos(_ selection: [PhotosPickerItem]) {
        guard !selection.isEmpty else { return }
        Task {
            defer { photosSelection = [] }
            for selectionItem in selection {
                do {
                    guard let data = try await selectionItem.loadTransferable(type: Data.self) else { continue }
                    let stored = try await MediaStorage.shared.store(
                        data: data,
                        type: selectionItem.supportedContentTypes.first
                    )
                    let item = MediaItem(
                        kind: stored.kind, source: .photos, localPath: stored.relativePath,
                        thumbnailPath: stored.thumbnailRelativePath, fileName: stored.fileName,
                        createdAt: stored.capturedAt ?? .now, fileSize: stored.fileSize,
                        width: stored.width, height: stored.height, duration: stored.duration
                    )
                    modelContext.insert(item)
                    try? modelContext.save()
                    // Left unclassified on purpose: the OCR pass files it into the
                    // receipt template itself, which is the flow being demonstrated.
                    OCRService.enqueue(item, in: modelContext)
                } catch {
                    message = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Row

struct ReceiptRow: View {
    let item: MediaItem

    private var amount: ReceiptAmount? {
        ReceiptSummaryService.amount(for: item)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Large enough to recognise which receipt this is at a glance — it is
            // the evidence, and a 44pt accessory made every receipt look alike.
            MediaThumbnail(item: item)
                .frame(width: 78, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(merchantTitle)
                        .font(.headline)
                        .foregroundStyle(item.receiptMerchant.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                }
                Text(amountTitle)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(amount == nil ? .secondary : .primary)
                    .lineLimit(1)
                Text(L10n.date(item.receiptDisplayDate, dateStyle: .abbreviated, timeStyle: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var merchantTitle: String {
        item.receiptMerchant.isEmpty ? L10n.text("상호 미확인") : item.receiptMerchant
    }

    private var amountTitle: String {
        amount?.formatted() ?? L10n.text("금액 확인 필요")
    }
}

/// The evidence shot, uncropped. `MediaThumbnail` fills its frame, which would
/// slice the top and bottom off a tall receipt — exactly the part that carries the
/// total and the date.
struct ReceiptImagePreview: View {
    let item: MediaItem

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: item.mediaURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                MediaThumbnail(item: item)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 340)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Detail

struct ReceiptDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem
    var onShowOriginal: () -> Void

    @State private var showsEditor = false
    @State private var showsRetention = false
    @State private var showsCompleteConfirmation = false
    @State private var showsDeleteConfirmation = false
    @State private var showsShareSheet = false
    @State private var message: String?

    private var amount: ReceiptAmount? {
        ReceiptSummaryService.amount(for: item)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.receiptMerchant.isEmpty ? L10n.text("상호 미확인") : item.receiptMerchant)
                            .font(.title3.bold())
                            .foregroundStyle(item.receiptMerchant.isEmpty ? .secondary : .primary)
                        Text(amount?.formatted() ?? L10n.text("금액 확인 필요"))
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .foregroundStyle(amount == nil ? .secondary : .primary)
                        Text(L10n.date(item.receiptDisplayDate, dateStyle: .long, timeStyle: .omitted))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Button {
                        dismiss()
                        onShowOriginal()
                    } label: {
                        ReceiptImagePreview(item: item)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } footer: {
                    Text(L10n.text("이미지를 누르면 원본을 크게 볼 수 있습니다."))
                }

                Section {
                    LabeledContent(L10n.text("상호")) {
                        Text(item.receiptMerchant.isEmpty ? L10n.text("상호 미확인") : item.receiptMerchant)
                    }
                    LabeledContent(L10n.text("금액")) {
                        Text(amount?.formatted() ?? L10n.text("금액 확인 필요"))
                    }
                    LabeledContent(L10n.text("날짜")) {
                        Text(L10n.date(item.receiptDisplayDate, dateStyle: .long, timeStyle: .omitted))
                    }
                    Button(L10n.text("정보 수정"), systemImage: "pencil") { showsEditor = true }
                } footer: {
                    Text(L10n.text("인식 결과가 정확하지 않으면 직접 수정할 수 있습니다."))
                }

                Section {
                    LabeledContent(L10n.text("보관")) {
                        Text(RetentionService.statusText(for: item))
                    }
                    Button(L10n.text("보관 기간 변경"), systemImage: "clock") { showsRetention = true }
                    Button {
                        item.isPinned.toggle()
                        try? modelContext.save()
                    } label: {
                        Label(
                            L10n.text(item.isPinned ? "고정 해제" : "고정"),
                            systemImage: item.isPinned ? "pin.slash" : "pin"
                        )
                    }
                }

                Section {
                    Button(L10n.text("완료 처리"), systemImage: "checkmark.circle.fill") {
                        showsCompleteConfirmation = true
                    }
                } footer: {
                    Text(L10n.text("완료한 사진은 최근 삭제로 이동하며 7일 동안 복구할 수 있습니다."))
                }

                Section {
                    Button(L10n.text("공유"), systemImage: "square.and.arrow.up") { showsShareSheet = true }
                    Button(L10n.text("사진 앱에 저장"), systemImage: "photo.badge.arrow.down") {
                        exportToPhotos()
                    }
                    Button(role: .destructive) { showsDeleteConfirmation = true } label: {
                        Label(L10n.text("삭제"), systemImage: "trash")
                    }
                }
            }
            .navigationTitle(L10n.text("영수증"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("완료")) { dismiss() } }
            }
        }
        .sheet(isPresented: $showsEditor) { ReceiptDetailsEditorView(item: item) }
        .sheet(isPresented: $showsRetention) { RetentionPickerView(item: item) }
        .sheet(isPresented: $showsShareSheet) { ActivityShareSheet(urls: [item.mediaURL]) }
        .confirmationDialog(
            L10n.text("이 사진을 완료 처리할까요?"),
            isPresented: $showsCompleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("완료 처리")) {
                Task {
                    await MediaLifecycleService.complete(item)
                    try? modelContext.save()
                    dismiss()
                }
            }
            Button(L10n.text("취소"), role: .cancel) { }
        }
        .confirmationDialog(
            L10n.text("이 사진을 삭제할까요?"),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("삭제"), role: .destructive) {
                Task {
                    await MediaLifecycleService.moveToRecentlyDeleted(item)
                    try? modelContext.save()
                    dismiss()
                }
            }
            Button(L10n.text("취소"), role: .cancel) { }
        }
        .alert(L10n.text("사진 작업"), isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button(L10n.text("확인"), role: .cancel) { }
        } message: {
            Text(message ?? "")
        }
    }

    private func exportToPhotos() {
        Task {
            do {
                try await MediaExportService.saveToPhotos([item])
                message = L10n.text("사진 앱에 저장했습니다.")
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
