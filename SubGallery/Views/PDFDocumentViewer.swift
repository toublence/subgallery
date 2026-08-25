import PDFKit
import SwiftData
import SwiftUI

/// Owns the `PDFView` so SwiftUI can read the current page and drive navigation
/// without rebuilding the view — recreating it would drop the scroll position and
/// re-render every page.
@MainActor
final class PDFViewerModel: ObservableObject {
    @Published private(set) var pageCount = 0
    @Published private(set) var currentPage = 1
    @Published private(set) var failedToOpen = false

    let pdfView = PDFView()
    private var pageObserver: NSObjectProtocol?

    func load(url: URL) {
        guard pdfView.document == nil else { return }
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            // No image fallback: a PDF that cannot be parsed is an error to report,
            // not something to paper over with a picture of it.
            failedToOpen = true
            return
        }

        pdfView.document = document
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        // The three settings that make this read as paper rather than a photo strip:
        // a grey deck behind the pages, a drop shadow on each sheet, and a real gap
        // between them.
        pdfView.pageShadowsEnabled = true
        pdfView.pageBreakMargins = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        pdfView.backgroundColor = .systemGray5
        // Scale bounds first: assigning them clears `autoScales`, so turning it on
        // afterwards is what makes the document fit the width when it opens.
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 8
        pdfView.autoScales = true

        pageCount = document.pageCount
        currentPage = 1

        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncCurrentPage() }
        }
    }

    func go(to pageNumber: Int) {
        guard let document = pdfView.document,
              let page = document.page(at: pageNumber - 1) else { return }
        pdfView.go(to: page)
        currentPage = pageNumber
    }

    private func syncCurrentPage() {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return }
        currentPage = document.index(for: page) + 1
    }

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
    }
}

struct PDFViewerRepresentable: UIViewRepresentable {
    let pdfView: PDFView

    func makeUIView(context: Context) -> PDFView { pdfView }
    func updateUIView(_ uiView: PDFView, context: Context) { }
}

/// PDFKit's own thumbnail strip: it renders lazily, so a long document does not
/// pay for pages the user never looks at, and tapping a thumbnail navigates the
/// attached `PDFView` for us.
struct PDFThumbnailStrip: UIViewRepresentable {
    let pdfView: PDFView
    let axis: NSLayoutConstraint.Axis
    var thumbnailSize = CGSize(width: 88, height: 112)

    func makeUIView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = pdfView
        view.layoutMode = axis == .vertical ? .vertical : .horizontal
        view.thumbnailSize = thumbnailSize
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ uiView: PDFThumbnailView, context: Context) {
        uiView.pdfView = pdfView
    }
}

// MARK: - Viewer

struct PDFDocumentViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var model = PDFViewerModel()
    let document: Document

    @State private var showsShare = false
    @State private var showsFilesExporter = false
    @State private var showsInfo = false
    @State private var showsPages = false
    @State private var showsRename = false
    @State private var showsDeleteConfirmation = false
    @State private var renameText = ""

    /// A sidebar only earns its space where there is genuinely room; in a narrow
    /// split or on iPhone the pages go into a sheet instead.
    private var showsSidebar: Bool {
        horizontalSizeClass == .regular && model.pageCount > 1
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.failedToOpen {
                    ContentUnavailableView {
                        Label(L10n.text("PDF를 열 수 없습니다."), systemImage: "doc.questionmark")
                    } description: {
                        Text(L10n.text("파일이 손상되었거나 옮겨졌을 수 있습니다."))
                    }
                } else {
                    content
                }
            }
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .top) { pageIndicator }
        }
        .onAppear { model.load(url: document.pdfURL) }
        .sheet(isPresented: $showsShare) { ActivityShareSheet(urls: [document.pdfURL]) }
        .sheet(isPresented: $showsFilesExporter) { FilesExportPicker(urls: [document.pdfURL]) }
        .sheet(isPresented: $showsInfo) { DocumentInfoView(document: document) }
        .sheet(isPresented: $showsPages) {
            NavigationStack {
                PDFThumbnailStrip(pdfView: model.pdfView, axis: .vertical, thumbnailSize: CGSize(width: 120, height: 160))
                    .navigationTitle(L10n.text("페이지"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.text("완료")) { showsPages = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .alert(L10n.text("이름 변경"), isPresented: $showsRename) {
            TextField(L10n.text("문서 이름"), text: $renameText)
            Button(L10n.text("저장")) { rename() }
            Button(L10n.text("취소"), role: .cancel) { }
        }
        .confirmationDialog(
            L10n.text("이 문서를 삭제할까요?"),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("삭제"), role: .destructive) { deleteDocument() }
            Button(L10n.text("취소"), role: .cancel) { }
        }
    }

    @ViewBuilder
    private var content: some View {
        if showsSidebar {
            HStack(spacing: 0) {
                PDFThumbnailStrip(pdfView: model.pdfView, axis: .vertical)
                    .frame(width: 132)
                Divider()
                PDFViewerRepresentable(pdfView: model.pdfView)
            }
            .ignoresSafeArea(edges: .bottom)
        } else {
            PDFViewerRepresentable(pdfView: model.pdfView)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private var pageIndicator: some View {
        if !model.failedToOpen, model.pageCount > 0 {
            Text("\(model.currentPage) / \(model.pageCount)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.text("닫기")) { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            // On iPhone the pages live behind a button so the document keeps the
            // full width.
            if !showsSidebar, model.pageCount > 1 {
                Button { showsPages = true } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .accessibilityLabel(L10n.text("페이지"))
            }
            Menu {
                Button(L10n.text("이름 변경"), systemImage: "pencil") {
                    renameText = document.title
                    showsRename = true
                }
                Button(L10n.text("공유"), systemImage: "square.and.arrow.up") { showsShare = true }
                Button(L10n.text("파일에 저장"), systemImage: "folder") { showsFilesExporter = true }
                Button(L10n.text("문서 정보"), systemImage: "info.circle") { showsInfo = true }
                Divider()
                Button(role: .destructive) { showsDeleteConfirmation = true } label: {
                    Label(L10n.text("삭제"), systemImage: "trash")
                }
            } label: {
                Label(L10n.text("문서 동작"), systemImage: "ellipsis.circle")
            }
        }
    }

    private func rename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        document.title = trimmed
        try? modelContext.save()
    }

    private func deleteDocument() {
        DocumentBuilderService.delete(document, from: modelContext)
        dismiss()
    }
}

// MARK: - Info

struct DocumentInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let document: Document

    private var fileSize: String {
        let values = try? document.pdfURL.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var body: some View {
        NavigationStack {
            List {
                LabeledContent(L10n.text("파일 이름")) { Text(document.pdfURL.lastPathComponent) }
                LabeledContent(L10n.text("형식")) { Text("PDF") }
                LabeledContent(L10n.text("페이지")) { Text(L10n.format("%d페이지", document.pageCount)) }
                LabeledContent(L10n.text("크기")) { Text(fileSize) }
                LabeledContent(L10n.text("생성일")) {
                    Text(L10n.date(document.createdAt, dateStyle: .long))
                }
            }
            .navigationTitle(L10n.text("문서 정보"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("완료")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
