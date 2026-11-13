import Foundation
import UniformTypeIdentifiers

/// A local file queued for upload, together with the path it should have
/// inside the archive.org item.
struct PickedFile: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let url: URL
    /// Name of the dropped folder this file came from, if any.
    var rootName: String?
    /// Path inside the item, before sanitizing and before the destination
    /// folder is prepended. Editable: renaming or moving a file or folder in
    /// the Files step rewrites this.
    var rawRelativePath: String
    let byteSize: Int64
    let contentType: String?

    init(
        id: UUID = UUID(),
        url: URL,
        rootName: String?,
        rawRelativePath: String,
        byteSize: Int64,
        contentType: String? = nil
    ) {
        self.id = id
        self.url = url
        self.rootName = rootName
        self.rawRelativePath = rawRelativePath
        self.byteSize = byteSize
        self.contentType = contentType ?? Self.mimeType(for: url)
    }

    var displayName: String {
        (rawRelativePath as NSString).lastPathComponent
    }

    var directory: String? {
        let directory = (rawRelativePath as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }

    var fileExtension: String {
        url.pathExtension
    }

    func remotePath(sanitize: Bool) -> String {
        sanitize ? RemotePath.sanitized(rawRelativePath) : rawRelativePath
    }

    static func mimeType(for url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        return type.preferredMIMEType
    }
}

/// Turns local paths into safe archive.org object keys and encodes them for
/// use in a URL path.
enum RemotePath {
    static func sanitized(_ path: String) -> String {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitizedComponent(String($0)) }
            .filter { !$0.isEmpty }
        return components.isEmpty ? "file" : components.joined(separator: "/")
    }

    static func sanitizedComponent(_ name: String) -> String {
        let folded = name.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var result = ""
        for character in folded {
            if character.isLetter || character.isNumber {
                result.append(character)
            } else if character == "." || character == "-" || character == "_" {
                result.append(character)
            } else if character.isWhitespace {
                result.append("_")
            } else {
                result.append("_")
            }
        }
        while result.contains("__") {
            result = result.replacingOccurrences(of: "__", with: "_")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        if result.isEmpty || result == "." || result == ".." {
            result = "file"
        }
        if result.count > 200 {
            let nsName = result as NSString
            let ext = nsName.pathExtension
            let base = nsName.deletingPathExtension
            let maxBaseLength = max(1, 200 - ext.count - 1)
            let truncated = String(base.prefix(maxBaseLength))
            result = ext.isEmpty ? truncated : "\(truncated).\(ext)"
        }
        return result
    }

    /// Percent-encodes each path segment while keeping the slashes between
    /// segments. This matches how the Internet Archive Python library builds
    /// IAS3 object URLs.
    static func encoded(_ path: String) -> String {
        path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { percentEncode(String($0)) }
            .joined(separator: "/")
    }

    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Joins path pieces, ignoring empty ones and stray slashes.
    static func join(_ parts: String...) -> String {
        parts
            .flatMap { $0.split(separator: "/", omittingEmptySubsequences: true) }
            .map(String.init)
            .joined(separator: "/")
    }

    /// "a/b/c.txt" -> "a/b"; "c.txt" -> "".
    static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "/" ? "" : parent
    }

    /// True when `path` is `folder` itself or lies anywhere inside it.
    static func isInside(_ path: String, folder: String) -> Bool {
        guard !folder.isEmpty else { return true }
        return path == folder || path.hasPrefix(folder + "/")
    }

    /// Replaces the `oldPrefix` folder of `path` with `newPrefix`.
    static func reparent(_ path: String, from oldPrefix: String, to newPrefix: String) -> String {
        guard isInside(path, folder: oldPrefix) else { return path }
        let rest = oldPrefix.isEmpty ? path : String(path.dropFirst(oldPrefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return join(newPrefix, rest)
    }

    /// Appends a numeric suffix when two local files would map to the same key.
    static func deduplicated(_ path: String, used: inout Set<String>) -> String {
        if used.insert(path).inserted { return path }
        let nsPath = path as NSString
        let ext = nsPath.pathExtension
        let base = nsPath.deletingPathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            if used.insert(candidate).inserted { return candidate }
            counter += 1
        }
    }
}
