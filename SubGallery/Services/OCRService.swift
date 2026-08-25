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
    let hasQRCode: Bool
    let qrCodes: [String]
    let receiptMerchant: String
    let receiptAmount: String
    let textLineCount: Int
    let textCoverage: Double?
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

        let qrObservations = detectQRCodes(original: image, enhanced: enhanced)

        let automatic = makeTextRequest(automaticallyDetectsLanguage: true)
        try? VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
            .perform([automatic])

        let koreanFocused = makeTextRequest(automaticallyDetectsLanguage: false)
        koreanFocused.recognitionLanguages = ["ko-KR", "en-US"]
        try? VNImageRequestHandler(ciImage: enhanced, orientation: .up, options: [:])
            .perform([koreanFocused])

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
        let qrCodes = qrPayloads(from: qrObservations)
        let qrURLs = qrCodes.compactMap { normalizedURLString($0) }

        return MediaAnalysisResult(
            text: text,
            urls: unique(detected.urls + qrURLs),
            phoneNumbers: detected.phoneNumbers,
            addresses: detected.addresses,
            dates: detected.dates,
            hasQRCode: !qrObservations.isEmpty,
            qrCodes: qrCodes,
            receiptMerchant: receiptMerchant(in: lines),
            receiptAmount: receiptAmount(in: lines),
            textLineCount: lines.count,
            textCoverage: textCoverage
        )
    }

    func analyzeStoredText(_ text: String) -> MediaAnalysisResult {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let detected = detectData(in: text)
        return MediaAnalysisResult(
            text: text,
            urls: detected.urls,
            phoneNumbers: detected.phoneNumbers,
            addresses: detected.addresses,
            dates: detected.dates,
            hasQRCode: false,
            qrCodes: [],
            receiptMerchant: receiptMerchant(in: lines),
            receiptAmount: receiptAmount(in: lines),
            textLineCount: lines.count,
            textCoverage: nil
        )
    }

    private func makeTextRequest(automaticallyDetectsLanguage: Bool) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        return request
    }

    private func makeQRCodeRequest() -> VNDetectBarcodesRequest {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        return request
    }

    private func qrResults(from request: VNDetectBarcodesRequest) -> [VNBarcodeObservation] {
        (request.results ?? []).filter { $0.symbology == .qr }
    }

    private func detectQRCodes(original: CIImage, enhanced: CIImage) -> [VNBarcodeObservation] {
        // CIImage applied the source EXIF orientation during loading, so each
        // normalized candidate is explicitly handed to Vision as upright.
        let candidates = [original, enhanced, scaledForSmallQRCode(enhanced)]
        for candidate in candidates {
            let observations = performQRCodeRequest(on: candidate)
            if !observations.isEmpty { return observations }
        }
        return []
    }

    private func performQRCodeRequest(on image: CIImage) -> [VNBarcodeObservation] {
        let request = makeQRCodeRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            return qrResults(from: request)
        } catch {
            // Some simulator/device pressure states cannot create the default
            // inference context. CPU fallback keeps QR classification available.
            let fallback = makeQRCodeRequest()
            fallback.usesCPUOnly = true
            let fallbackHandler = VNImageRequestHandler(
                ciImage: image,
                orientation: .up,
                options: [:]
            )
            guard (try? fallbackHandler.perform([fallback])) != nil else { return [] }
            return qrResults(from: fallback)
        }
    }

    private func scaledForSmallQRCode(_ image: CIImage) -> CIImage {
        let longestEdge = max(image.extent.width, image.extent.height)
        guard longestEdge > 0 else { return image }
        let scale = min(2, 6000 / longestEdge)
        guard scale > 1.05 else { return image }
        return image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1
        ])
    }

    private func qrPayloads(from observations: [VNBarcodeObservation]) -> [String] {
        unique(observations.compactMap { observation in
            Self.qrPayload(symbology: observation.symbology, payload: observation.payloadStringValue)
        })
    }

    nonisolated static func qrPayload(
        symbology: VNBarcodeSymbology,
        payload: String?
    ) -> String? {
        guard symbology == .qr,
              let value = payload?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
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
            return [
                "합계", "결제", "총액", "total", "amount", "summe", "gesamt", "importe",
                "合計", "总计", "總計", "الإجمالي", "المجموع"
            ].contains(where: lowercased.contains)
        }
        let candidates = preferred.map { [$0] } ?? lines.filter {
            let uppercased = $0.uppercased()
            return ["₩", "￦", "$", "€", "£", "¥", "₹", "원"].contains(where: $0.contains)
                || [
                    "KRW", "USD", "EUR", "GBP", "JPY", "CNY", "RMB", "AED", "SAR",
                    "CAD", "AUD", "CHF", "INR"
                ].contains(where: uppercased.contains)
        }
        let pattern = #"(?:(?:₩|￦|\$|€|£|¥|₹|KRW|USD|EUR|GBP|JPY|CNY|RMB|AED|SAR|CAD|AUD|CHF|INR)\s*)?(?:\d{1,3}(?:[,.\s]\d{3})+|\d+)(?:[,.]\d{2})?\s*(?:원|KRW|USD|EUR|GBP|JPY|CNY|RMB|AED|SAR|CAD|AUD|CHF|INR)?"#
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
    static func enqueue(
        _ item: MediaItem,
        in context: ModelContext,
        force: Bool = false,
        postsSuggestionNotification: Bool = true
    ) {
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
                SmartClassificationService.evaluate(
                    result,
                    for: item,
                    in: context,
                    postsSuggestionNotification: postsSuggestionNotification
                )
                let isReceipt = item.purpose == .receipt
                    || item.suggestedPurpose == .receipt
                    || SmartClassificationService.isHighConfidenceReceipt(result, text: result.text)
                if isReceipt {
                    if item.receiptMerchant.isEmpty { item.receiptMerchant = result.receiptMerchant }
                    if item.receiptAmount.isEmpty { item.receiptAmount = result.receiptAmount }
                    if item.receiptDate == nil { item.receiptDate = result.dates.first }
                }
                if PremiumAccess.isActive {
                    item.premiumAnalysisVersion = PremiumBackfillService.currentVersion
                }
                item.ocrStatus = .completed
            } catch {
                item.ocrStatus = .failed
            }
            try? context.save()
        }
    }
}

struct PremiumBackfillResult: Equatable {
    var analyzedFromStoredText = 0
    var enqueuedForOCR = 0
}

@MainActor
enum PremiumBackfillService {
    static let currentVersion = 1

    @discardableResult
    static func run(in context: ModelContext) async -> PremiumBackfillResult {
        guard PremiumAccess.isActive else { return PremiumBackfillResult() }

        CapturePresetService.upgradePremiumTemplates(in: context)
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        var summary = PremiumBackfillResult()

        for item in items where needsPremiumAnalysis(item) {
            guard item.kind == .photo, item.deletedAt == nil, item.analysisEnabled else { continue }
            let storedText = item.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !storedText.isEmpty else {
                OCRService.enqueue(
                    item,
                    in: context,
                    force: true,
                    postsSuggestionNotification: false
                )
                summary.enqueuedForOCR += 1
                await Task.yield()
                continue
            }

            let result = await OCRService.shared.analyzeStoredText(item.recognizedText)
            if item.classificationStatus == .none {
                item.classificationStatus = .pending
            }
            if item.classificationStatus == .pending {
                SmartClassificationService.evaluate(
                    result,
                    for: item,
                    in: context,
                    postsSuggestionNotification: false
                )
            }
            let isReceipt = item.purpose == .receipt
                || item.suggestedPurpose == .receipt
                || SmartClassificationService.isHighConfidenceReceipt(result, text: result.text)
            if isReceipt {
                if item.receiptMerchant.isEmpty { item.receiptMerchant = result.receiptMerchant }
                if item.receiptAmount.isEmpty { item.receiptAmount = result.receiptAmount }
                if item.receiptDate == nil { item.receiptDate = result.dates.first }
            }
            item.premiumAnalysisVersion = currentVersion
            summary.analyzedFromStoredText += 1
            await Task.yield()
        }
        try? context.save()
        return summary
    }

    private static func needsPremiumAnalysis(_ item: MediaItem) -> Bool {
        item.premiumAnalysisVersion < currentVersion
            || item.classificationStatus == .pending
    }
}

@MainActor
enum SmartClassificationService {
    struct AutomaticClassificationNotice: Identifiable, Equatable {
        let itemID: UUID
        let purpose: CapturePurpose

        var id: UUID { itemID }
    }

    private struct UndoSnapshot {
        let albumID: UUID?
        let purpose: CapturePurpose
        let analysisEnabled: Bool
        let primaryAction: PrimaryMediaAction
        let expirationType: RetentionPolicy
        let expirationDate: Date?
        let waitingForCompletion: Bool
        let classificationStatus: SmartClassificationStatus
        let suggestedPurpose: CapturePurpose?
        let suggestedAlbumID: UUID?
        let suggestedRetention: RetentionPolicy?
    }

    private static var undoSnapshots: [UUID: UndoSnapshot] = [:]

    static func evaluate(
        _ result: MediaAnalysisResult,
        for item: MediaItem,
        in context: ModelContext,
        postsSuggestionNotification: Bool = true
    ) {
        guard item.deletedAt == nil,
              item.classificationStatus == .pending else { return }

        let normalizedText = result.text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )

        let automaticPurpose: CapturePurpose? = if result.hasQRCode {
            .qr
        } else if isHighConfidenceReceipt(result, text: normalizedText) {
            .receipt
        } else {
            nil
        }

        if let automaticPurpose {
            if item.albumID == nil, item.purpose == .general {
                applyAutomatically(
                    automaticPurpose,
                    result: result,
                    to: item,
                    in: context,
                    postsNotification: postsSuggestionNotification
                )
            } else {
                item.classificationStatus = .none
                try? context.save()
            }
            return
        }

        guard PremiumAccess.isActive else {
            item.classificationStatus = .none
            try? context.save()
            return
        }

        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []

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
        if postsSuggestionNotification {
            NotificationCenter.default.post(name: .smartClassificationSuggested, object: item.id)
        }
    }

    @discardableResult
    static func undoAutomaticClassification(itemID: UUID, in context: ModelContext) -> Bool {
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        guard let item = items.first(where: { $0.id == itemID }) else { return false }
        return undoAutomaticClassification(item, in: context)
    }

    @discardableResult
    static func undoAutomaticClassification(_ item: MediaItem, in context: ModelContext) -> Bool {
        guard let snapshot = undoSnapshots.removeValue(forKey: item.id),
              item.classificationStatus == .applied else { return false }
        item.albumID = snapshot.albumID
        item.purpose = snapshot.purpose
        item.analysisEnabled = snapshot.analysisEnabled
        item.primaryAction = snapshot.primaryAction
        item.expirationType = snapshot.expirationType
        item.expirationDate = snapshot.expirationDate
        item.waitingForCompletion = snapshot.waitingForCompletion
        item.classificationStatus = snapshot.classificationStatus == .pending ? .dismissed : snapshot.classificationStatus
        item.suggestedPurpose = snapshot.suggestedPurpose
        item.suggestedAlbumID = snapshot.suggestedAlbumID
        item.suggestedRetention = snapshot.suggestedRetention
        try? context.save()
        return true
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
        guard !result.receiptAmount.isEmpty else { return false }

        let totalTerms = [
            "합계", "총액", "결제금액", "total", "amount", "summe", "gesamt", "importe",
            "合計", "总计", "總計", "الإجمالي", "المجموع"
        ]
        let paymentTerms = [
            "결제", "승인", "카드", "매출", "payment", "approved", "card", "paid",
            "zahlung", "bezahlt", "pago", "pagado", "paiement", "payé",
            "お支払", "カード", "支付", "付款", "مدفوع", "بطاقة"
        ]
        let receiptTerms = [
            "영수증", "현금영수증", "receipt", "invoice", "beleg", "quittung", "recibo",
            "factura", "reçu", "ticket", "領収", "レシート", "收据", "收據", "إيصال"
        ]
        let currencyTerms = [
            "₩", "￦", "$", "€", "£", "¥", "₹", "원", "krw", "usd", "eur", "gbp", "jpy",
            "cny", "rmb", "aed", "sar", "cad", "aud", "chf", "inr"
        ]
        let hasTotalTerm = totalTerms.contains { text.localizedCaseInsensitiveContains($0) }
        let hasPaymentTerm = paymentTerms.contains { text.localizedCaseInsensitiveContains($0) }
        let hasReceiptTerm = receiptTerms.contains { text.localizedCaseInsensitiveContains($0) }
        guard hasTotalTerm || hasPaymentTerm || hasReceiptTerm else { return false }

        let hasDate = !result.dates.isEmpty
        let hasMerchant = !result.receiptMerchant.isEmpty
        let hasEnoughLines = result.textLineCount >= 4
        let hasTextCoverage = (result.textCoverage ?? 0) >= 0.025
        let hasCurrency = currencyTerms.contains { text.localizedCaseInsensitiveContains($0) }
        guard hasReceiptTerm || hasPaymentTerm || (hasTotalTerm && hasDate && hasCurrency) else {
            return false
        }

        var score = 3
        if hasTotalTerm { score += 2 }
        if hasPaymentTerm { score += 1 }
        if hasReceiptTerm { score += 1 }
        if hasDate { score += 1 }
        if hasMerchant { score += 1 }
        if hasEnoughLines { score += 1 }
        if hasCurrency { score += 1 }
        if hasTextCoverage { score += 1 }

        let supportingSignals = [hasDate, hasMerchant, hasEnoughLines, hasCurrency, hasTextCoverage]
            .filter { $0 }.count
        return score >= 8 && supportingSignals >= 3
    }

    private static func applyAutomatically(
        _ purpose: CapturePurpose,
        result: MediaAnalysisResult,
        to item: MediaItem,
        in context: ModelContext,
        postsNotification: Bool
    ) {
        let snapshot = UndoSnapshot(
            albumID: item.albumID,
            purpose: item.purpose,
            analysisEnabled: item.analysisEnabled,
            primaryAction: item.primaryAction,
            expirationType: item.expirationType,
            expirationDate: item.expirationDate,
            waitingForCompletion: item.waitingForCompletion,
            classificationStatus: item.classificationStatus,
            suggestedPurpose: item.suggestedPurpose,
            suggestedAlbumID: item.suggestedAlbumID,
            suggestedRetention: item.suggestedRetention
        )
        item.albumID = nil
        item.templatePurpose = purpose
        item.analysisEnabled = true
        item.primaryAction = purpose == .receipt ? .shareAndComplete : .open
        RetentionService.apply(defaultRetention(for: purpose), to: item)
        item.suggestedPurpose = nil
        item.suggestedAlbumID = nil
        item.suggestedRetention = nil
        item.classificationStatus = .applied
        if purpose == .receipt {
            if item.receiptMerchant.isEmpty { item.receiptMerchant = result.receiptMerchant }
            if item.receiptAmount.isEmpty { item.receiptAmount = result.receiptAmount }
            if item.receiptDate == nil { item.receiptDate = result.dates.first }
        }
        try? context.save()
        undoSnapshots[item.id] = snapshot

        guard postsNotification else { return }
        let notice = AutomaticClassificationNotice(itemID: item.id, purpose: purpose)
        NotificationCenter.default.post(name: .automaticClassificationApplied, object: notice)
    }

    private static func isHighConfidenceDocument(_ result: MediaAnalysisResult) -> Bool {
        guard let textCoverage = result.textCoverage else { return false }
        return result.textLineCount >= 8
            && result.text.count >= 160
            && textCoverage >= 0.12
    }
}

private enum OCRServiceError: Error {
    case unreadableImage
}
