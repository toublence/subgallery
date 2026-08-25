import PDFKit
import PhotosUI
import SwiftData
import SwiftUI

struct DocumentBuilderView: View {
    private enum Stage {
        case selecting
        case arranging
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var purchases = PurchaseManager.shared
    let sourceItems: [MediaItem]

    @State private var stage: Stage = .selecting
    @State private var selection = Set<UUID>()
    @State private var pages: [DocumentPage] = []
    @State private var title = DocumentBuilderService.defaultTitle()
    @State private var isBuilding = false
    @State private var builtDocument: Document?
    @State private var showsScanner = false
    @State private var showsAddMenu = false
    @State private var photosSelection: [PhotosPickerItem] = []
    @State private var message: String?
    @State private var showsFreeLimitNotice = false

    /// Only images can become pages; a video has nothing to print.
    private var candidates: [MediaItem] {
        sourceItems.filter { $0.kind == .photo && $0.deletedAt == nil }
    }

    private var remainingFreeUses: Int { DocumentBuilderUsageStore.remaining }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .selecting: selectionStage
                case .arranging: arrangeStage
                }
            }
            .navigationTitle(L10n.text("문서 만들기"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .interactiveDismissDisabled(isBuilding)
        .fullScreenCover(isPresented: $showsScanner) {
            DocumentScannerView { images in
                appendScanned(images)
            }
        }
        .sheet(item: $builtDocument) { document in
            DocumentCompletionView(document: document) { dismiss() }
        }
        .onChange(of: photosSelection) { _, selected in importPhotos(selected) }
        .alert(L10n.text("문서 만들기"), isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button(L10n.text("확인"), role: .cancel) { }
        } message: {
            Text(message ?? "")
        }
        .alert(L10n.text("무료 문서 만들기를 모두 사용했습니다."), isPresented: $showsFreeLimitNotice) {
            Button(L10n.text("확인"), role: .cancel) { }
        } message: {
            Text(L10n.text("다음 문서부터 Premium이 필요합니다."))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.text("취소")) { dismiss() }
                .disabled(isBuilding)
        }
        ToolbarItem(placement: .confirmationAction) {
            switch stage {
            case .selecting:
                Button(L10n.text("다음")) { beginArranging() }
                    .disabled(selection.isEmpty)
            case .arranging:
                Button(L10n.text("만들기")) { build() }
                    .disabled(pages.isEmpty || isBuilding)
            }
        }
    }

    // MARK: - Stage 1

    private var selectionStage: some View {
        ScrollView {
            LazyVGrid(columns: TemplateGridLayout.columns, spacing: 12) {
                ForEach(candidates) { item in
                    selectionCell(item)
                }
            }
            .padding(16)
        }
        .overlay {
            if candidates.isEmpty {
                ContentUnavailableView {
                    Label(L10n.text("문서 사진이 없습니다."), systemImage: "doc.text")
                } description: {
                    Text(L10n.text("문서를 스캔하거나 사진을 가져오면 여기에서 선택할 수 있습니다."))
                } actions: {
                    Button(L10n.text("문서 스캔")) { showsScanner = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { stageFooter(L10n.format("%d페이지 선택됨", selection.count)) }
    }

    private func selectionCell(_ item: MediaItem) -> some View {
        let isSelected = selection.contains(item.id)
        return Button {
            if isSelected { selection.remove(item.id) } else { selection.insert(item.id) }
        } label: {
            // `aspectRatio(_, contentMode: .fill)` asks for MORE space than the cell
            // offers, so the image spilled over its neighbour. A clear box sets the
            // size first and the thumbnail fills that instead.
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay { MediaThumbnail(item: item) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                        .shadow(radius: 2)
                        .padding(6)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Stage 2

    private var arrangeStage: some View {
        List {
            Section {
                TextField(L10n.text("문서 이름"), text: $title)
                    .textInputAutocapitalization(.never)
            } header: {
                Text(L10n.text("문서 이름"))
            }

            Section {
                // Drag to reorder: the row order is the page order in the PDF.
                ForEach(pages) { page in
                    pageRow(page)
                }
                .onMove { pages.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { pages.remove(atOffsets: $0) }
            } header: {
                Text(L10n.format("%d페이지", pages.count))
            } footer: {
                Text(L10n.text("끌어서 페이지 순서를 바꿀 수 있습니다."))
            }

            Section {
                Button(L10n.text("문서 스캔"), systemImage: "doc.viewfinder") { showsScanner = true }
                PhotosPicker(selection: $photosSelection, maxSelectionCount: 0, matching: .images) {
                    Label(L10n.text("사진 가져오기"), systemImage: "photo.badge.plus")
                }
            } header: {
                Text(L10n.text("페이지 추가"))
            }
        }
        .environment(\.editMode, .constant(.active))
        .safeAreaInset(edge: .bottom) { stageFooter(nil) }
        .overlay {
            if isBuilding {
                ProgressView(L10n.text("문서를 만드는 중…"))
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func pageRow(_ page: DocumentPage) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: DocumentBuilderService.renderedImage(for: page))
                .resizable()
                .scaledToFill()
                .frame(width: 54, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if let index = pages.firstIndex(of: page) {
                Text(L10n.format("%d페이지", index + 1))
                    .font(.subheadline)
            }
            Spacer(minLength: 0)

            Button {
                rotate(page)
            } label: {
                Image(systemName: "rotate.right")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.text("회전"))

            Menu {
                Picker(L10n.text("보정"), selection: renderingBinding(for: page)) {
                    ForEach(DocumentPage.Rendering.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Image(systemName: "wand.and.rays")
            }
            .accessibilityLabel(L10n.text("보정"))
        }
    }

    @ViewBuilder
    private func stageFooter(_ caption: String?) -> some View {
        VStack(spacing: 4) {
            if let caption {
                Text(caption).font(.subheadline)
            }
            if !purchases.isPremium {
                // Deliberately a quiet line, not a banner: the document work matters
                // more than the upsell.
                Text(L10n.format("무료 문서 만들기 %d회 남음", remainingFreeUses))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Behaviour

    private func renderingBinding(for page: DocumentPage) -> Binding<DocumentPage.Rendering> {
        Binding(
            get: { pages.first { $0.id == page.id }?.rendering ?? .original },
            set: { value in
                guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
                pages[index].rendering = value
            }
        )
    }

    private func rotate(_ page: DocumentPage) {
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
        pages[index].rotation = (pages[index].rotation + 90) % 360
    }

    private func beginArranging() {
        let ordered = candidates.filter { selection.contains($0.id) }
        pages = ordered.compactMap { item in
            guard let image = UIImage(contentsOfFile: item.mediaURL.path) else { return nil }
            return DocumentPage(image: image, sourceItemID: item.id)
        }
        guard !pages.isEmpty else {
            message = DocumentBuilderError.noPages.errorDescription
            return
        }
        stage = .arranging
    }

    private func appendScanned(_ images: [UIImage]) {
        pages.append(contentsOf: images.map { DocumentPage(image: $0) })
        if stage == .selecting, !pages.isEmpty { stage = .arranging }
    }

    private func importPhotos(_ selected: [PhotosPickerItem]) {
        guard !selected.isEmpty else { return }
        Task {
            defer { photosSelection = [] }
            var loaded: [UIImage] = []
            for pick in selected {
                guard let data = try? await pick.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { continue }
                loaded.append(image)
            }
            await MainActor.run { appendScanned(loaded) }
        }
    }

    private func build() {
        guard !pages.isEmpty else {
            message = DocumentBuilderError.noPages.errorDescription
            return
        }
        isBuilding = true
        let snapshot = pages
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = name.isEmpty ? DocumentBuilderService.defaultTitle() : name

        Task {
            do {
                let built = try await DocumentBuilderService.build(pages: snapshot, title: finalTitle)
                await MainActor.run {
                    let document = Document(
                        title: finalTitle,
                        pageCount: built.pageCount,
                        pdfRelativePath: built.pdfRelativePath,
                        thumbnailRelativePath: built.thumbnailRelativePath,
                        recognizedText: built.recognizedText,
                        sourceItemIDs: snapshot.compactMap(\.sourceItemID)
                    )
                    modelContext.insert(document)
                    do {
                        try modelContext.save()
                    } catch {
                        // Nothing was persisted, so this is not a completed build and
                        // must not spend a free use.
                        DocumentBuilderService.remove(document)
                        isBuilding = false
                        message = DocumentBuilderError.writeFailed.errorDescription
                        return
                    }

                    let wasLastFreeUse = DocumentBuilderUsageStore.isLastFreeUse(
                        isPremium: purchases.isPremium
                    )
                    DocumentBuilderUsageStore.recordSuccessfulBuild(isPremium: purchases.isPremium)
                    isBuilding = false
                    builtDocument = document
                    if wasLastFreeUse { showsFreeLimitNotice = true }
                }
            } catch {
                await MainActor.run {
                    isBuilding = false
                    message = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Completion

struct DocumentCompletionView: View {
    @Environment(\.dismiss) private var dismiss
    let document: Document
    var onFinish: () -> Void

    @State private var showsViewer = false
    @State private var showsShare = false
    @State private var showsFilesExporter = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Color.accentColor)
                VStack(spacing: 4) {
                    Text(L10n.text("문서가 만들어졌습니다."))
                        .font(.title3.bold())
                    Text(L10n.format("%d페이지", document.pageCount))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 10) {
                    Button(L10n.text("PDF 열기"), systemImage: "doc.text.magnifyingglass") {
                        showsViewer = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button(L10n.text("공유"), systemImage: "square.and.arrow.up") { showsShare = true }
                    Button(L10n.text("파일에 저장"), systemImage: "folder") { showsFilesExporter = true }
                }
                .controlSize(.large)
                Spacer()
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("완료")) {
                        dismiss()
                        onFinish()
                    }
                }
            }
        }
        .sheet(isPresented: $showsViewer) { PDFDocumentViewer(document: document) }
        .sheet(isPresented: $showsShare) { ActivityShareSheet(urls: [document.pdfURL]) }
        .sheet(isPresented: $showsFilesExporter) { FilesExportPicker(urls: [document.pdfURL]) }
    }
}

struct DocumentTextView: View {
    @Environment(\.dismiss) private var dismiss
    let document: Document
    @State private var query = ""

    private var lines: [String] {
        let all = document.recognizedText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).textSelection(.enabled)
                }
            }
            .searchable(text: $query, prompt: L10n.text("텍스트 검색"))
            .overlay {
                if lines.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle(L10n.text("인식된 텍스트"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("닫기")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("전체 복사")) {
                        MediaActionService.copy(document.recognizedText)
                    }
                }
            }
        }
    }
}


// MARK: - List card

struct DocumentCard: View {
    let document: Document

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(L10n.format("%d페이지", document.pageCount)) · PDF")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.date(document.createdAt, dateStyle: .abbreviated, timeStyle: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var preview: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay { previewContent }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var previewContent: some View {
        Group {
            if let url = document.thumbnailURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "doc.richtext")
                    .resizable()
                    .scaledToFit()
                    .padding(30)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .topTrailing) {
            // Marks the card as a finished document rather than a photo.
            Image(systemName: "doc.fill")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(5)
                .background(.black.opacity(0.4), in: Circle())
                .padding(6)
        }
    }
}
