import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum EditorCrop: String, CaseIterable, Identifiable {
    case original = "원본"
    case square = "1:1"
    case fourThree = "4:3"
    case sixteenNine = "16:9"

    var id: String { rawValue }
    var ratio: CGFloat? {
        switch self {
        case .original: nil
        case .square: 1
        case .fourThree: 4 / 3
        case .sixteenNine: 16 / 9
        }
    }
}

struct PhotoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem
    let onSaved: (MediaItem) -> Void

    @State private var quarterTurns = 0
    @State private var isMirrored = false
    @State private var crop: EditorCrop = .original
    @State private var overlayText = ""
    @State private var textSize = 34.0
    @State private var textColor = Color.white
    @State private var textPosition = CGPoint(x: 0.5, y: 0.5)
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var sourceImage: UIImage? {
        UIImage(contentsOfFile: MediaStorage.url(for: item.localPath).path)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorCanvas
                controls
            }
            .background(Color.black)
            .navigationTitle("편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("편집본 저장") { saveCopy() }.disabled(isSaving || sourceImage == nil)
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("편집본을 저장할 수 없음", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { }
        } message: { Text(errorMessage ?? "") }
    }

    private var editorCanvas: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image = renderedBaseImage() {
                    let imageRect = aspectFitRect(
                        image.size,
                        in: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 12, dy: 12)
                    )
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)
                    if !overlayText.isEmpty {
                        Text(overlayText)
                            .font(.system(size: textSize, weight: .semibold))
                            .foregroundStyle(textColor)
                            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                            .position(
                                x: imageRect.minX + imageRect.width * textPosition.x,
                                y: imageRect.minY + imageRect.height * textPosition.y
                            )
                            .gesture(DragGesture().onChanged { value in
                                textPosition = CGPoint(
                                    x: min(max((value.location.x - imageRect.minX) / imageRect.width, 0.05), 0.95),
                                    y: min(max((value.location.y - imageRect.minY) / imageRect.height, 0.05), 0.95)
                                )
                            })
                    }
                } else {
                    ContentUnavailableView("사진을 열 수 없음", systemImage: "photo.badge.exclamationmark")
                }
                if isSaving { ProgressView().controlSize(.large) }
            }
        }
    }

    private func aspectFitRect(_ imageSize: CGSize, in availableRect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return availableRect }
        let scale = min(availableRect.width / imageSize.width, availableRect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: availableRect.midX - size.width / 2,
            y: availableRect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                Button { quarterTurns = (quarterTurns + 1) % 4 } label: {
                    Label("회전", systemImage: "rotate.right")
                }
                Button { isMirrored.toggle() } label: {
                    Label("좌우 반전", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                Menu {
                    ForEach(EditorCrop.allCases) { option in
                        Button(option.rawValue) { crop = option }
                    }
                } label: {
                    Label(crop.rawValue, systemImage: "crop")
                }
            }
            .labelStyle(.titleAndIcon)

            TextField("텍스트 추가", text: $overlayText)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(.primary)

            HStack {
                Image(systemName: "textformat.size.smaller")
                Slider(value: $textSize, in: 16...72)
                Image(systemName: "textformat.size.larger")
                ColorPicker("텍스트 색상", selection: $textColor, supportsOpacity: false)
                    .labelsHidden()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
        .foregroundStyle(.white)
    }

    private func renderedBaseImage() -> UIImage? {
        guard let sourceImage else { return nil }
        return transformedAndCropped(sourceImage)
    }

    private func transformedAndCropped(_ source: UIImage) -> UIImage {
        let normalized = UIGraphicsImageRenderer(size: source.size).image { _ in
            source.draw(in: CGRect(origin: .zero, size: source.size))
        }
        let swapsSides = quarterTurns % 2 == 1
        let rotatedSize = swapsSides
            ? CGSize(width: normalized.size.height, height: normalized.size.width)
            : normalized.size
        let transformed = UIGraphicsImageRenderer(size: rotatedSize).image { context in
            let cg = context.cgContext
            cg.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
            cg.rotate(by: CGFloat(quarterTurns) * .pi / 2)
            if isMirrored { cg.scaleBy(x: -1, y: 1) }
            normalized.draw(in: CGRect(
                x: -normalized.size.width / 2,
                y: -normalized.size.height / 2,
                width: normalized.size.width,
                height: normalized.size.height
            ))
        }
        guard let cropRatio = crop.ratio, let cgImage = transformed.cgImage else { return transformed }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let ratio = width < height ? 1 / cropRatio : cropRatio
        let rect: CGRect
        if width / height > ratio {
            let cropWidth = height * ratio
            rect = CGRect(x: (width - cropWidth) / 2, y: 0, width: cropWidth, height: height)
        } else {
            let cropHeight = width / ratio
            rect = CGRect(x: 0, y: (height - cropHeight) / 2, width: width, height: cropHeight)
        }
        guard let cropped = cgImage.cropping(to: rect.integral) else { return transformed }
        return UIImage(cgImage: cropped, scale: transformed.scale, orientation: .up)
    }

    private func finalImage() -> UIImage? {
        guard let base = renderedBaseImage() else { return nil }
        return UIGraphicsImageRenderer(size: base.size).image { _ in
            base.draw(in: CGRect(origin: .zero, size: base.size))
            guard !overlayText.isEmpty else { return }
            let fontSize = base.size.width * CGFloat(textSize / 390)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor(textColor),
                .strokeColor: UIColor.black.withAlphaComponent(0.35),
                .strokeWidth: -1.5
            ]
            let string = NSString(string: overlayText)
            let size = string.size(withAttributes: attributes)
            string.draw(
                at: CGPoint(
                    x: base.size.width * textPosition.x - size.width / 2,
                    y: base.size.height * textPosition.y - size.height / 2
                ),
                withAttributes: attributes
            )
        }
    }

    private func saveCopy() {
        guard let image = finalImage(), let data = image.jpegData(compressionQuality: 0.94) else { return }
        isSaving = true
        Task {
            do {
                let baseName = URL(fileURLWithPath: item.fileName).deletingPathExtension().lastPathComponent
                let stored = try await MediaStorage.shared.store(
                    data: data,
                    type: .jpeg,
                    preferredName: "\(baseName)-편집본.jpg"
                )
                await MainActor.run {
                    let copy = MediaItem(
                        kind: .photo,
                        source: item.source,
                        localPath: stored.relativePath,
                        thumbnailPath: stored.thumbnailRelativePath,
                        fileName: stored.fileName,
                        createdAt: .now,
                        albumID: item.albumID,
                        expirationDate: item.expirationDate,
                        fileSize: stored.fileSize,
                        width: stored.width,
                        height: stored.height
                    )
                    copy.expirationTypeRaw = item.expirationTypeRaw
                    copy.waitingForCompletion = item.waitingForCompletion
                    copy.isPinned = item.isPinned
                    copy.note = item.note
                    copy.latitude = item.latitude
                    copy.longitude = item.longitude
                    modelContext.insert(copy)
                    try? modelContext.save()
                    OCRService.enqueue(copy, in: modelContext)
                    onSaved(copy)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
