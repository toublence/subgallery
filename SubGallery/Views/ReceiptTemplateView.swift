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
    @Binding var captureContext: CaptureContext

    @AppStorage("receipt.sort") private var sortRaw = ReceiptSort.newest.rawValue
    @AppStorage("receipt.pinnedOnly") private var showsPinnedOnly = false
    @AppStorage("privacy.stripMetadata") private var stripsMetadata = false

    @State private var searchText = ""
    @State private var detailItem: MediaItem?
    @State private var viewerItem: MediaItem?
    @State private var photosSelection: [PhotosPickerItem] = []
    @State private var showsPremium = false
    @State private var showsReport = false
    @State private var message: String?
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var showsRetentionSheet = false
    @State private var showsShareSheet = false
    @State private var showsFilesExporter = false
    @State private var preparedExportURLs: [URL] = []
    @State private var deleteConfirmation = false
    @State private var didLogOpen = false

    private var sort: ReceiptSort { ReceiptSort(rawValue: sortRaw) ?? .newest }

    private var selectedItems: [MediaItem] { items.filter { selection.contains($0.id) } }

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
                ForEach(items) { item in receiptCell(item) }
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
        .onSubmit(of: .search) {
            guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            SubGalleryAnalytics.searchPerformed(resultCount: items.count)
        }
        .onAppear {
            guard !didLogOpen else { return }
            didLogOpen = true
            SubGalleryAnalytics.templateOpen(.receipt)
        }
        .navigationTitle(CapturePurpose.receipt.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !isSelecting {
                CaptureInputControls(
                    selection: $photosSelection,
                    allowsVideos: false,
                    captureTitle: L10n.text("영수증 촬영"),
                    captureSymbol: "camera.fill",
                    captureAccessibilityLabel: L10n.text("영수증 촬영")
                ) {
                    captureContext = .template(.receipt)
                    isCameraPresented = true
                }
            }
        }
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.text(selection.count == items.count ? "전체 선택 해제" : "전체 선택")) {
                        if selection.count == items.count {
                            selection.removeAll()
                        } else {
                            selection = Set(items.map(\.id))
                        }
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !isSelecting {
                    Button { openReport() } label: {
                        Label(L10n.text("지출 리포트"), systemImage: "chart.bar.xaxis")
                    }
                    optionsMenu
                }
                Button(L10n.text(isSelecting ? "완료" : "선택")) {
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                }
                .disabled(items.isEmpty)
            }
            if isSelecting {
                ToolbarItemGroup(placement: .bottomBar) { batchActions }
            }
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
                SubGalleryAnalytics.receiptReportOpen()
                showsReport = true
            }
        }
        .sheet(isPresented: $showsRetentionSheet) {
            BatchRetentionPickerView(items: selectedItems) {
                endSelection()
                showsRetentionSheet = false
            }
        }
        .sheet(isPresented: $showsShareSheet, onDismiss: cleanupPreparedExport) {
            ActivityShareSheet(urls: preparedExportURLs) { completed in
                if completed {
                    SubGalleryAnalytics.mediaExported(
                        destination: .share,
                        metadataRemoved: stripsMetadata && purchases.isPremium
                    )
                }
            }
        }
        .sheet(isPresented: $showsFilesExporter, onDismiss: cleanupPreparedExport) {
            FilesExportPicker(urls: preparedExportURLs) { completed in
                if completed {
                    SubGalleryAnalytics.mediaExported(
                        destination: .files,
                        metadataRemoved: stripsMetadata && purchases.isPremium
                    )
                }
            }
        }
        .confirmationDialog(
            L10n.text("선택한 사진을 최근 삭제로 이동할까요?"),
            isPresented: $deleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("삭제"), role: .destructive) { deleteSelected() }
            Button(L10n.text("취소"), role: .cancel) { }
        }
        .onChange(of: items.map(\.id)) { _, ids in
            // Receipts leave this list when completed or deleted; drop them from the
            // selection so a batch action cannot target something no longer shown.
            selection.formIntersection(Set(ids))
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

    private var batchActions: some View {
        Menu {
            Button { saveSelectedToPhotos() } label: {
                Label(L10n.text("사진 앱에 저장"), systemImage: "photo.badge.arrow.down")
            }
            Button { prepareExport(selectedItems) { showsFilesExporter = true } } label: {
                Label(L10n.text("파일 앱으로 내보내기"), systemImage: "folder")
            }
            Button { prepareExport(selectedItems) { showsShareSheet = true } } label: {
                Label(L10n.text("공유"), systemImage: "square.and.arrow.up")
            }
            Divider()
            Button { showsRetentionSheet = true } label: {
                Label(L10n.text("보관 기간 변경"), systemImage: "clock")
            }
            Button { togglePinnedSelected() } label: {
                let removesPins = selectedItems.allSatisfy(\.isPinned)
                Label(
                    L10n.text(removesPins ? "고정 해제" : "고정"),
                    systemImage: removesPins ? "pin.slash" : "pin"
                )
            }
            Button { completeSelected() } label: {
                Label(L10n.text("완료 처리"), systemImage: "checkmark.circle")
            }
            Divider()
            Button(role: .destructive) { deleteConfirmation = true } label: {
                Label(L10n.text("삭제"), systemImage: "trash")
            }
        } label: {
            Label(L10n.format("%d개 작업", selection.count), systemImage: "ellipsis.circle")
        }
        .disabled(selection.isEmpty)
    }

    // MARK: - Selection

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func endSelection() {
        selection.removeAll()
        isSelecting = false
    }

    private func togglePinnedSelected() {
        let changing = selectedItems
        let shouldPin = !changing.allSatisfy(\.isPinned)
        changing.forEach { $0.isPinned = shouldPin }
        Task {
            // Unpinning can make an already-expired receipt due for cleanup, which
            // the pin was the only thing holding back.
            if !shouldPin {
                for item in changing where RetentionService.shouldMoveToRecentlyDeleted(item) {
                    await MediaLifecycleService.moveToRecentlyDeleted(item)
                }
            }
            try? modelContext.save()
            endSelection()
        }
    }

    private func completeSelected() {
        let completing = selectedItems
        Task {
            for item in completing { await MediaLifecycleService.complete(item) }
            try? modelContext.save()
            endSelection()
        }
    }

    private func deleteSelected() {
        let deleting = selectedItems
        Task {
            for item in deleting { await MediaLifecycleService.moveToRecentlyDeleted(item) }
            try? modelContext.save()
            endSelection()
        }
    }

    private func saveSelectedToPhotos() {
        let exporting = selectedItems
        Task {
            do {
                try await MediaExportService.saveToPhotos(exporting)
                message = L10n.format("%d개 항목을 Photos에 저장했습니다.", exporting.count)
                endSelection()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func prepareExport(_ exporting: [MediaItem], present: @escaping @MainActor () -> Void) {
        Task {
            do {
                let urls = try await MediaExportService.preparedURLs(
                    for: exporting,
                    strippingMetadata: stripsMetadata
                )
                await MainActor.run {
                    preparedExportURLs = urls
                    present()
                }
            } catch {
                await MainActor.run { message = error.localizedDescription }
            }
        }
    }

    private func cleanupPreparedExport() {
        MediaExportService.cleanupPreparedURLs(preparedExportURLs)
        preparedExportURLs = []
        endSelection()
    }

    /// Extracted so the grid body stays small enough for the type checker, which
    /// times out when the cell, its gestures and its menu are all inlined.
    @ViewBuilder
    private func receiptCell(_ item: MediaItem) -> some View {
        ReceiptGridCard(
            item: item,
            isSelecting: isSelecting,
            isSelected: selection.contains(item.id)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                toggle(item.id)
            } else {
                SubGalleryAnalytics.mediaOpened()
                detailItem = item
            }
        }
        // `swipeActions` only does anything inside a `List`; in a grid it compiles
        // and silently does nothing, so pin and complete live in the context menu.
        .contextMenu { cellMenu(item) }
    }

    @ViewBuilder
    private func cellMenu(_ item: MediaItem) -> some View {
        Button {
            item.isPinned.toggle()
            try? modelContext.save()
        } label: {
            Label(
                L10n.text(item.isPinned ? "고정 해제" : "고정"),
                systemImage: item.isPinned ? "pin.slash" : "pin"
            )
        }
        Button { complete(item) } label: {
            Label(L10n.text("완료"), systemImage: "checkmark.circle")
        }
        Button {
            SubGalleryAnalytics.mediaOpened()
            detailItem = item
        } label: {
            Label(L10n.text("정보 수정"), systemImage: "pencil")
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
            Button(L10n.text("영수증 촬영")) {
                captureContext = .template(.receipt)
                isCameraPresented = true
            }
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
            SubGalleryAnalytics.receiptReportOpen()
            showsReport = true
        } else {
            PremiumAnalytics.limitReached(.receiptReport)
            showsPremium = true
        }
    }

    private func importPhotos(_ selection: [PhotosPickerItem]) {
        guard !selection.isEmpty else { return }
        SubGalleryAnalytics.mediaAddStart(
            source: .photos, destination: .receipt,
            template: .receipt, kind: .photo
        )
        Task {
            defer { photosSelection = [] }
            for selectionItem in selection {
                do {
                    guard let data = try await selectionItem.loadTransferable(type: Data.self) else {
                        SubGalleryAnalytics.mediaAddFailed(
                            source: .photos, destination: .receipt,
                            template: .receipt, kind: .photo, reason: .decodeFailed
                        )
                        continue
                    }
                    let stored = try await MediaStorage.shared.store(
                        data: data,
                        type: selectionItem.supportedContentTypes.first
                    )
                    await MainActor.run {
                        let _ = TemplateCapturePipeline.insert(
                            stored, source: .photos, purpose: .receipt, in: modelContext
                        )
                        SubGalleryAnalytics.mediaAddSuccess(
                            source: .photos, destination: .receipt,
                            template: .receipt, kind: .photo
                        )
                    }
                } catch {
                    SubGalleryAnalytics.mediaAddFailed(
                        source: .photos, destination: .receipt,
                        template: .receipt, kind: .photo, reason: .storageFailed
                    )
                    message = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Row

/// Grid presentation for the receipt template. `ReceiptRow` stays as the
/// horizontal form used by the report's lists; a grid cell is too narrow for a
/// side-by-side thumbnail and text.
struct ReceiptGridCard: View {
    let item: MediaItem
    var isSelecting = false
    var isSelected = false

    private var amount: ReceiptAmount? {
        ReceiptSummaryService.amount(for: item)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MediaThumbnail(item: item)
                .frame(width: 72, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                            .shadow(radius: 2)
                            .padding(6)
                    } else if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.35), in: Circle())
                            .padding(5)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(merchantTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item.receiptMerchant.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Text(amountTitle)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(amount == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(L10n.date(item.receiptDisplayDate, dateStyle: .abbreviated, timeStyle: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var merchantTitle: String {
        item.receiptMerchant.isEmpty ? L10n.text("상호 미확인") : item.receiptMerchant
    }

    private var amountTitle: String {
        amount?.formatted() ?? L10n.text("금액 확인 필요")
    }
}

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
