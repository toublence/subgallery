import CoreImage
import Foundation
import SwiftData
import Vision

struct MediaAnalysisResult: Sendable {
    let text: String
    let urls: [String]
    let phoneNumbers: [String]
    let addresses: [String]
    let dates: [Date]
    let qrCodes: [String]
    let receiptMerchant: String
    let receiptAmount: String
    let textLineCount: Int
    let textCoverage: Double
}

actor OCRService {
    static let shared = OCRService()

    func recognizeText(at url: URL) throws -> String {
        try analyze(at: url).text
    }

    func analyze(at url: URL) throws -> MediaAnalysisResult {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw OCRServiceError.unreadableImage
        }

        let enhanced = image
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.35
            ])
            .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.5])

        let automatic = makeTextRequest(automaticallyDetectsLanguage: true)
        let barcode = VNDetectBarcodesRequest()
        try VNImageRequestHandler(ciImage: image, options: [:]).perform([automatic, barcode])

        let koreanFocused = makeTextRequest(automaticallyDetectsLanguage: false)
        koreanFocused.recognitionLanguages = ["ko-KR", "en-US"]
        try VNImageRequestHandler(ciImage: enhanced, options: [:]).perform([koreanFocused])

        var seen = Set<String>()
        let lines = [automatic, koreanFocused]
            .flatMap { $0.results ?? [] }
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let text = lines.joined(separator: "\n")
        let textCoverage = min(1, (automatic.results ?? []).reduce(0.0) {
            $0 + Double($1.boundingBox.width * $1.boundingBox.height)
        })
        let detected = detectData(in: text)
        let qrCodes = unique((barcode.results ?? []).compactMap(\.payloadStringValue))
        let qrURLs = qrCodes.compactMap { normalizedURLString($0) }

        return MediaAnalysisResult(
            text: text,
            urls: unique(detected.urls + qrURLs),
            phoneNumbers: detected.phoneNumbers,
            addresses: detected.addresses,
            dates: detected.dates,
            qrCodes: qrCodes,
            receiptMerchant: receiptMerchant(in: lines),
            receiptAmount: receiptAmount(in: lines),
            textLineCount: lines.count,
            textCoverage: textCoverage
        )
    }

    private func makeTextRequest(automaticallyDetectsLanguage: Bool) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        return request
    }

    private func detectData(in text: String) -> (urls: [String], phoneNumbers: [String], addresses: [String], dates: [Date]) {
        let types = NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue
            | NSTextCheckingResult.CheckingType.date.rawValue
        guard let detector = try? NSDataDetector(types: types) else { return ([], [], [], []) }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var urls: [String] = []
        var phoneNumbers: [String] = []
        var addresses: [String] = []
        var dates: [Date] = []

        for match in detector.matches(in: text, options: [], range: range) {
            switch match.resultType {
            case .link:
                if let url = match.url?.absoluteString { urls.append(url) }
            case .phoneNumber:
                if let phone = match.phoneNumber { phoneNumbers.append(phone) }
            case .address:
                if let matchRange = Range(match.range, in: text) { addresses.append(String(text[matchRange])) }
            case .date:
                if let date = match.date { dates.append(date) }
            default:
                break
            }
        }
        return (unique(urls), unique(phoneNumbers), unique(addresses), Array(Set(dates)).sorted())
    }

    private func normalizedURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        return url.absoluteString
    }

    private func receiptMerchant(in lines: [String]) -> String {
        let ignored = ["영수증", "receipt", "승인", "매출", "합계", "total", "카드"]
        return lines.first { line in
            let lowercased = line.lowercased()
            let letterCount = line.unicodeScalars.filter(CharacterSet.letters.contains).count
            return letterCount >= 2 && !ignored.contains(where: lowercased.contains)
        } ?? ""
    }

    private func receiptAmount(in lines: [String]) -> String {
        let preferred = lines.first { line in
            let lowercased = line.lowercased()
            return ["합계", "결제", "총액", "total", "amount"].contains(where: lowercased.contains)
        }
        let candidates = preferred.map { [$0] } ?? lines.filter {
            let uppercased = $0.uppercased()
            return ["₩", "￦", "$", "€", "£", "¥", "원"].contains(where: $0.contains)
                || ["KRW", "USD", "EUR", "GBP", "JPY", "CNY", "RMB"].contains(where: uppercased.contains)
        }
        let pattern = #"(?:(?:₩|￦|\$|€|£|¥|KRW|USD|EUR|GBP|JPY|CNY|RMB)\s*)?(?:\d{1,3}(?:[,.\s]\d{3})+|\d+)(?:[,.]\d{2})?\s*(?:원|KRW|USD|EUR|GBP|JPY|CNY|RMB)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return "" }
        for line in candidates {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = expression.firstMatch(in: line, range: range),
               let matchRange = Range(match.range, in: line) {
                return String(line[matchRange]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    @MainActor
    static func enqueue(_ item: MediaItem, in context: ModelContext, force: Bool = false) {
        guard item.kind == .photo, item.analysisEnabled,
              force || item.ocrStatus == .pending else {
            if !item.analysisEnabled { item.ocrStatus = .notApplicable }
            return
        }
        item.ocrStatus = .processing
        let url = item.mediaURL

        Task(priority: .utility) {
            do {
                let result = try await OCRService.shared.analyze(at: url)
                item.recognizedText = result.text
                item.detectedURLs = result.urls
                item.detectedPhoneNumbers = result.phoneNumbers
                item.detectedAddresses = result.addresses
                item.detectedDates = result.dates
                item.detectedQRCodes = result.qrCodes
                if PremiumAccess.isActive {
                    SmartClassificationService.evaluate(result, for: item, in: context)
                    let isReceipt = item.purpose == .receipt
                        || item.suggestedPurpose == .receipt
                        || SmartClassificationService.isHighConfidenceReceipt(result, text: result.text)
                    if isReceipt {
                        if item.receiptMerchant.isEmpty { item.receiptMerchant = result.receiptMerchant }
                        if item.receiptAmount.isEmpty { item.receiptAmount = result.receiptAmount }
                        if item.receiptDate == nil { item.receiptDate = result.dates.first }
                    }
                }
                item.ocrStatus = .completed
            } catch {
                item.ocrStatus = .failed
            }
            try? context.save()
        }
    }
}

@MainActor
enum SmartClassificationService {
    static func evaluate(_ result: MediaAnalysisResult, for item: MediaItem, in context: ModelContext) {
        guard PremiumAccess.isActive,
              item.deletedAt == nil,
              item.classificationStatus == .pending else { return }

        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        let normalizedText = result.text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )

        let customMatch = albums.first { album in
            guard album.smartRuleEnabled else { return false }
            let keywords = album.smartRuleKeywords
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return !keywords.isEmpty && keywords.contains {
                normalizedText.localizedCaseInsensitiveContains($0)
            }
        }

        let purpose: CapturePurpose?
        if let customMatch {
            purpose = customMatch.purpose
        } else if isHighConfidenceReceipt(result, text: normalizedText) {
            purpose = .receipt
        } else if !result.qrCodes.isEmpty {
            purpose = .qr
        } else if isHighConfidenceDocument(result) {
            purpose = .document
        } else {
            purpose = nil
        }

        guard let purpose else {
            item.classificationStatus = .none
            try? context.save()
            return
        }

        let targetAlbum = customMatch
            ?? albums.first(where: { $0.smartRuleEnabled && $0.purpose == purpose })
            ?? albums.first(where: { $0.purpose == purpose })
        let retention = targetAlbum?.defaultRetention ?? defaultRetention(for: purpose)

        item.suggestedPurpose = purpose
        item.suggestedAlbumID = targetAlbum?.id
        item.suggestedRetention = retention
        item.classificationStatus = .suggested
        try? context.save()
        NotificationCenter.default.post(name: .smartClassificationSuggested, object: item.id)
    }

    static func apply(
        _ item: MediaItem,
        album: Album?,
        retention: RetentionPolicy,
        in context: ModelContext
    ) {
        item.albumID = album?.id
        item.purpose = album?.purpose ?? item.suggestedPurpose ?? .general
        item.analysisEnabled = album?.ocrEnabled ?? true
        item.primaryAction = album?.primaryAction ?? .automatic
        RetentionService.apply(retention, customDate: album?.defaultRetentionDate, to: item)
        item.classificationStatus = .applied
        try? context.save()
    }

    static func dismiss(_ item: MediaItem, in context: ModelContext) {
        item.classificationStatus = .dismissed
        try? context.save()
    }

    static func defaultRetention(for purpose: CapturePurpose) -> RetentionPolicy {
        switch purpose {
        case .receipt: .thirtyDays
        case .temporary, .qr: .sevenDays
        case .parking: .untilComplete
        default: .forever
        }
    }

    static func isHighConfidenceReceipt(_ result: MediaAnalysisResult, text: String) -> Bool {
        let receiptTerms = [
            "합계", "총액", "결제", "승인", "영수증", "total", "amount", "receipt",
            "summe", "gesamt", "importe", "total", "合計", "領収", "总计", "總計", "الإجمالي"
        ]
        let hasReceiptTerm = receiptTerms.contains { text.localizedCaseInsensitiveContains($0) }
        let hasIdentity = !result.receiptMerchant.isEmpty
        let hasDate = !result.dates.isEmpty
        return !result.receiptAmount.isEmpty && hasReceiptTerm && (hasIdentity || hasDate)
    }

    private static func isHighConfidenceDocument(_ result: MediaAnalysisResult) -> Bool {
        result.textLineCount >= 8
            && result.text.count >= 160
            && result.textCoverage >= 0.12
    }
}

private enum OCRServiceError: Error {
    case unreadableImage
}
