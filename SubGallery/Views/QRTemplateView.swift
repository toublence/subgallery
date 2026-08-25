import SwiftData
import SwiftUI

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

// MARK: - List row

struct QRInfoRow: View {
    let item: MediaItem
    let isSelecting: Bool
    let isSelected: Bool
    let open: () -> Void
    let runAction: (QRContentInfo) -> Void

    private var info: QRContentInfo? { item.primaryQRContent }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: (info?.type ?? .unknown).symbol)
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                        Text((info?.type ?? .unknown).title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        if item.detectedQRCodes.count > 1 {
                            Text(L10n.format("QR %d개", item.detectedQRCodes.count))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        usageBadge
                    }
                    Text(info?.title ?? L10n.text("QR 코드"))
                        .font(.headline)
                        .foregroundStyle(item.isQRUsed ? .secondary : .primary)
                        .lineLimit(1)
                    if let subtitle = info?.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(L10n.date(item.createdAt))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(10)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
    }

    private var usageBadge: some View {
        Label(
            L10n.text(item.isQRUsed ? "확인함" : "미확인"),
            systemImage: item.isQRUsed ? "checkmark.circle.fill" : "circle.dotted"
        )
        .labelStyle(.titleAndIcon)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(item.isQRUsed ? Color.secondary : Color.orange)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            (item.isQRUsed ? Color.secondary : Color.orange).opacity(0.12),
            in: Capsule()
        )
    }

    private var thumbnail: some View {
        MediaThumbnail(item: item)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var trailing: some View {
        if isSelecting {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        } else if let info {
            Button { runAction(info) } label: {
                Label(info.primaryAction.title, systemImage: info.primaryAction.symbol)
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleOnly)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(info.primaryAction.title) · \(info.title)")
        }
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
