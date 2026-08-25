import Foundation
import Security

/// A receipt total that knows which currency it is in. Keeping the currency
/// attached is the whole point: a ₩ and a $ receipt must never land in the same
/// sum just because both parsed to a number.
struct ReceiptAmount: Equatable {
    let currencyCode: String
    let value: Decimal

    func formatted(locale: Locale = AppLanguage.selected.locale) -> String {
        value.formatted(.currency(code: currencyCode).locale(locale))
    }
}

struct ReceiptCurrencyTotal: Equatable, Identifiable {
    let currencyCode: String
    let value: Decimal

    var id: String { currencyCode }

    func formatted(locale: Locale = AppLanguage.selected.locale) -> String {
        value.formatted(.currency(code: currencyCode).locale(locale))
    }
}

struct ReceiptSummary: Equatable {
    let count: Int
    let totals: [ReceiptCurrencyTotal]
    /// Receipts whose amount could not be read. Surfaced rather than hidden, so a
    /// total is never quietly wrong.
    let unreadableAmountCount: Int

    var hasMixedCurrencies: Bool { totals.count > 1 }
    var isEmpty: Bool { count == 0 }
}

enum ReceiptSummaryService {
    /// Currency written as a symbol or a code somewhere in the captured string.
    private static let symbolCodes: [(String, String)] = [
        ("₩", "KRW"), ("￦", "KRW"), ("원", "KRW"),
        ("€", "EUR"), ("£", "GBP"), ("¥", "JPY"), ("₹", "INR"), ("$", "USD")
    ]
    private static let literalCodes = [
        "KRW", "USD", "EUR", "GBP", "JPY", "CNY", "RMB",
        "AED", "SAR", "CAD", "AUD", "CHF", "INR"
    ]

    /// The currency assumed when a receipt shows only digits — overwhelmingly the
    /// common case on a domestic receipt. It is only ever an assumption about which
    /// bucket to use; if any receipt names a different currency the summary splits
    /// per currency instead of pretending they are comparable.
    static func defaultCurrencyCode(locale: Locale = AppLanguage.selected.locale) -> String {
        locale.currency?.identifier ?? "KRW"
    }

    static func amount(
        from raw: String,
        locale: Locale = AppLanguage.selected.locale
    ) -> ReceiptAmount? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isTrustedStoredAmount(trimmed),
              let value = numericValue(in: trimmed) else { return nil }
        let code = currencyCode(in: trimmed) ?? defaultCurrencyCode(locale: locale)
        return ReceiptAmount(currencyCode: code, value: value)
    }

    /// The persisted receipt field is the single source of truth shared by the
    /// list, detail and report. OCR extraction and manual edits both write here.
    static func amount(
        for item: MediaItem,
        locale: Locale = AppLanguage.selected.locale
    ) -> ReceiptAmount? {
        amount(from: item.receiptAmount, locale: locale)
    }

    static func summary(
        for items: [MediaItem],
        locale: Locale = AppLanguage.selected.locale
    ) -> ReceiptSummary {
        var totals: [String: Decimal] = [:]
        var unreadable = 0
        for item in items {
            guard let parsed = amount(for: item, locale: locale) else {
                unreadable += 1
                continue
            }
            totals[parsed.currencyCode, default: 0] += parsed.value
        }
        return ReceiptSummary(
            count: items.count,
            totals: totals
                .map { ReceiptCurrencyTotal(currencyCode: $0.key, value: $0.value) }
                .sorted { $0.currencyCode < $1.currencyCode },
            unreadableAmountCount: unreadable
        )
    }

    // MARK: - Parsing

    /// Rejects a bare long digit run before it reaches any report calculation.
    /// Approval/card/transaction numbers are commonly stored this way by older
    /// extractor generations; real large amounts normally retain a currency or
    /// grouping separator.
    private static func isTrustedStoredAmount(_ value: String) -> Bool {
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else { return false }
        let hasCurrency = currencyCode(in: value) != nil
        let hasGroupingOrDecimal = value.contains(",") || value.contains(".")
        if digits.count >= 8 && !hasCurrency && !hasGroupingOrDecimal { return false }

        let numericRuns = value.split { !$0.isNumber && $0 != "," && $0 != "." }
            .filter { $0.contains(where: \.isNumber) }
        return numericRuns.count == 1
    }

    private static func currencyCode(in value: String) -> String? {
        let uppercased = value.uppercased()
        if let code = literalCodes.first(where: { uppercased.contains($0) }) {
            return code == "RMB" ? "CNY" : code
        }
        return symbolCodes.first { value.contains($0.0) }?.1
    }

    /// Reads the number out of strings like `₩8,500`, `12,000원`, `TOTAL $12.34`
    /// or `1.234,56`. The final separator decides whether it is decimal or a
    /// thousands mark: a two-digit tail means cents, anything else means grouping.
    static func numericValue(in value: String) -> Decimal? {
        let digitsAndSeparators = value.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard digitsAndSeparators.contains(where: \.isNumber) else { return nil }

        var integerPart = digitsAndSeparators
        var fractionPart = ""
        if let lastSeparator = digitsAndSeparators.lastIndex(where: { $0 == "." || $0 == "," }) {
            let tail = String(digitsAndSeparators[digitsAndSeparators.index(after: lastSeparator)...])
            if tail.count == 2 && tail.allSatisfy(\.isNumber) {
                integerPart = String(digitsAndSeparators[..<lastSeparator])
                fractionPart = tail
            }
        }
        let digits = integerPart.filter(\.isNumber)
        guard !digits.isEmpty || !fractionPart.isEmpty else { return nil }

        // Built from an integer significand and an exponent rather than
        // `Decimal(string:)`, which routes through Double and turns 1234.56 into
        // 1234.5599999999997952. Money must not pick up binary rounding.
        let combined = "\(digits)\(fractionPart)"
        guard combined.count <= 18, let significand = UInt64(combined) else { return nil }
        return Decimal(
            sign: .plus,
            exponent: -fractionPart.count,
            significand: Decimal(significand)
        )
    }
}

// MARK: - Free report access

struct ReceiptReportTrialPolicy: Equatable {
    static let freeUseLimit = 15

    private(set) var used: Int

    init(used: Int) {
        self.used = min(max(used, 0), Self.freeUseLimit)
    }

    var remaining: Int { max(0, Self.freeUseLimit - used) }

    func canOpen(isPremium: Bool, hasReceiptData: Bool) -> Bool {
        isPremium || !hasReceiptData || remaining > 0
    }

    func consumingIfEligible(isPremium: Bool, didRenderReport: Bool) -> Self {
        guard !isPremium, didRenderReport, remaining > 0 else { return self }
        return Self(used: used + 1)
    }
}

@MainActor
enum ReceiptReportUsageStore {
    private static let service = "com.namslab.subgallery.receipt-report"
    private static let account = "receiptReportFreeUsesUsed"

    static var used: Int {
        guard let data = data(), let string = String(data: data, encoding: .utf8),
              let value = Int(string) else { return 0 }
        return ReceiptReportTrialPolicy(used: value).used
    }

    static var remaining: Int { ReceiptReportTrialPolicy(used: used).remaining }

    static func canOpen(isPremium: Bool, hasReceiptData: Bool) -> Bool {
        ReceiptReportTrialPolicy(used: used)
            .canOpen(isPremium: isPremium, hasReceiptData: hasReceiptData)
    }

    /// Returns the remaining count. Calling it repeatedly in one report session
    /// is harmless when the caller guards the session with its local consumed flag.
    @discardableResult
    static func consumeIfEligible(isPremium: Bool, didRenderReport: Bool) -> Int {
        let current = ReceiptReportTrialPolicy(used: used)
        let next = current.consumingIfEligible(
            isPremium: isPremium,
            didRenderReport: didRenderReport
        )
        guard next != current else { return current.remaining }
        set(next.used)
        return next.remaining
    }

    private static func set(_ value: Int) {
        let payload = Data(String(value).utf8)
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updates: [String: Any] = [kSecValueData as String: payload]
        let status = SecItemUpdate(match as CFDictionary, updates as CFDictionary)
        guard status == errSecItemNotFound else { return }

        var insert = match
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insert[kSecValueData as String] = payload
        SecItemAdd(insert as CFDictionary, nil)
    }

    private static func data() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
