import AVKit
import Photos
import SwiftData
import SwiftUI

struct MediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Album.sortOrder) private var albums: [Album]
    let items: [MediaItem]
    let initialID: UUID
    let isRecentlyDeleted: Bool
    @State private var selectedID: UUID
    @State private var showsInfo = false
    @State private var showsDelete = false
    @State private var showsRetention = false
    @State private var showsReminder = false
    @State private var showsAlbumMove = false

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
            .toolbarBackground(.black.opacity(0.55), for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("닫기") { dismiss() } }
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
                            Button("복구") { MediaLifecycleService.restore(current); dismiss() }
                            Spacer()
                            Button(role: .destructive) { showsDelete = true } label: { Label("영구 삭제", systemImage: "trash") }
                        } else {
                            if current.waitingForCompletion {
                                Button { completeCurrent() } label: {
                                    Label("완료", systemImage: "checkmark.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
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
        .confirmationDialog("이 항목을 삭제할까요?", isPresented: $showsDelete) {
            Button(L10n.text(isRecentlyDeleted ? "영구 삭제" : "삭제"), role: .destructive) { deleteCurrent() }
        }
    }

    @ViewBuilder
    private func actionsMenu(for item: MediaItem) -> some View {
        Menu {
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
                Label(item.reminderDate == nil ? "다시 알려주기" : "알림 변경", systemImage: "bell")
            }
            Button { showsRetention = true } label: { Label("보관 기간", systemImage: "clock") }
            Button { showsAlbumMove = true } label: { Label("앨범으로 이동", systemImage: "folder") }
                .disabled(albums.isEmpty)
            ShareLink(item: MediaStorage.url(for: item.localPath)) { Label("공유", systemImage: "square.and.arrow.up") }
            Button { showsInfo = true } label: { Label("정보", systemImage: "info.circle") }
            Divider()
            Button(role: .destructive) { showsDelete = true } label: { Label("삭제", systemImage: "trash") }
        } label: {
            Label("사진 동작", systemImage: "ellipsis.circle")
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
                        Text(album.name).foregroundStyle(.primary)
                        Spacer()
                        if current?.albumID == album.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
            }
            .navigationTitle("앨범으로 이동")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { showsAlbumMove = false } }
            }
        }
        .presentationDetents([.large])
    }

    private func completeCurrent() {
        guard let current else { return }
        Task {
            await MediaLifecycleService.complete(current)
            try? modelContext.save()
            dismiss()
        }
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
                VideoPlayer(player: AVPlayer(url: MediaStorage.url(for: item.localPath)))
            } else if let image = UIImage(contentsOfFile: MediaStorage.url(for: item.localPath).path) {
                Image(uiImage: image)
                    .resizable().scaledToFit().scaleEffect(scale)
                    .gesture(MagnifyGesture().onChanged { value in scale = min(max(lastScale * value.magnification, 1), 6) }
                        .onEnded { _ in lastScale = scale })
                    .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2; lastScale = scale } }
            } else {
                ContentUnavailableView("파일을 열 수 없음", systemImage: "exclamationmark.triangle")
            }
        }
    }
}

struct MediaInfoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("촬영 날짜", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("가져온 날짜", value: item.importedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("크기", value: ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                LabeledContent("해상도", value: "\(item.width) × \(item.height)")
                LabeledContent("파일 형식", value: URL(fileURLWithPath: item.localPath).pathExtension.uppercased())
                if item.kind == .video { LabeledContent("길이", value: Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))) }
                LabeledContent("보관 상태", value: RetentionService.statusText(for: item))
                if item.isPinned { LabeledContent("고정", value: L10n.text("켜짐")) }
                if let reminder = item.reminderDate { LabeledContent("다시 알림", value: reminder.formatted(date: .abbreviated, time: .shortened)) }
                if item.kind == .photo {
                    LabeledContent("텍스트 인식", value: ocrStatusText)
                    if !item.recognizedText.isEmpty {
                        Section("인식된 텍스트") { Text(item.recognizedText).textSelection(.enabled) }
                    }
                    Button("텍스트 다시 인식") {
                        OCRService.enqueue(item, in: modelContext, force: true)
                    }
                    .disabled(item.ocrStatus == .processing)
                }
            }
            .navigationTitle("정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
        .presentationDetents([.large])
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

                Section("날짜 지정") {
                    DatePicker("보관 기한", selection: $customDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    Button("이 날짜까지 보관") {
                        RetentionService.apply(.customDate, customDate: customDate, to: item)
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
            .navigationTitle("보관 기간")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
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
                        Button("5초 후 (테스트)") { schedule(at: .now.addingTimeInterval(5)) }
                    }
                    #endif
                    ForEach(ReminderDateOption.allCases) { option in
                        Button(option.title) { schedule(at: option.date()) }
                    }
                } footer: {
                    Text("처음 사용할 때만 알림 권한을 요청합니다. 알림을 누르면 이 사진이 바로 열립니다.")
                }

                Section("날짜 및 시간 선택") {
                    DatePicker("알림 시간", selection: $customDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    Button("이 시간에 알리기") { schedule(at: customDate) }
                }

                if item.reminderDate != nil {
                    Section {
                        Button("알림 취소", role: .destructive) { cancel() }
                    }
                }
            }
            .navigationTitle("다시 알려주기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
        }
        .presentationDetents([.large])
        .alert("알림을 설정할 수 없음", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { }
            Button("설정 열기") {
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
