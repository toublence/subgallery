import Foundation

/// The amount a receipt was actually charged for, together with how confident the
/// extractor is about it. `nil` from the extractor means "could not tell" — never
/// a guess, because a wrong total is worse than no total.
struct ExtractedReceiptAmount: Equatable {
    let value: Decimal
    let currencyCode: String?
    let raw: String
    let score: Int
}

/// Picks the charged amount out of OCR text by looking at the *label* a number
/// belongs to, not merely at whether a line happens to contain a currency-ish
/// character. That distinction is the whole fix: `승인번호 822608619 승인금액
/// 15,100원` is one OCR line, and taking the first number on it yields the
/// approval *number*.
enum ReceiptAmountExtractor {
    private struct Label {
        let text: String
        let score: Int
    }

    /// Highest first — the list is scanned in this order so `승인금액` is matched
    /// before the looser `금액`.
    private static let amountLabels: [Label] = [
        Label(text: "승인금액", score: 100),
        Label(text: "실결제금액", score: 95),
        Label(text: "결제금액", score: 90),
        Label(text: "받을금액", score: 88),
        Label(text: "총결제금액", score: 85),
        Label(text: "총 결제금액", score: 85),
        Label(text: "청구금액", score: 85),
        Label(text: "판매금액", score: 78),
        Label(text: "grand total", score: 80),
        Label(text: "amount paid", score: 80),
        Label(text: "amount due", score: 78),
        Label(text: "total due", score: 78),
        Label(text: "합계금액", score: 74),
        Label(text: "총액", score: 70),
        Label(text: "합계", score: 70),
        Label(text: "total", score: 70),
        Label(text: "gesamt", score: 70),
        Label(text: "summe", score: 70),
        Label(text: "importe", score: 70),
        Label(text: "合計", score: 70),
        Label(text: "总计", score: 70),
        Label(text: "總計", score: 70),
        Label(text: "الإجمالي", score: 70),
        Label(text: "المجموع", score: 70),
        Label(text: "금액", score: 55)
    ]

    /// Labels whose numbers are identifiers. A number introduced by any of these is
    /// discarded outright, however money-like it looks.
    private static let excludedLabels = [
        "승인번호", "거래번호", "영수증번호", "주문번호", "카드번호", "가맹점번호",
        "사업자등록번호", "사업자번호", "전화번호", "회원번호", "일련번호", "단말기번호",
        "바코드", "포인트", "적립", "잔액",
        "approval", "auth no", "card no", "order no", "invoice no", "tel", "barcode"
    ]

    private static let currencyMarkers = ["₩", "￦", "원", "$", "€", "£", "¥", "₹"]

    /// Character pairs Vision routinely confuses on thermal receipt print. Applied
    /// to label matching only — never to the digits themselves.
    private static let ocrConfusions: [(String, String)] = [
        ("숭", "승"), ("싱", "승"), ("힙", "합"), ("겨", "결"), ("촐", "총")
    ]

    private static func normalizedForLabelMatching(_ text: String) -> String {
        ocrConfusions.reduce(text.lowercased()) { partial, pair in
            partial.replacingOccurrences(of: pair.0, with: pair.1)
        }
    }

    static func extract(
        from text: String,
        locale: Locale = AppLanguage.selected.locale
    ) -> ExtractedReceiptAmount? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var best: ExtractedReceiptAmount?
        for (index, line) in lines.enumerated() {
            for candidate in candidates(in: line, at: index, of: lines) {
                if best == nil || candidate.score > best!.score { best = candidate }
            }
        }
        return best
    }

    /// Convenience for the display layer: the canonical amount string to persist.
    static func canonicalAmountString(from text: String) -> String {
        guard let extracted = extract(from: text) else { return "" }
        return extracted.raw
    }

    // MARK: - Candidate discovery

    private static func candidates(
        in line: String,
        at index: Int,
        of lines: [String]
    ) -> [ExtractedReceiptAmount] {
        // Same length as `line` — the substitutions are all single scalars — so
        // offsets found here map straight back onto the original text.
        let lowercased = normalizedForLabelMatching(line)
        var results: [ExtractedReceiptAmount] = []

        for label in amountLabels {
            var searchStart = lowercased.startIndex
            while let labelRange = lowercased.range(
                of: label.text.lowercased(),
                range: searchStart..<lowercased.endIndex
            ) {
                searchStart = labelRange.upperBound
                // `승인번호` also contains `번호`; make sure this occurrence is not
                // sitting inside an excluded label.
                guard !isInsideExcludedLabel(lowercased, at: labelRange) else { continue }
                // `결제금액` is also a substring of `실결제금액` and
                // `총결제금액`. Let the full, more specific label own the value so
                // the documented priority order is preserved across different lines.
                guard !isInsideMoreSpecificAmountLabel(
                    lowercased,
                    at: labelRange,
                    current: label.text
                ) else { continue }

                let tailIndex = line.index(
                    line.startIndex,
                    offsetBy: lowercased.distance(from: lowercased.startIndex, to: labelRange.upperBound)
                )
                let tail = String(line[tailIndex...])
                if let number = firstNumber(in: tail) {
                    results.append(scored(number, label: label, line: tail))
                    continue
                }
                // Layout OCR often breaks `승인금액` and its value onto separate
                // lines; look a little further before giving up.
                for offset in 1...2 where index + offset < lines.count {
                    let next = lines[index + offset]
                    guard !containsExcludedLabel(normalizedForLabelMatching(next)) else { continue }
                    if let number = firstNumber(in: next) {
                        results.append(scored(number, label: label, line: next))
                        break
                    }
                }
            }
        }

        // No label anywhere: accept a number only when it carries its own currency
        // marker, and never one that an identifier label introduced.
        if results.isEmpty, !containsExcludedLabel(lowercased) {
            if let number = firstNumber(in: line), hasCurrencyMarker(line) {
                results.append(
                    ExtractedReceiptAmount(
                        value: number.value,
                        currencyCode: currencyCode(near: line),
                        raw: number.raw,
                        score: 20
                    )
                )
            }
        }
        return results
    }

    private static func scored(
        _ number: (value: Decimal, raw: String),
        label: Label,
        line: String
    ) -> ExtractedReceiptAmount {
        let bonus = hasCurrencyMarker(line) ? 10 : 0
        return ExtractedReceiptAmount(
            value: number.value,
            currencyCode: currencyCode(near: line),
            raw: number.raw,
            score: label.score + bonus
        )
    }

    private static func isInsideExcludedLabel(_ lowercased: String, at range: Range<String.Index>) -> Bool {
        for excluded in excludedLabels {
            var start = lowercased.startIndex
            while let found = lowercased.range(of: excluded, range: start..<lowercased.endIndex) {
                if found.lowerBound <= range.lowerBound && range.upperBound <= found.upperBound { return true }
                start = found.upperBound
            }
        }
        return false
    }

    private static func isInsideMoreSpecificAmountLabel(
        _ lowercased: String,
        at range: Range<String.Index>,
        current: String
    ) -> Bool {
        for label in amountLabels where label.text.count > current.count {
            var start = lowercased.startIndex
            while let found = lowercased.range(
                of: label.text.lowercased(),
                range: start..<lowercased.endIndex
            ) {
                if found.lowerBound <= range.lowerBound && range.upperBound <= found.upperBound {
                    return true
                }
                start = found.upperBound
            }
        }
        return false
    }

    private static func containsExcludedLabel(_ lowercased: String) -> Bool {
        excludedLabels.contains { lowercased.contains($0) }
    }

    private static func hasCurrencyMarker(_ text: String) -> Bool {
        let uppercased = text.uppercased()
        return currencyMarkers.contains { text.contains($0) }
            || ["KRW", "USD", "EUR", "GBP", "JPY", "CNY"].contains { uppercased.contains($0) }
    }

    private static func currencyCode(near text: String) -> String? {
        let uppercased = text.uppercased()
        for code in ["KRW", "USD", "EUR", "GBP", "JPY", "CNY"] where uppercased.contains(code) {
            return code
        }
        if text.contains("₩") || text.contains("￦") || text.contains("원") { return "KRW" }
        if text.contains("€") { return "EUR" }
        if text.contains("£") { return "GBP" }
        if text.contains("¥") { return "JPY" }
        if text.contains("₹") { return "INR" }
        if text.contains("$") { return "USD" }
        return nil
    }

    // MARK: - Number scanning

    /// Matches money-shaped runs only. Deliberately refuses to span `-`, `/` or `:`
    /// so a date, a phone number, a business registration number or a hyphenated
    /// card number can never be read as one value.
    /// Grouped forms first so a whole value is consumed before the loose fallbacks
    /// get a chance to bite off a prefix. Both `1,234.56` and `1.234,56` are read
    /// in full rather than clipped.
    private static let numberExpression = try? NSRegularExpression(
        pattern: #"\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{2})?|\d+"#
    )

    private static func firstNumber(in text: String) -> (value: Decimal, raw: String)? {
        guard let expression = numberExpression else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let raw = String(text[matchRange])
            guard isPlausibleAmount(raw, in: text, at: matchRange) else { continue }
            guard let value = ReceiptSummaryService.numericValue(in: raw) else { continue }
            return (value, raw)
        }
        return nil
    }

    private static func isPlausibleAmount(
        _ raw: String,
        in text: String,
        at range: Range<String.Index>
    ) -> Bool {
        // Part of a longer run that the match did not consume. `-` `/` `:` mean a
        // date, a card or an ID; `,` and `.` mean the grouping is malformed — OCR
        // clipped `15,100` to `15,1`, and taking `15` from it would be inventing a
        // total that is off by three orders of magnitude.
        let separators: Set<Character> = ["-", "/", ":", "*", ",", "."]
        if range.lowerBound > text.startIndex,
           separators.contains(text[text.index(before: range.lowerBound)]) {
            return false
        }
        if range.upperBound < text.endIndex, separators.contains(text[range.upperBound]) {
            return false
        }
        // A digit immediately outside the match means the pattern under-consumed the
        // run, so what was captured is a fragment of a larger number.
        if range.lowerBound > text.startIndex, text[text.index(before: range.lowerBound)].isNumber {
            return false
        }
        if range.upperBound < text.endIndex, text[range.upperBound].isNumber { return false }
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return false }
        // An unpunctuated run this long is an identifier, not a price. Grouped
        // values like 1,234,567 keep their separators and are unaffected.
        if !raw.contains(","), digits.count >= 8 { return false }
        return true
    }
}
