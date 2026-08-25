#!/usr/bin/env swift
import AppKit
import CoreText
import CryptoKit
import Foundation

struct Translation: Decodable {
    let locale: String
    let language: String
    let appleLocale: String
    let direction: String
    let frames: [Frame]
}

struct Frame: Decodable {
    let frame: Int
    let filename: String
    let route: String
    let headline: String
    let support: String
}

struct CanvasSpec {
    let width: Int
    let height: Int
    let captureX: CGFloat
    let captureTop: CGFloat
    let captureWidth: CGFloat
    let headlineTop: CGFloat
    let headlineHeight: CGFloat
    let supportTop: CGFloat
    let supportHeight: CGFloat
    let textMargin: CGFloat
    let headlineSize: CGFloat
    let supportSize: CGFloat
    let cornerRadius: CGFloat
}

let locales = ["ko-KR", "en-US", "de-DE", "es-ES", "ar-SA", "ja-JP", "zh-Hans", "zh-Hant", "fr-FR"]
let devices = ["iphone", "ipad"]
let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let translationsRoot = projectRoot.appendingPathComponent("store-assets/translations")
let rawRoot = projectRoot.appendingPathComponent("store-assets/raw")
let outputRoot = projectRoot.appendingPathComponent("output")

let specs: [String: CanvasSpec] = [
    "iphone": CanvasSpec(
        width: 1242,
        height: 2688,
        captureX: 71,
        captureTop: 700,
        captureWidth: 1100,
        headlineTop: 118,
        headlineHeight: 270,
        supportTop: 420,
        supportHeight: 150,
        textMargin: 72,
        headlineSize: 88,
        supportSize: 38,
        cornerRadius: 44
    ),
    "ipad": CanvasSpec(
        width: 2064,
        height: 2752,
        captureX: 120,
        captureTop: 650,
        captureWidth: 1824,
        headlineTop: 126,
        headlineHeight: 270,
        supportTop: 430,
        supportHeight: 130,
        textMargin: 124,
        headlineSize: 96,
        supportSize: 42,
        cornerRadius: 48
    )
]

func topRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, canvasHeight: CGFloat) -> NSRect {
    NSRect(x: x, y: canvasHeight - y - height, width: width, height: height)
}

func paragraphStyle(alignment: NSTextAlignment, isRTL: Bool, lineSpacing: CGFloat) -> NSMutableParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    style.lineBreakMode = .byWordWrapping
    style.lineSpacing = lineSpacing
    return style
}

func fittedFont(
    text: String,
    initialSize: CGFloat,
    minimumSize: CGFloat,
    weight: NSFont.Weight,
    color: NSColor,
    paragraph: NSParagraphStyle,
    rect: NSRect
) -> (font: NSFont, fits: Bool) {
    var size = initialSize
    while size >= minimumSize {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let bounds = (text as NSString).boundingRect(
            with: rect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        if ceil(bounds.width) <= rect.width && ceil(bounds.height) <= rect.height {
            return (font, true)
        }
        size -= 2
    }
    return (NSFont.systemFont(ofSize: minimumSize, weight: weight), false)
}

func fittedHeadlineFont(
    text: String,
    initialSize: CGFloat,
    minimumSize: CGFloat,
    rect: NSRect,
    lineSpacing: CGFloat
) -> (font: NSFont, fits: Bool) {
    let lines = text.components(separatedBy: "\n")
    var size = initialSize
    while size >= minimumSize {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let widths = lines.map { line -> CGFloat in
            let attributed = NSAttributedString(string: line, attributes: [.font: font])
            return CGFloat(CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(attributed),
                nil,
                nil,
                nil
            ))
        }
        let lineHeight = font.ascender - font.descender + font.leading
        let totalHeight = lineHeight * CGFloat(lines.count) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        if (widths.max() ?? 0) <= rect.width && totalHeight <= rect.height {
            return (font, true)
        }
        size -= 2
    }
    return (NSFont.systemFont(ofSize: minimumSize, weight: .bold), false)
}

func drawHeadline(
    _ text: String,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment,
    isRTL: Bool,
    rect: NSRect,
    lineSpacing: CGFloat
) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let lines = text.components(separatedBy: "\n")
    let lineHeight = font.ascender - font.descender + font.leading
    var baseline = rect.maxY - font.ascender

    context.saveGState()
    context.textMatrix = .identity
    for value in lines {
        let paragraph = paragraphStyle(alignment: alignment, isRTL: isRTL, lineSpacing: 0)
        let attributed = NSAttributedString(string: value, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x: CGFloat
        switch alignment {
        case .center:
            x = rect.midX - width / 2
        case .right:
            x = rect.maxX - width
        default:
            x = rect.minX
        }
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
        baseline -= lineHeight + lineSpacing
    }
    context.restoreGState()
}

func sha256(_ url: URL) throws -> String {
    let digest = SHA256.hash(data: try Data(contentsOf: url))
    return digest.map { String(format: "%02x", $0) }.joined()
}

func drawCapture(
    _ image: NSImage,
    in captureRect: NSRect,
    cornerRadius: CGFloat,
    sourceTopInset: CGFloat
) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let path = CGPath(roundedRect: captureRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.16).cgColor)
    context.addPath(path)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()

    let rawSize = image.size
    let scale = captureRect.width / rawSize.width
    let availableRawHeight = max(rawSize.height - sourceTopInset, 1)
    let visibleRawHeight = min(availableRawHeight, captureRect.height / scale)
    let sourceRect = NSRect(
        x: 0,
        y: rawSize.height - sourceTopInset - visibleRawHeight,
        width: rawSize.width,
        height: visibleRawHeight
    )
    image.draw(
        in: captureRect,
        from: sourceRect,
        operation: .copy,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    context.restoreGState()
}

try? FileManager.default.removeItem(at: outputRoot)
try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

var manifestImages: [[String: Any]] = []
let decoder = JSONDecoder()

for locale in locales {
    let translationURL = translationsRoot.appendingPathComponent("\(locale).json")
    let translation = try decoder.decode(Translation.self, from: Data(contentsOf: translationURL))

    for device in devices {
        guard let spec = specs[device] else { continue }
        let destination = outputRoot.appendingPathComponent(locale).appendingPathComponent(device)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for frame in translation.frames {
            let rawURL = rawRoot
                .appendingPathComponent(locale)
                .appendingPathComponent(device)
                .appendingPathComponent("\(frame.route).png")
            guard let source = NSImage(contentsOf: rawURL) else {
                throw NSError(domain: "StoreComposer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing source capture: \(rawURL.path)"])
            }

            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: spec.width,
                pixelsHigh: spec.height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                throw NSError(domain: "StoreComposer", code: 2)
            }

            let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics

            NSColor(calibratedRed: 0.965, green: 0.972, blue: 0.982, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: spec.width, height: spec.height)).fill()

            let isRTL = translation.direction == "rtl"
            let centersPhoneCJK = device == "iphone" && ["ko-KR", "ja-JP", "zh-Hans", "zh-Hant"].contains(locale)
            let alignment: NSTextAlignment = isRTL ? .right : (centersPhoneCJK ? .center : .left)
            let supportParagraph = paragraphStyle(alignment: alignment, isRTL: isRTL, lineSpacing: 6)

            let textWidth = CGFloat(spec.width) - spec.textMargin * 2
            let headlineRect = topRect(
                x: spec.textMargin,
                y: spec.headlineTop,
                width: textWidth,
                height: spec.headlineHeight,
                canvasHeight: CGFloat(spec.height)
            )
            let supportRect = topRect(
                x: spec.textMargin,
                y: spec.supportTop,
                width: textWidth,
                height: spec.supportHeight,
                canvasHeight: CGFloat(spec.height)
            )

            let headlineFit = fittedHeadlineFont(
                text: frame.headline,
                initialSize: spec.headlineSize,
                minimumSize: device == "iphone" ? 68 : 76,
                rect: headlineRect,
                lineSpacing: 3
            )
            let supportFit = fittedFont(
                text: frame.support,
                initialSize: spec.supportSize,
                minimumSize: device == "iphone" ? 30 : 34,
                weight: .medium,
                color: NSColor(calibratedWhite: 0.32, alpha: 1),
                paragraph: supportParagraph,
                rect: supportRect
            )

            drawHeadline(
                frame.headline,
                font: headlineFit.font,
                color: NSColor(calibratedWhite: 0.08, alpha: 1),
                alignment: alignment,
                isRTL: isRTL,
                rect: headlineRect,
                lineSpacing: 3
            )
            (frame.support as NSString).draw(
                with: supportRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: supportFit.font,
                    .foregroundColor: NSColor(calibratedWhite: 0.32, alpha: 1),
                    .paragraphStyle: supportParagraph
                ]
            )

            let captureRect = topRect(
                x: spec.captureX,
                y: spec.captureTop,
                width: spec.captureWidth,
                height: CGFloat(spec.height) - spec.captureTop,
                canvasHeight: CGFloat(spec.height)
            )
            let sourceTopInset: CGFloat = {
                if frame.route == "workflows" { return device == "iphone" ? 450 : 350 }
                return device == "ipad" ? 60 : 0
            }()
            drawCapture(
                source,
                in: captureRect,
                cornerRadius: spec.cornerRadius,
                sourceTopInset: sourceTopInset
            )

            NSGraphicsContext.restoreGraphicsState()

            let destinationURL = destination.appendingPathComponent(frame.filename)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "StoreComposer", code: 3)
            }
            try png.write(to: destinationURL, options: .atomic)

            manifestImages.append([
                "locale": locale,
                "device": device,
                "frame": frame.frame,
                "slug": frame.route,
                "filename": frame.filename,
                "width": spec.width,
                "height": spec.height,
                "headline": frame.headline,
                "supportingCopy": frame.support,
                "layoutDirection": translation.direction,
                "headlineFontSize": headlineFit.font.pointSize,
                "supportFontSize": supportFit.font.pointSize,
                "textFits": headlineFit.fits && supportFit.fits,
                "sourceCaptureIdentifier": rawURL.path.replacingOccurrences(of: projectRoot.path + "/", with: ""),
                "sourceCaptureSHA256": try sha256(rawURL)
            ])
        }
    }
}

let manifest: [String: Any] = [
    "campaign": "SubGallery App Store screenshots",
    "buildConfiguration": "Release",
    "screenshotCompilationCondition": "STORE_SCREENSHOTS",
    "imageCount": manifestImages.count,
    "images": manifestImages
]
let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try manifestData.write(to: outputRoot.appendingPathComponent("manifest.json"), options: .atomic)
print("Composed \(manifestImages.count) PNG files")
