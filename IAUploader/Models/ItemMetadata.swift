import Foundation

struct CustomMetadataField: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var key: String = ""
    var value: String = ""

    var normalizedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValidKey: Bool {
        let key = normalizedKey
        guard !key.isEmpty, key.count <= 64 else { return false }
        guard let first = key.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        return key.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
        }
    }
}

/// Everything needed to describe a new archive.org item.
struct ItemMetadata: Codable, Equatable, Sendable {
    var title: String = ""
    var identifier: String = ""
    var creator: String = ""
    var date: String = ""
    var descriptionText: String = ""
    var subjects: [String] = []
    var collections: String = ""
    var language: String = "eng"
    var licenseURL: String = ""
    var mediatype: Mediatype = .texts
    var isTestItem: Bool = false
    var customFields: [CustomMetadataField] = []

    var parsedSubjects: [String] {
        Self.splitList(subjects.joined(separator: ","))
    }

    var parsedCollections: [String] {
        Self.splitList(collections)
    }

    var effectiveCollections: [String] {
        isTestItem ? ["test_collection"] : parsedCollections
    }

    var issues: [MetadataIssue] {
        var issues: [MetadataIssue] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(MetadataIssue(id: "title", field: .title, message: "Add a title for this item."))
        }
        if let identifierIssue = IdentifierRules.issue(for: identifier) {
            issues.append(MetadataIssue(id: "identifier", field: .identifier, message: identifierIssue.message))
        }
        if descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(MetadataIssue(id: "description", field: .description, message: "Add a description so people can find and understand this item."))
        }
        if parsedSubjects.isEmpty {
            issues.append(MetadataIssue(id: "subjects", field: .subjects, message: "Add at least one subject tag."))
        }
        for field in customFields where !field.normalizedKey.isEmpty || !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !field.isValidKey {
                issues.append(MetadataIssue(id: "custom-\(field.id)", field: .custom(field.id), message: "“\(field.normalizedKey)” is not a valid field name."))
            } else if field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(MetadataIssue(id: "custom-value-\(field.id)", field: .custom(field.id), message: "Add a value for “\(field.normalizedKey)”."))
            }
        }
        return issues
    }

    var isReadyToUpload: Bool {
        issues.isEmpty
    }

    mutating func addSubjects(from text: String) {
        let incoming = Self.splitList(text)
        for subject in incoming where !subjects.contains(subject) {
            if subjects.count >= 10 { break }
            subjects.append(subject)
        }
    }

    static func splitList(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = value.lowercased()
            if seen.insert(key).inserted {
                result.append(value)
            }
        }
        return result
    }

    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

enum MetadataIssueField: Equatable {
    case title
    case identifier
    case description
    case subjects
    case custom(UUID)
}

struct MetadataIssue: Identifiable, Equatable {
    let id: String
    let field: MetadataIssueField
    let message: String
}
