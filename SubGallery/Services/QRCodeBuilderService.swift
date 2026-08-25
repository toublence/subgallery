import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Security
import UIKit

/// The kinds of QR a user can author. Deliberately a short list: these are the
/// codes people actually need to show someone.
enum QRBuilderKind: String, CaseIterable, Identifiable {
    case url, wifi, text, contact, phone, email, location

    var id: String { rawValue }

    var title: String {
        switch self {
        case .url: L10n.text("웹사이트")
        case .wifi: "Wi-Fi"
        case .text: L10n.text("텍스트")
        case .contact: L10n.text("연락처")
        case .phone: L10n.text("전화")
        case .email: L10n.text("이메일")
        case .location: L10n.text("위치")
        }
    }

    var symbol: String {
        switch self {
        case .url: "globe"
        case .wifi: "wifi"
        case .text: "text.alignleft"
        case .contact: "person.crop.circle"
        case .phone: "phone"
        case .email: "envelope"
        case .location: "mappin.and.ellipse"
        }
    }
}

enum QRWiFiSecurity: String, CaseIterable, Identifiable {
    case wpa = "WPA"
    case wep = "WEP"
    case none = "nopass"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wpa: "WPA/WPA2"
        case .wep: "WEP"
        case .none: L10n.text("없음")
        }
    }
}

enum QRCodeBuilderError: LocalizedError {
    case invalidURL
    case emptyValue
    case invalidEmail
    case invalidCoordinate
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: L10n.text("http 또는 https로 시작하는 주소를 입력해 주세요.")
        case .emptyValue: L10n.text("내용을 입력해 주세요.")
        case .invalidEmail: L10n.text("올바른 이메일 주소를 입력해 주세요.")
        case .invalidCoordinate: L10n.text("올바른 좌표를 입력해 주세요.")
        case .renderFailed: L10n.text("QR 코드를 만들 수 없습니다.")
        }
    }
}

/// Everything the builder needs to describe one QR before it exists.
enum QRBuilderInput: Equatable {
    case url(String)
    case wifi(ssid: String, password: String, security: QRWiFiSecurity, isHidden: Bool)
    case text(String)
    case contact(name: String, phone: String, email: String, organization: String)
    case phone(String)
    case email(address: String, subject: String, body: String)
    case location(latitude: Double, longitude: Double)
}

// MARK: - Free usage

/// QR authoring is lighter than document building, so it gets a longer free run.
struct QRBuilderTrialPolicy: Equatable {
    static let freeUseLimit = 5
    private(set) var used: Int

    init(used: Int) {
        self.used = min(max(used, 0), Self.freeUseLimit)
    }

    var remaining: Int { max(0, Self.freeUseLimit - used) }
    var isLastFreeUse: Bool { remaining == 1 }
    func canBuild(isPremium: Bool) -> Bool { isPremium || remaining > 0 }

    func consumingIfEligible(isPremium: Bool) -> Self {
        guard !isPremium, remaining > 0 else { return self }
        return Self(used: used + 1)
    }
}

@MainActor
enum QRBuilderUsageStore {
    static let freeLimit = QRBuilderTrialPolicy.freeUseLimit

    private static let service = "com.namslab.subgallery.qr-builder"
    private static let account = "qrBuilderFreeUsesUsed"

    static var used: Int {
        guard let data = read(), let value = Int(String(decoding: data, as: UTF8.self)) else { return 0 }
        return QRBuilderTrialPolicy(used: value).used
    }

    static var remaining: Int { QRBuilderTrialPolicy(used: used).remaining }

    static func hasFreeUseAvailable(isPremium: Bool) -> Bool {
        QRBuilderTrialPolicy(used: used).canBuild(isPremium: isPremium)
    }

    static func isLastFreeUse(isPremium: Bool) -> Bool {
        !isPremium && QRBuilderTrialPolicy(used: used).isLastFreeUse
    }

    /// Called only once a generated QR has actually been saved into the library.
    @discardableResult
    static func recordSuccessfulSave(isPremium: Bool) -> Int {
        let current = QRBuilderTrialPolicy(used: used)
        let next = current.consumingIfEligible(isPremium: isPremium)
        guard next != current else { return current.remaining }
        write(next.used)
        return next.remaining
    }

    #if DEBUG
    static func configureForTesting(used value: Int) { write(value) }
    #endif

    private static func write(_ value: Int) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(String(value).utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func read() -> Data? {
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

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Builder

enum QRCodeBuilderService {
    /// Turns user input into the standard payload for its kind. This is the exact
    /// inverse of `QRContentService.parse`, and the payloads are the published
    /// formats other scanners expect — nothing app-specific.
    static func payload(for input: QRBuilderInput) throws -> String {
        switch input {
        case .url(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let normalized = OCRService.httpURLString(trimmed) else {
                throw QRCodeBuilderError.invalidURL
            }
            return normalized

        case .wifi(let ssid, let password, let security, let isHidden):
            let name = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw QRCodeBuilderError.emptyValue }
            var payload = "WIFI:T:\(security.rawValue);S:\(escapedWiFi(name));"
            if security != .none, !password.isEmpty {
                payload += "P:\(escapedWiFi(password));"
            }
            if isHidden { payload += "H:true;" }
            return payload + ";"

        case .text(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw QRCodeBuilderError.emptyValue }
            return trimmed

        case .contact(let name, let phone, let email, let organization):
            return try vCard(name: name, phone: phone, email: email, organization: organization)

        case .phone(let value):
            let digits = value.filter { $0.isNumber || $0 == "+" }
            guard !digits.isEmpty else { throw QRCodeBuilderError.emptyValue }
            return "tel:\(digits)"

        case .email(let address, let subject, let body):
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isEmailAddress(trimmed) else { throw QRCodeBuilderError.invalidEmail }
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = trimmed
            var query: [URLQueryItem] = []
            if !subject.isEmpty { query.append(URLQueryItem(name: "subject", value: subject)) }
            if !body.isEmpty { query.append(URLQueryItem(name: "body", value: body)) }
            if !query.isEmpty { components.queryItems = query }
            guard let string = components.string else { throw QRCodeBuilderError.invalidEmail }
            return string

        case .location(let latitude, let longitude):
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw QRCodeBuilderError.invalidCoordinate
            }
            return String(format: "geo:%.6f,%.6f", latitude, longitude)
        }
    }

    /// `;` `:` `,` and `\` all terminate or separate fields in the Wi-Fi format, so
    /// a password containing one has to be escaped or the network name breaks.
    static func escapedWiFi(_ value: String) -> String {
        var result = ""
        for character in value {
            if character == "\\" || character == ";" || character == ":" || character == "," {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    private static func vCard(
        name: String,
        phone: String,
        email: String,
        organization: String
    ) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOrg = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty || !trimmedPhone.isEmpty || !trimmedEmail.isEmpty else {
            throw QRCodeBuilderError.emptyValue
        }
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]
        if !trimmedName.isEmpty {
            lines.append("N:\(trimmedName);;;;")
            lines.append("FN:\(trimmedName)")
        }
        if !trimmedOrg.isEmpty { lines.append("ORG:\(trimmedOrg)") }
        if !trimmedPhone.isEmpty { lines.append("TEL;TYPE=CELL:\(trimmedPhone)") }
        if !trimmedEmail.isEmpty { lines.append("EMAIL:\(trimmedEmail)") }
        lines.append("END:VCARD")
        return lines.joined(separator: "\n")
    }

    private static func isEmailAddress(_ value: String) -> Bool {
        value.range(
            of: "^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    // MARK: - Rendering

    /// Core Image only — no service, no network. The generator emits a tiny bitmap
    /// (one pixel per module), so it is scaled with nearest-neighbour sampling;
    /// any smoothing here would blur the module edges and break scanning.
    static func image(for payload: String, size: CGFloat = 1024) throws -> UIImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        // Medium correction: enough resilience for a screen or a print without
        // inflating the module count so far that small renders stop scanning.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { throw QRCodeBuilderError.renderFailed }

        // The generator emits one pixel per module, so the raw extent IS the module
        // count — needed below to size the quiet zone in modules rather than pixels.
        let moduleCount = max(output.extent.width, 1)
        let scale = max(1, size / moduleCount)
        let scaled = output
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .samplingNearest()

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            throw QRCodeBuilderError.renderFailed
        }

        // Drawn onto white with a quiet zone: scanners need the margin, and a
        // transparent background renders as black-on-black in dark mode.
        //
        // The margin is four MODULES, as the QR spec requires — not a percentage of
        // the image. A short payload has few modules, so a percentage margin shrinks
        // below the required four and the code stops being readable; that made plain
        // URL codes, the most common kind, fail to scan.
        let quietZone = scale * 4
        let canvas = CGSize(
            width: scaled.extent.width + quietZone * 2,
            height: scaled.extent.height + quietZone * 2
        )
        return UIGraphicsImageRenderer(size: canvas).image { renderer in
            renderer.cgContext.interpolationQuality = .none
            UIColor.white.setFill()
            renderer.cgContext.fill(CGRect(origin: .zero, size: canvas))
            renderer.cgContext.draw(
                cgImage,
                in: CGRect(
                    x: quietZone,
                    y: quietZone,
                    width: scaled.extent.width,
                    height: scaled.extent.height
                )
            )
        }
    }

    static func defaultFileName(for kind: QRBuilderKind) -> String {
        "QR-\(kind.rawValue)-\(UUID().uuidString.prefix(8)).png"
    }
}
