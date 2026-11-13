import Foundation

/// Rules for archive.org item identifiers.
///
/// The metadata schema allows 5-100 characters from the Roman alphabet,
/// digits, periods, underscores, and dashes, and requires the first
/// character to be alphanumeric.
enum IdentifierRules {
    static let minLength = 5
    static let maxLength = 100

    private static let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    static func issue(for identifier: String) -> IdentifierIssue? {
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .empty }
        if value.count < minLength { return .tooShort }
        if value.count > maxLength { return .tooLong }
        guard let first = value.unicodeScalars.first, isAlphanumeric(first) else {
            return .mustStartAlphanumeric
        }
        if value.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return .invalidCharacters
        }
        return nil
    }

    static func isValid(_ identifier: String) -> Bool {
        issue(for: identifier) == nil
    }

    /// Turns arbitrary text into a valid, readable identifier.
    static func suggestion(from text: String, fallback: String = "untitled") -> String {
        let folded = text.folding(
            options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var result = ""
        var lastWasSeparator = false
        for scalar in folded.lowercased().unicodeScalars {
            if isAlphanumeric(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if scalar == "." || scalar == "_" {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append("-")
                lastWasSeparator = true
            }
        }
        while result.hasPrefix("-") || result.hasPrefix(".") || result.hasPrefix("_") {
            result.removeFirst()
        }
        while result.hasSuffix("-") || result.hasSuffix(".") || result.hasSuffix("_") {
            result.removeLast()
        }
        if result.isEmpty { result = fallback }
        if result.count < minLength {
            result += "-item"
        }
        if result.count > 80 {
            result = String(result.prefix(80))
            while result.hasSuffix("-") || result.hasSuffix(".") || result.hasSuffix("_") {
                result.removeLast()
            }
        }
        return result
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}

enum IdentifierIssue: Equatable {
    case empty
    case tooShort
    case tooLong
    case invalidCharacters
    case mustStartAlphanumeric

    var message: String {
        switch self {
        case .empty:
            return "Enter an identifier."
        case .tooShort:
            return "Use at least \(IdentifierRules.minLength) characters."
        case .tooLong:
            return "Use at most \(IdentifierRules.maxLength) characters."
        case .invalidCharacters:
            return "Use only letters, numbers, periods, underscores, and dashes."
        case .mustStartAlphanumeric:
            return "Start with a letter or number."
        }
    }
}
