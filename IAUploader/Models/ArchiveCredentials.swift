import Foundation

/// Credentials for the Internet Archive S3-like API.
///
/// The password is never stored. When a user signs in with an email and
/// password, the xauthn service returns short-lived cookies plus the
/// account's S3 access/secret keys. Only the S3 keys are persisted.
struct ArchiveCredentials: Codable, Equatable, Sendable {
    var accessKey: String
    var secretKey: String
    var screenName: String?
    var email: String?
    var itemName: String?

    var displayName: String {
        if let name = screenName?.trimmedNonEmpty { return name }
        if let name = itemName?.trimmedNonEmpty { return name }
        if let email = email?.trimmedNonEmpty { return email }
        return "Internet Archive account"
    }

    var isS3Only: Bool {
        screenName?.trimmedNonEmpty == nil && email?.trimmedNonEmpty == nil
    }

    var authorizationHeader: String {
        "LOW \(accessKey):\(secretKey)"
    }

    var hasUsableKeys: Bool {
        !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
