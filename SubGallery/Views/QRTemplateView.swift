import SwiftData
import SwiftUI
import UIKit

/// Runs a parsed QR's action and reports failures, so the row and the detail
/// screen share one implementation instead of each re-deriving what to do.
@MainActor
enum QRActionRunner {
    /// Passing the item marks it used on success. Any deliberate use counts, not
    /// just opening a link — a Wi-Fi or contact QR has no "open" to speak of, and
    /// copying it is the same act of having dealt with the code.
    @discardableResult
    static func perform(
        _ info: QRContentInfo,
        for item: MediaItem? = nil,
        in context: ModelContext? = nil
    ) -> String? {
        do {
            switch info.primaryAction {
            case .open: try MediaActionService.openURL(info.actionValue)
            case .copy: MediaActionService.copy(info.actionValue)
            case .call: try MediaActionService.call(info.actionValue)
            case .mail: try MediaActionService.openMail(info.actionValue)
            case .message: try MediaActionService.openMessage(info.actionValue)
            case .map:
                guard let coordinate = info.coordinate else { throw MediaActionError.invalidValue }
                MediaActionService.openLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    name: info.title
                )
            }
            if let item { markUsed(item, in: context) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func markUsed(_ item: MediaItem, in context: ModelContext?) {
        guard item.qrOpenedAt == nil else { return }
        item.qrOpenedAt = .now
        try? context?.save()
    }

    static func clearUsed(_ item: MediaItem, in context: ModelContext?) {
        item.qrOpenedAt = nil
        try? context?.save()
    }
}

extension MediaItem {
    /// Every payload found in the shot, parsed. The first one represents the item
    /// in list contexts; the detail screen shows them all.
    var qrContents: [QRContentInfo] {
        QRContentService.parseAll(detectedQRCodes)
    }

    var primaryQRContent: QRContentInfo? { qrContents.first }
}

enum TemplateGridLayout {
    /// QR and receipt template albums use three columns on iPad and two on iPhone.
    static var columns: [GridItem] {
        let count = UIDevice.current.userInterfaceIdiom == .pad ? 3 : 2
        return Array(
            repeating: GridItem(.flexible(), spacing: 12),
            count: count
        )
    }
}

// MARK: - Grid card

struct QRInfoCard: View {
    let item: MediaItem
    let isSelecting: Bool
    let isSelected: Bool
    let open: () -> Void
    let runAction: (QRContentInfo) -> Void

    private var info: QRContentInfo? { item.primaryQRContent }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                header
                Text(info?.title ?? L10n.text("QR 코드"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item.isQRUsed ? .secondary : .primary)
                    .lineLimit(1)
                if let subtitle = info?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(L10n.date(item.createdAt, dateStyle: .abbreviated, timeStyle: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let info, !isSelecting { actionButton(info) }
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
        .onTapGesture(perform: open)
        .accessibilityAddTraits(isSelecting && isSelected ? .isSelected : [])
        .accessibilityAction { open() }
    }

    private var thumbnail: some View {
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
                }
            }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: (info?.type ?? .unknown).symbol)
                .font(.caption2)
            Text((info?.type ?? .unknown).title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
            if item.detectedQRCodes.count > 1 {
                Text("· \(item.detectedQRCodes.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: item.isQRUsed ? "checkmark.circle.fill" : "circle.dotted")
                .font(.caption2)
                .foregroundStyle(item.isQRUsed ? Color.secondary : Color.orange)
        }
        .foregroundStyle(Color.accentColor)
    }

    private func actionButton(_ info: QRContentInfo) -> some View {
        Button { runAction(info) } label: {
            Text(info.primaryAction.title)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .accessibilityLabel("\(info.primaryAction.title) · \(info.title)")
    }
}

// MARK: - Detail

struct QRDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem
    var onShowOriginal: () -> Void

    @State private var message: String?
    @State private var revealedFields = Set<String>()
    @State private var showsCompleteConfirmation = false
    @State private var shareValue: String?

    private var contents: [QRContentInfo] { item.qrContents }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        MediaThumbnail(item: item)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.date(item.createdAt, dateStyle: .long))
                                .font(.subheadline)
                            Text(RetentionService.statusText(for: item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    if let openedAt = item.qrOpenedAt {
                        LabeledContent(L10n.text("확인함")) {
                            Text(L10n.date(openedAt))
                        }
                        Button(L10n.text("미확인으로 표시"), systemImage: "arrow.uturn.backward") {
                            QRActionRunner.clearUsed(item, in: modelContext)
                        }
                    } else {
                        Button(L10n.text("확인함으로 표시"), systemImage: "checkmark.circle") {
                            QRActionRunner.markUsed(item, in: modelContext)
                        }
                    }
                    Button(L10n.text("원본 사진 보기"), systemImage: "photo") {
                        dismiss()
                        onShowOriginal()
                    }
                }

                ForEach(Array(contents.enumerated()), id: \.offset) { _, info in
                    contentSection(info)
                }

                Section {
                    Button(L10n.text("완료 처리"), systemImage: "checkmark.circle.fill") {
                        showsCompleteConfirmation = true
                    }
                } footer: {
                    Text(L10n.text("완료한 사진은 최근 삭제로 이동하며 7일 동안 복구할 수 있습니다."))
                }
            }
            .navigationTitle(L10n.text("QR 정보"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("완료")) { dismiss() }
                }
            }
        }
        .sheet(item: Binding(
            get: { shareValue.map(ShareableText.init) },
            set: { if $0 == nil { shareValue = nil } }
        )) { shareable in
            ActivityShareSheet(urls: [], text: shareable.value)
        }
        .confirmationDialog(
            L10n.text("이 사진을 완료 처리할까요?"),
            isPresented: $showsCompleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("완료 처리")) { complete() }
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

    @ViewBuilder
    private func contentSection(_ info: QRContentInfo) -> some View {
        Section {
            ForEach(info.fields) { field in
                fieldRow(info: info, field: field)
            }

            Button {
                if let error = QRActionRunner.perform(info, for: item, in: modelContext) {
                    message = error
                }
            } label: {
                Label(info.primaryAction.title, systemImage: info.primaryAction.symbol)
            }

            Button(L10n.text("내용 복사"), systemImage: "doc.on.doc") {
                MediaActionService.copy(info.rawValue)
                QRActionRunner.markUsed(item, in: modelContext)
            }
            Button(L10n.text("공유"), systemImage: "square.and.arrow.up") {
                shareValue = info.rawValue
            }
            Button(L10n.format("%@ 후 완료", info.primaryAction.title), systemImage: "checkmark.circle") {
                if let error = QRActionRunner.perform(info, for: item, in: modelContext) {
                    message = error
                } else {
                    complete()
                }
            }
        } header: {
            Label(info.type.title, systemImage: info.type.symbol)
        }
    }

    @ViewBuilder
    private func fieldRow(info: QRContentInfo, field: QRContentInfo.Field) -> some View {
        if field.isSensitive && !revealedFields.contains(field.id) {
            // Passwords stay hidden until asked for, but remain copyable without
            // ever being displayed.
            HStack {
                Text(field.label)
                Spacer()
                Button(L10n.text("표시")) { revealedFields.insert(field.id) }
                    .font(.subheadline)
                Button {
                    MediaActionService.copy(field.value)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        } else {
            LabeledContent(field.label) {
                Text(field.value)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func complete() {
        Task {
            await MediaLifecycleService.complete(item)
            try? modelContext.save()
            dismiss()
        }
    }

    private struct ShareableText: Identifiable {
        let value: String
        var id: String { value }
    }
}
