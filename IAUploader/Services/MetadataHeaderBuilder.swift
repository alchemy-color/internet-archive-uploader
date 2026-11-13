import Foundation

/// Builds `x-archive-metaNN-*` headers exactly the way IAS3 expects them.
///
/// Rules (mirroring the Internet Archive Python library):
/// - Values are numbered per key, starting at `00`.
/// - Underscores in field names are written as double dashes.
/// - Values containing whitespace or non-ASCII characters are URI-encoded
///   and wrapped in `uri(...)`.
enum MetadataHeaderBuilder {
    static func headers(for metadata: ItemMetadata) -> [(String, String)] {
        orderedFields(for: metadata).flatMap { key, values -> [(String, String)] in
            values.enumerated().map { index, value in
                let header = "x-archive-meta\(String(format: "%02d", index))-\(escapeKey(key))"
                return (header, encodeValue(value))
            }
        }
    }

    static func orderedFields(for metadata: ItemMetadata) -> [(String, [String])] {
        var order: [String] = []
        var valuesByKey: [String: [String]] = [:]

        func add(_ key: String, _ values: [String]) {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { return }
            let values = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !values.isEmpty else { return }
            let identity = trimmedKey.lowercased()
            if valuesByKey[identity] == nil {
                order.append(identity)
                valuesByKey[identity] = []
            }
            for value in values where !(valuesByKey[identity]?.contains(value) ?? false) {
                valuesByKey[identity]?.append(value)
            }
        }

        add("title", [metadata.title])
        add("creator", [metadata.creator])
        add("description", [metadata.descriptionText])
        add("date", [metadata.date])
        add("subject", Array(metadata.parsedSubjects.prefix(10)))
        add("collection", metadata.effectiveCollections)
        add("language", [metadata.language])
        add("licenseurl", [metadata.licenseURL])
        add("mediatype", [metadata.mediatype.rawValue])
        for field in metadata.customFields {
            add(field.normalizedKey, [field.value])
        }

        var result: [(String, [String])] = []
        for identity in order {
            guard let values = valuesByKey[identity], !values.isEmpty else { continue }
            // Preserve the first spelling the user provided for this key.
            let original = firstSpelling(for: identity, metadata: metadata)
            result.append((original, values))
        }
        return result
    }

    static func escapeKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: "--")
    }

    static func encodeValue(_ value: String) -> String {
        guard needsQuoting(value) else { return value }
        return "uri(\(RemotePath.percentEncode(value)))"
    }

    static func needsQuoting(_ value: String) -> Bool {
        if value.unicodeScalars.contains(where: { !$0.isASCII }) { return true }
        return value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func firstSpelling(for identity: String, metadata: ItemMetadata) -> String {
        let standardKeys = ["title", "creator", "description", "date", "subject", "collection", "language", "licenseurl", "mediatype"]
        if let match = standardKeys.first(where: { $0 == identity }) { return match }
        if let match = metadata.customFields.first(where: { $0.normalizedKey.lowercased() == identity }) {
            return match.normalizedKey
        }
        return identity
    }
}
