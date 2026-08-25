import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case korean = "ko"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case japanese = "ja"
    case arabic = "ar"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.text("language.system")
        case .english: L10n.text("language.english")
        case .korean: L10n.text("language.korean")
        case .german: L10n.text("language.german")
        case .spanish: L10n.text("language.spanish")
        case .french: L10n.text("language.french")
        case .japanese: L10n.text("language.japanese")
        case .arabic: L10n.text("language.arabic")
        case .simplifiedChinese: L10n.text("language.chinese_simplified")
        case .traditionalChinese: L10n.text("language.chinese_traditional")
        }
    }

    var resolvedIdentifier: String {
        guard self == .system else { return rawValue }
        return Self.supportedIdentifier(for: Locale.preferredLanguages.first ?? "en") ?? "en"
    }

    var locale: Locale { Locale(identifier: resolvedIdentifier) }

    static var selected: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "app.language") ?? "system") ?? .system
    }

    private static func supportedIdentifier(for identifier: String) -> String? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        if normalized.hasPrefix("zh-Hant") || normalized.hasPrefix("zh-TW")
            || normalized.hasPrefix("zh-HK") || normalized.hasPrefix("zh-MO") { return "zh-Hant" }
        if normalized.hasPrefix("zh") { return "zh-Hans" }
        let language = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return ["en", "ko", "de", "es", "fr", "ja", "ar"].contains(language) ? language : nil
    }
}

enum L10n {
    static func text(_ key: String) -> String {
        let selected = AppLanguage.selected
        let bundle = localizedBundle(for: selected.resolvedIdentifier)
        let value = bundle?.localizedString(forKey: key, value: nil, table: nil)
        if let value, value != key { return value }
        if selected.resolvedIdentifier == "ko", key.range(of: "[가-힣]", options: .regularExpression) != nil {
            return key
        }
        return localizedBundle(for: "en")?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: AppLanguage.selected.locale, arguments: arguments)
    }

    /// `Date.formatted` follows the system locale, which is not the same thing as
    /// the language the user picked in Settings. Every user-facing date goes
    /// through here so it matches the rest of the interface.
    static func date(
        _ date: Date,
        dateStyle: Date.FormatStyle.DateStyle = .abbreviated,
        timeStyle: Date.FormatStyle.TimeStyle = .shortened
    ) -> String {
        date.formatted(
            Date.FormatStyle(date: dateStyle, time: timeStyle)
                .locale(AppLanguage.selected.locale)
        )
    }

    static func monthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().locale(AppLanguage.selected.locale))
    }

    private static func localizedBundle(for identifier: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}
