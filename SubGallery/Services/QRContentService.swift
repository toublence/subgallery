import Foundation

enum QRContentType: String, Codable, CaseIterable {
    case url
    case text
    case phone
    case email
    case wifi
    case contact
    case location
    case sms
    case unknown

    var title: String {
        switch self {
        case .url: L10n.text("링크")
        case .text: L10n.text("텍스트")
        case .phone: L10n.text("전화번호")
        case .email: L10n.text("이메일")
        case .wifi: "Wi-Fi"
        case .contact: L10n.text("연락처")
        case .location: L10n.text("위치")
        case .sms: L10n.text("문자")
        case .unknown: L10n.text("QR 코드")
        }
    }

    var symbol: String {
        switch self {
        case .url: "link"
        case .text: "text.alignleft"
        case .phone: "phone.fill"
        case .email: "envelope.fill"
        case .wifi: "wifi"
        case .contact: "person.crop.circle.fill"
        case .location: "mappin.and.ellipse"
        case .sms: "message.fill"
        case .unknown: "qrcode"
        }
    }
}

/// What the card's trailing button does. The value it operates on travels in
/// `QRContentInfo.actionValue` so the view never re-parses the payload.
enum QRAction: String, Equatable {
    case open
    case copy
    case call
    case mail
    case message
    case map

    var title: String {
        switch self {
        case .open: L10n.text("열기")
        case .copy: L10n.text("복사")
        case .call: L10n.text("전화")
        case .mail: L10n.text("메일")
        case .message: L10n.text("문자")
        case .map: L10n.text("지도")
        }
    }

    var symbol: String {
        switch self {
        case .open: "safari"
        case .copy: "doc.on.doc"
        case .call: "phone"
        case .mail: "envelope"
        case .message: "message"
        case .map: "map"
        }
    }
}

struct QRCoordinate: Equatable {
    let latitude: Double
    let longitude: Double
}

struct QRContentInfo: Equatable, Identifiable {
    struct Field: Equatable, Identifiable {
        let label: String
        let value: String
        /// Wi-Fi passwords and the like are copyable but never printed in a list.
        var isSensitive = false

        var id: String { "\(label)\u{1F}\(value)" }
    }

    let type: QRContentType
    let title: String
    /// Safe for list display — never contains a secret.
    let subtitle: String
    let rawValue: String
    let primaryAction: QRAction
    let actionValue: String
    var coordinate: QRCoordinate?
    var fields: [Field] = []

    var id: String { rawValue }
}

/// Turns a raw QR payload into something displayable. Prefix matching, URLComponents
/// and small regexes only — no network, no model, fully deterministic so the same
/// payload always renders the same card.
enum QRContentService {
    static func parse(_ payload: String) -> QRContentInfo {
        let raw = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return QRContentInfo(
                type: .unknown,
                title: QRContentType.unknown.title,
                subtitle: "",
                rawValue: payload,
                primaryAction: .copy,
                actionValue: payload
            )
        }

        let lowercased = raw.lowercased()
        if lowercased.hasPrefix("wifi:") { return wifi(raw) }
        if lowercased.hasPrefix("begin:vcard") { return vCard(raw) }
        if lowercased.hasPrefix("mecard:") { return meCard(raw) }
        if lowercased.hasPrefix("tel:") { return phone(raw, number: String(raw.dropFirst(4))) }
        if lowercased.hasPrefix("smsto:") { return sms(raw, body: String(raw.dropFirst(6))) }
        if lowercased.hasPrefix("sms:") { return sms(raw, body: String(raw.dropFirst(4))) }
        if lowercased.hasPrefix("mailto:") { return email(raw, address: String(raw.dropFirst(7))) }
        if lowercased.hasPrefix("geo:") { return geo(raw) }
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") { return url(raw) }
        if isEmailAddress(raw) { return email(raw, address: raw) }
        if let number = barePhoneNumber(raw) { return phone(raw, number: number) }
        if hasUnhandledScheme(raw) {
            return QRContentInfo(
                type: .unknown,
                title: QRContentType.unknown.title,
                subtitle: raw,
                rawValue: raw,
                primaryAction: .copy,
                actionValue: raw,
                fields: [Field(label: L10n.text("내용"), value: raw)]
            )
        }
        return text(raw)
    }

    static func parseAll(_ payloads: [String]) -> [QRContentInfo] {
        payloads.map(parse)
    }

    /// Extra terms the library search should match on beyond the raw payload —
    /// domain, SSID, contact name and so on.
    static func searchTerms(for payloads: [String]) -> [String] {
        parseAll(payloads).flatMap { info -> [String] in
            [info.title, info.subtitle] + info.fields.filter { !$0.isSensitive }.map(\.value)
        }
    }

    // MARK: - Type builders

    private typealias Field = QRContentInfo.Field

    private static func url(_ raw: String) -> QRContentInfo {
        // The host is the only part safe to present as a name. Anything friendlier
        // would mean guessing which brand owns a domain, which is exactly the kind
        // of hardcoding this pipeline avoids.
        let host = URLComponents(string: raw)?.host?
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        return QRContentInfo(
            type: .url,
            title: host?.isEmpty == false ? host! : QRContentType.url.title,
            subtitle: raw,
            rawValue: raw,
            primaryAction: .open,
            actionValue: raw,
            fields: [Field(label: L10n.text("주소"), value: raw)]
        )
    }

    private static func text(_ raw: String) -> QRContentInfo {
        QRContentInfo(
            type: .text,
            title: QRContentType.text.title,
            subtitle: raw,
            rawValue: raw,
            primaryAction: .copy,
            actionValue: raw,
            fields: [Field(label: L10n.text("내용"), value: raw)]
        )
    }

    private static func phone(_ raw: String, number: String) -> QRContentInfo {
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        return QRContentInfo(
            type: .phone,
            title: QRContentType.phone.title,
            subtitle: trimmed,
            rawValue: raw,
            primaryAction: .call,
            actionValue: trimmed,
            fields: [Field(label: L10n.text("전화번호"), value: trimmed)]
        )
    }

    private static func email(_ raw: String, address: String) -> QRContentInfo {
        // mailto: may carry ?subject=&body=; the address is everything before it.
        let components = URLComponents(string: raw)
        let queryItems = components?.queryItems ?? []
        let addressOnly = address.components(separatedBy: "?").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? address
        var fields = [Field(label: L10n.text("주소"), value: addressOnly)]
        if let subject = queryItems.first(where: { $0.name.lowercased() == "subject" })?.value,
           !subject.isEmpty {
            fields.append(Field(label: L10n.text("제목"), value: subject))
        }
        return QRContentInfo(
            type: .email,
            title: QRContentType.email.title,
            subtitle: addressOnly,
            rawValue: raw,
            primaryAction: .mail,
            actionValue: addressOnly,
            fields: fields
        )
    }

    private static func sms(_ raw: String, body: String) -> QRContentInfo {
        // Both `sms:number?body=` and `SMSTO:number:message` appear in the wild.
        let parts = body.components(separatedBy: CharacterSet(charactersIn: ":?"))
        let number = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = parts.count > 1
            ? parts.dropFirst().joined(separator: ":")
                .replacingOccurrences(of: "body=", with: "")
                .removingPercentEncoding ?? ""
            : ""
        var fields = [Field(label: L10n.text("전화번호"), value: number)]
        if !message.isEmpty { fields.append(Field(label: L10n.text("내용"), value: message)) }
        return QRContentInfo(
            type: .sms,
            title: QRContentType.sms.title,
            subtitle: message.isEmpty ? number : "\(number) · \(message)",
            rawValue: raw,
            primaryAction: .message,
            actionValue: number,
            fields: fields
        )
    }

    private static func geo(_ raw: String) -> QRContentInfo {
        // geo:lat,lon[,alt][?q=label]
        let body = String(raw.dropFirst(4)).components(separatedBy: "?").first ?? ""
        let numbers = body.components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count >= 2 else { return text(raw) }
        let coordinate = QRCoordinate(latitude: numbers[0], longitude: numbers[1])
        let formatted = String(format: "%.6f, %.6f", numbers[0], numbers[1])
        return QRContentInfo(
            type: .location,
            title: QRContentType.location.title,
            subtitle: formatted,
            rawValue: raw,
            primaryAction: .map,
            actionValue: formatted,
            coordinate: coordinate,
            fields: [Field(label: L10n.text("좌표"), value: formatted)]
        )
    }

    private static func wifi(_ raw: String) -> QRContentInfo {
        let values = keyedSegments(String(raw.dropFirst(5)))
        let ssid = values["S"] ?? ""
        let security = (values["T"] ?? "").uppercased()
        let password = values["P"] ?? ""
        let isHidden = (values["H"] ?? "").lowercased() == "true"

        let securityTitle = security.isEmpty || security == "NOPASS"
            ? L10n.text("보안 없음")
            : security
        var fields = [
            Field(label: "SSID", value: ssid),
            Field(label: L10n.text("보안"), value: securityTitle)
        ]
        if !password.isEmpty {
            fields.append(Field(label: L10n.text("비밀번호"), value: password, isSensitive: true))
        }
        if isHidden { fields.append(Field(label: L10n.text("숨김 네트워크"), value: L10n.text("예"))) }

        return QRContentInfo(
            type: .wifi,
            title: "Wi-Fi",
            // Deliberately SSID + security only: the password must not reach a list row.
            subtitle: ssid.isEmpty ? securityTitle : "\(ssid) · \(securityTitle)",
            rawValue: raw,
            primaryAction: .copy,
            actionValue: ssid.isEmpty ? raw : ssid,
            fields: fields
        )
    }

    private static func vCard(_ raw: String) -> QRContentInfo {
        var name = ""
        var organization = ""
        var phones: [String] = []
        var emails: [String] = []

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            // Properties can carry parameters: `TEL;TYPE=CELL:010-0000-0000`.
            let property = String(trimmed[..<separator]).components(separatedBy: ";")[0].uppercased()
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch property {
            case "FN": name = value
            case "N" where name.isEmpty:
                name = value.components(separatedBy: ";").filter { !$0.isEmpty }
                    .reversed().joined(separator: " ")
            case "ORG": organization = value.components(separatedBy: ";")[0]
            case "TEL": phones.append(value)
            case "EMAIL": emails.append(value)
            default: break
            }
        }
        return contact(raw, name: name, organization: organization, phones: phones, emails: emails)
    }

    private static func meCard(_ raw: String) -> QRContentInfo {
        let values = keyedSegments(String(raw.dropFirst(7)))
        // MECARD names arrive as `Last,First`.
        let name = (values["N"] ?? "").components(separatedBy: ",")
            .filter { !$0.isEmpty }.reversed().joined(separator: " ")
        return contact(
            raw,
            name: name,
            organization: values["ORG"] ?? "",
            phones: [values["TEL"] ?? ""].filter { !$0.isEmpty },
            emails: [values["EMAIL"] ?? ""].filter { !$0.isEmpty }
        )
    }

    private static func contact(
        _ raw: String,
        name: String,
        organization: String,
        phones: [String],
        emails: [String]
    ) -> QRContentInfo {
        var fields: [Field] = []
        if !name.isEmpty { fields.append(Field(label: L10n.text("이름"), value: name)) }
        if !organization.isEmpty { fields.append(Field(label: L10n.text("회사"), value: organization)) }
        fields += phones.map { Field(label: L10n.text("전화번호"), value: $0) }
        fields += emails.map { Field(label: L10n.text("이메일"), value: $0) }

        let subtitle = [name, phones.first, organization].compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let action: QRAction = phones.first != nil ? .call : (emails.first != nil ? .mail : .copy)
        return QRContentInfo(
            type: .contact,
            title: name.isEmpty ? QRContentType.contact.title : name,
            subtitle: subtitle.isEmpty ? QRContentType.contact.title : subtitle,
            rawValue: raw,
            primaryAction: action,
            actionValue: phones.first ?? emails.first ?? raw,
            fields: fields
        )
    }

    // MARK: - Primitives

    /// Splits `K:V;K:V;;` payloads used by both WIFI and MECARD, honouring the
    /// backslash escapes those formats allow inside values.
    private static func keyedSegments(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var escaped = false

        func commit() {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces).uppercased()
            if !trimmedKey.isEmpty, result[trimmedKey] == nil { result[trimmedKey] = value }
            key = ""
            value = ""
            readingKey = true
        }

        for character in body {
            if escaped {
                if readingKey { key.append(character) } else { value.append(character) }
                escaped = false
                continue
            }
            switch character {
            case "\\": escaped = true
            case ":" where readingKey: readingKey = false
            case ";": commit()
            default:
                if readingKey { key.append(character) } else { value.append(character) }
            }
        }
        commit()
        return result
    }

    private static func isEmailAddress(_ value: String) -> Bool {
        value.range(
            of: "^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Only treats a bare string as a phone number when it is nothing but dialling
    /// characters, so an order number or a serial does not become a call button.
    private static func barePhoneNumber(_ value: String) -> String? {
        guard value.range(of: "^\\+?[0-9][0-9 ().-]{6,19}$", options: .regularExpression) != nil else {
            return nil
        }
        let digits = value.filter(\.isNumber)
        return digits.count >= 7 ? value : nil
    }

    private static func hasUnhandledScheme(_ value: String) -> Bool {
        guard let match = value.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) else {
            return false
        }
        // A bare "10:30" is text, not a URI scheme.
        return value[match].count > 2
    }
}
