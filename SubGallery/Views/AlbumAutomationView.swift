import SwiftData
import SwiftUI

/// A user album and its automation are core SubGallery features.
struct AlbumAutomationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var media: [MediaItem]
    let album: Album

    @State private var customDate: Date
    @State private var showsRetroactiveConfirmation = false
    @State private var showsSuggestions = false
    @State private var message: String?

    init(album: Album) {
        self.album = album
        _customDate = State(initialValue: album.defaultRetentionDate
            ?? Calendar.current.date(byAdding: .day, value: 1, to: .now)
            ?? .now)
    }

    private var retroactiveTargets: [MediaItem] {
        AlbumAutomationService.itemsEligibleForRetroactiveRetention(in: album, from: media)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(AlbumAutomationService.summary(for: album))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(L10n.text("현재 설정"))
                } footer: {
                    Text(L10n.text("이 앨범에 추가되는 사진을 어떻게 관리할까요?"))
                }

                basicSection
                completionSection
                advancedSection
                retroactiveSection
            }
            .navigationTitle(L10n.text("앨범 자동화"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("완료")) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showsSuggestions) {
            AlbumCleanupSuggestionsView(album: album)
        }
        .confirmationDialog(
            L10n.format(
                "이 앨범의 기존 사진 %d장에 %@ 규칙을 적용할까요?",
                retroactiveTargets.count,
                album.defaultRetention.title
            ),
            isPresented: $showsRetroactiveConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.format("%d장에 적용", retroactiveTargets.count)) { applyToExisting() }
            Button(L10n.text("취소"), role: .cancel) { }
        } message: {
            Text(L10n.text("고정한 사진은 바뀌지 않습니다."))
        }
        .alert(L10n.text("앨범 자동화"), isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button(L10n.text("확인"), role: .cancel) { }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: - Free

    private var basicSection: some View {
        Section(L10n.text("기본 관리")) {
            Picker(L10n.text("보관 기간"), selection: Binding(
                get: { album.defaultRetention },
                set: { policy in
                    update {
                        album.defaultRetention = policy
                        album.defaultRetentionDate = policy == .customDate ? customDate : nil
                    }
                }
            )) {
                ForEach(RetentionPolicy.allCases) { Text($0.title).tag($0) }
            }
            if album.defaultRetention == .customDate {
                DatePicker(
                    L10n.text("날짜"),
                    selection: $customDate,
                    in: Date.now...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .onChange(of: customDate) { _, date in
                    update { album.defaultRetentionDate = date }
                }
            }
            // "사진 속 글자 검색" rather than "OCR": the setting is named for what the
            // user gets, not for the technology.
            Toggle(L10n.text("사진 속 글자 검색"), isOn: binding(
                get: { album.ocrEnabled },
                set: { album.ocrEnabled = $0 }
            ))
            Toggle(L10n.text("촬영 위치 저장"), isOn: binding(
                get: { album.savesLocation },
                set: { album.savesLocation = $0 }
            ))
            Toggle(L10n.text("새 사진 자동 고정"), isOn: binding(
                get: { album.autoPins },
                set: { album.autoPins = $0 }
            ))
        }
    }

    private var completionSection: some View {
        Section {
            Picker(L10n.text("완료 방식"), selection: Binding(
                get: { album.autoCleanupEnabled },
                set: { enabled in
                    update { album.autoCleanupEnabled = enabled }
                }
            )) {
                Text(L10n.text("직접 완료")).tag(false)
                Text(L10n.text("보관 기간이 끝나면 자동 정리")).tag(true)
            }
        } header: {
            Text(L10n.text("완료와 정리"))
        } footer: {
            Text(L10n.text("자동 정리된 사진은 최근 삭제로 이동하며 7일 동안 복구할 수 있습니다. 고정한 사진은 정리되지 않습니다."))
        }
    }

    // MARK: - Suggestions

    private var advancedSection: some View {
        Section {
            Button {
                showsSuggestions = true
            } label: {
                LabeledContent(L10n.text("정리 제안")) {
                    Text(L10n.format("%d장", suggestionCount))
                }
            }
            .disabled(suggestionCount == 0)
        } header: {
            Text(L10n.text("고급 자동화"))
        }
    }

    private var suggestionCount: Int {
        AlbumAutomationService.cleanupSuggestions(for: album, media: media).total
    }

    // MARK: - Retroactive

    private var retroactiveSection: some View {
        Section {
            Button(L10n.text("기존 사진에도 적용")) {
                showsRetroactiveConfirmation = true
            }
            .disabled(retroactiveTargets.isEmpty)
        } footer: {
            // Stated plainly because the alternative — silently rewriting existing
            // photos when a setting changes — is exactly what this avoids.
            Text(L10n.text("설정은 앞으로 추가되는 사진에 적용됩니다. 기존 사진은 직접 적용할 때만 바뀝니다."))
        }
    }

    private func applyToExisting() {
        let count = AlbumAutomationService.applyRetentionToExisting(
            in: album,
            media: media,
            context: modelContext
        )
        message = L10n.format("사진 %d장에 적용했습니다.", count)
    }

    // MARK: - Persistence

    private func binding<Value>(
        get: @escaping () -> Value,
        set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(get: get, set: { value in update { set(value) } })
    }

    /// Saved immediately — there is no Save button. A failed write is rolled back so
    /// the switch never shows a value the album does not actually have.
    private func update(_ change: () -> Void) {
        change()
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            message = error.localizedDescription
        }
    }
}

// MARK: - Cleanup suggestions

struct AlbumCleanupSuggestionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var media: [MediaItem]
    let album: Album

    @State private var viewerItem: MediaItem?

    private var suggestions: AlbumAutomationService.CleanupSuggestions {
        AlbumAutomationService.cleanupSuggestions(for: album, media: media)
    }

    var body: some View {
        NavigationStack {
            List {
                group(L10n.text("30일 이상 된 사진"), items: suggestions.agedOut)
                group(L10n.text("완료 대기"), items: suggestions.waitingForCompletion)
                group(L10n.text("곧 만료"), items: suggestions.expiringSoon)
            }
            .navigationTitle(L10n.text("정리 제안"))
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if suggestions.isEmpty {
                    ContentUnavailableView(
                        L10n.text("정리할 사진이 없습니다."),
                        systemImage: "checkmark.circle"
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("완료")) { dismiss() }
                }
            }
        }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewer(items: media.filter { $0.albumID == album.id && $0.deletedAt == nil },
                        initialID: item.id,
                        isRecentlyDeleted: false)
        }
    }

    @ViewBuilder
    private func group(_ title: String, items: [MediaItem]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    Button { viewerItem = item } label: {
                        HStack(spacing: 12) {
                            MediaThumbnail(item: item)
                                .frame(width: 46, height: 46)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.fileName).lineLimit(1)
                                Text(RetentionService.statusText(for: item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("\(title) · \(L10n.format("%d장", items.count))")
            }
        }
    }
}
