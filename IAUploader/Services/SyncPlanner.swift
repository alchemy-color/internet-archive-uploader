import Foundation
import CryptoKit

/// What to do when a file is going to a path that already holds a
/// *different* file in the item. Identical files (same path, same size and,
/// when checked, the same MD5) are always skipped.
enum ExistingFilePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case replace
    case skip
    case keepBoth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replace: return "Replace it"
        case .skip: return "Skip the file"
        case .keepBoth: return "Keep both (rename the new one)"
        }
    }
}

extension RemoteFile {
    /// archive.org adds its own files to every item (metadata XML, thumbnails,
    /// torrents, derivatives). Those are never user content.
    var isSystemFile: Bool {
        if let source, source != "original" { return true }
        let lower = name.lowercased()
        let systemSuffixes = ["_meta.xml", "_files.xml", "_meta.sqlite", "_archive.torrent", "_reviews.xml", "__ia_thumb.jpg"]
        if systemSuffixes.contains(where: { lower.hasSuffix($0) }) { return true }
        if lower.hasPrefix("history/") { return true }
        return false
    }

    var isOriginal: Bool { !isSystemFile }
}

/// Pure, testable comparison logic shared by the Upload step, the Manage
/// folder sync, and the queue.
enum SyncPlanner {
    enum Decision: Equatable, Sendable {
        case upload                      // nothing at that path
        case skipIdentical               // identical file already there
        case replace                     // different file at that path, replace it
        case skipDifferent               // different file at that path, policy says skip
        case rename(String)              // different file, upload under a new name
        case alreadyQueued               // same path is already waiting in the queue
    }

    struct Candidate: Sendable, Equatable {
        var remotePath: String
        var byteSize: Int64
        var localMD5: String?
    }

    /// Decides what to do with each candidate. Matching is by exact path
    /// (archive.org paths are case-sensitive) — never by bare file name, so
    /// `A/cover.jpg` never collides with `B/cover.jpg`.
    static func decide(
        _ candidates: [Candidate],
        remote: [RemoteFile],
        queuedPaths: Set<String> = [],
        policy: ExistingFilePolicy
    ) -> [Decision] {
        let byPath = Dictionary(remote.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var taken = Set(remote.map(\.name)).union(queuedPaths)
        return candidates.map { candidate in
            if queuedPaths.contains(candidate.remotePath) {
                return .alreadyQueued
            }
            guard let existing = byPath[candidate.remotePath] else {
                taken.insert(candidate.remotePath)
                return .upload
            }
            if isIdentical(candidate, existing) {
                return .skipIdentical
            }
            switch policy {
            case .replace: return .replace
            case .skip: return .skipDifferent
            case .keepBoth:
                let renamed = RemotePath.deduplicated(candidate.remotePath, used: &taken)
                return .rename(renamed)
            }
        }
    }

    static func isIdentical(_ candidate: Candidate, _ remote: RemoteFile) -> Bool {
        guard let remoteSize = remote.size else {
            // Size unknown on the server (still processing). Fall back to MD5.
            if let local = candidate.localMD5, let md5 = remote.md5 { return local.lowercased() == md5.lowercased() }
            return false
        }
        guard remoteSize == candidate.byteSize else { return false }
        if let local = candidate.localMD5, let md5 = remote.md5 {
            return local.lowercased() == md5.lowercased()
        }
        return true
    }

    // MARK: Folder diff

    enum DiffStatus: String, Sendable, CaseIterable {
        case new, changed, identical, remoteOnly

        var title: String {
            switch self {
            case .new: return "New"
            case .changed: return "Changed"
            case .identical: return "Up to date"
            case .remoteOnly: return "Only on archive.org"
            }
        }
    }

    struct DiffEntry: Identifiable, Sendable, Equatable {
        var id: String { remotePath }
        let remotePath: String
        let status: DiffStatus
        let localURL: URL?
        let localSize: Int64?
        let remoteSize: Int64?
    }

    struct LocalEntry: Sendable, Equatable {
        let url: URL
        /// Path relative to the chosen local folder (no folder name).
        let relativePath: String
        let byteSize: Int64
        var md5: String?
    }

    /// Compares a local folder with a folder inside the item.
    /// `remoteFolder` is "" for the item root.
    static func diff(
        local: [LocalEntry],
        remote: [RemoteFile],
        remoteFolder: String,
        sanitize: Bool
    ) -> [DiffEntry] {
        let folder = UploadPlanBuilder.normalizedFolder(remoteFolder, sanitize: false)
        let remoteInFolder = remote.filter { $0.isOriginal && RemotePath.isInside($0.name, folder: folder) && $0.name != folder }
        let byPath = Dictionary(remoteInFolder.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var entries: [DiffEntry] = []
        for item in local {
            let relative = sanitize ? RemotePath.sanitized(item.relativePath) : item.relativePath
            let path = RemotePath.join(folder, relative)
            guard seen.insert(path).inserted else { continue }
            if let remoteFile = byPath[path] {
                let candidate = Candidate(remotePath: path, byteSize: item.byteSize, localMD5: item.md5)
                entries.append(DiffEntry(
                    remotePath: path,
                    status: isIdentical(candidate, remoteFile) ? .identical : .changed,
                    localURL: item.url,
                    localSize: item.byteSize,
                    remoteSize: remoteFile.size
                ))
            } else {
                entries.append(DiffEntry(remotePath: path, status: .new, localURL: item.url, localSize: item.byteSize, remoteSize: nil))
            }
        }
        for remoteFile in remoteInFolder where !seen.contains(remoteFile.name) {
            entries.append(DiffEntry(remotePath: remoteFile.name, status: .remoteOnly, localURL: nil, localSize: nil, remoteSize: remoteFile.size))
        }
        return entries.sorted { $0.remotePath.localizedStandardCompare($1.remotePath) == .orderedAscending }
    }

    // MARK: Checksums

    /// Streams the file through MD5 (archive.org's checksum) in 4 MB chunks.
    static func md5(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Remembers changes this app made to an item recently, because archive.org's
/// metadata API lags behind IAS3 by seconds to hours. Without this, a file
/// uploaded a minute ago looks "missing" and gets uploaded again, and a file
/// just deleted or moved still shows at its old path.
struct RemoteOverlay: Codable, Sendable {
    enum Change: Codable, Sendable, Equatable {
        case added(size: Int64, md5: String?)
        case removed
    }

    struct Entry: Codable, Sendable, Equatable {
        var change: Change
        var date: Date
    }

    /// identifier -> path -> latest change
    private(set) var entries: [String: [String: Entry]] = [:]
    static let lifetime: TimeInterval = 6 * 60 * 60

    mutating func recordAdded(identifier: String, path: String, size: Int64, md5: String? = nil) {
        entries[identifier, default: [:]][path] = Entry(change: .added(size: size, md5: md5), date: Date())
    }

    mutating func recordRemoved(identifier: String, path: String) {
        entries[identifier, default: [:]][path] = Entry(change: .removed, date: Date())
    }

    /// Applies recent local changes on top of what the server reported, and
    /// forgets changes the server already reflects (or that expired).
    mutating func merge(identifier: String, server: [RemoteFile], now: Date = Date()) -> (files: [RemoteFile], pending: Set<String>) {
        guard var changes = entries[identifier], !changes.isEmpty else { return (server, []) }
        var byPath = Dictionary(server.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var pending = Set<String>()
        for (path, entry) in changes {
            if now.timeIntervalSince(entry.date) > Self.lifetime {
                changes[path] = nil
                continue
            }
            switch entry.change {
            case .added(let size, let md5):
                if let existing = byPath[path], existing.size == size {
                    changes[path] = nil           // server caught up
                } else {
                    byPath[path] = RemoteFile(name: path, size: size, md5: md5, source: "original")
                    pending.insert(path)
                }
            case .removed:
                if byPath[path] == nil {
                    changes[path] = nil           // server caught up
                } else {
                    byPath[path] = nil
                    pending.insert(path)
                }
            }
        }
        entries[identifier] = changes.isEmpty ? nil : changes
        let files = byPath.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (files, pending)
    }
}

// MARK: - Folder sync (Finder is the reference)

/// A Finder folder linked to a folder inside an item, like a git checkout.
struct LinkedFolder: Codable, Sendable, Equatable {
    var localPath: String
    /// Folder inside the item that mirrors the local folder ("" = item root).
    var remoteFolder: String
    var linkedAt: Date = Date()

    var localURL: URL { URL(fileURLWithPath: localPath) }
    var displayPath: String { (localPath as NSString).abbreviatingWithTildeInPath }
}

/// What it takes to make the item match the Finder folder.
struct SyncPlan: Sendable, Equatable {
    struct Upload: Sendable, Equatable, Identifiable {
        var id: String { remotePath }
        let localURL: URL
        let remotePath: String
        let byteSize: Int64
        let replaces: Bool          // a different file is at that path now
    }
    struct Move: Sendable, Equatable, Identifiable {
        var id: String { to }
        let from: String
        let to: String
        let byteSize: Int64
    }
    struct Removal: Sendable, Equatable, Identifiable {
        var id: String { remotePath }
        let remotePath: String
        let byteSize: Int64
    }

    var uploads: [Upload] = []       // new in Finder
    var updates: [Upload] = []       // changed in Finder
    var moves: [Move] = []           // moved/renamed in Finder → move on server
    var removals: [Removal] = []     // not in Finder any more
    var unchanged: Int = 0
    var emptyLocalFolders: [String] = []
    var checkedAt = Date()

    var changeCount: Int { uploads.count + updates.count + moves.count + removals.count }
    var isInSync: Bool { changeCount == 0 }
    var uploadBytes: Int64 { (uploads + updates).reduce(0) { $0 + $1.byteSize } }
}

extension SyncPlanner {
    /// Compares a Finder folder with a folder inside the item and works out
    /// the uploads, server-side moves, and removals that make the item match
    /// Finder. Moves are detected by MD5 (or name + size when the server has
    /// no checksum yet), so reorganising folders in Finder never re-uploads.
    ///
    /// `localMD5` is called lazily, only for files where a checksum decides
    /// the outcome.
    static func plan(
        local: [LocalEntry],
        remote: [RemoteFile],
        remoteFolder: String,
        sanitize: Bool,
        deepCompare: Bool,
        localMD5: (LocalEntry) -> String?
    ) -> SyncPlan {
        let folder = RemotePath.join(remoteFolder)
        let remoteInFolder = remote.filter { $0.isOriginal && RemotePath.isInside($0.name, folder: folder) && $0.name != folder }
        var remoteByPath = Dictionary(remoteInFolder.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var plan = SyncPlan()
        var unmatchedLocal: [(entry: LocalEntry, path: String)] = []
        var seen = Set<String>()

        // 1. Same path on both sides: unchanged or modified.
        for entry in local {
            let relative = sanitize ? RemotePath.sanitized(entry.relativePath) : entry.relativePath
            let path = RemotePath.join(folder, relative)
            guard seen.insert(path).inserted else { continue }
            guard let existing = remoteByPath.removeValue(forKey: path) else {
                unmatchedLocal.append((entry, path))
                continue
            }
            var same = existing.size == nil || existing.size == entry.byteSize
            if same, deepCompare, let remoteMD5 = existing.md5, let md5 = localMD5(entry) {
                same = md5.lowercased() == remoteMD5.lowercased()
            }
            if same {
                plan.unchanged += 1
            } else {
                plan.updates.append(.init(localURL: entry.url, remotePath: path, byteSize: entry.byteSize, replaces: true))
            }
        }

        // 2. Moves: a remote file that disappeared from its path whose content
        //    shows up at a new local path.
        var leftovers = Array(remoteByPath.values).sorted { $0.name < $1.name }
        for (entry, path) in unmatchedLocal {
            let sameSize = leftovers.indices.filter { leftovers[$0].size == entry.byteSize }
            var match: Int?
            if !sameSize.isEmpty {
                if sameSize.contains(where: { leftovers[$0].md5 != nil }), let md5 = localMD5(entry)?.lowercased() {
                    match = sameSize.first { leftovers[$0].md5?.lowercased() == md5 }
                }
                if match == nil {
                    let name = (path as NSString).lastPathComponent
                    match = sameSize.first { leftovers[$0].md5 == nil && (leftovers[$0].name as NSString).lastPathComponent == name }
                }
            }
            if let index = match {
                let source = leftovers.remove(at: index)
                plan.moves.append(.init(from: source.name, to: path, byteSize: entry.byteSize))
            } else {
                plan.uploads.append(.init(localURL: entry.url, remotePath: path, byteSize: entry.byteSize, replaces: false))
            }
        }

        // 3. Whatever is left on the server is not in Finder any more.
        plan.removals = leftovers.map { .init(remotePath: $0.name, byteSize: $0.size ?? 0) }
        plan.uploads.sort { $0.remotePath.localizedStandardCompare($1.remotePath) == .orderedAscending }
        plan.updates.sort { $0.remotePath.localizedStandardCompare($1.remotePath) == .orderedAscending }
        plan.moves.sort { $0.to.localizedStandardCompare($1.to) == .orderedAscending }
        plan.removals.sort { $0.remotePath.localizedStandardCompare($1.remotePath) == .orderedAscending }
        return plan
    }

    /// Lists a Finder folder as sync entries (paths relative to the folder),
    /// plus its empty subfolders.
    static func scanLocal(_ folder: URL, includeHidden: Bool) -> (files: [LocalEntry], emptyFolders: [String]) {
        let scan = FileScanner.scan(urls: [folder], includeHidden: includeHidden)
        let files = scan.files.map { file -> LocalEntry in
            let relative = file.rootName.map { root in
                file.relativePath.hasPrefix(root + "/") ? String(file.relativePath.dropFirst(root.count + 1)) : file.relativePath
            } ?? file.relativePath
            return LocalEntry(url: file.url, relativePath: relative, byteSize: file.byteSize, md5: nil)
        }
        var empty: [String] = []
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: options) {
            for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                if contents.filter({ includeHidden || !$0.hasPrefix(".") }).isEmpty {
                    let relative = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if !relative.isEmpty { empty.append(relative) }
                }
            }
        }
        return (files, empty)
    }
}

/// Remembers local MD5s by path + size + modification date so re-checking a
/// big folder is instant after the first time.
final class MD5Cache: @unchecked Sendable {
    static let shared = MD5Cache()

    private struct Entry: Codable { var size: Int64; var modified: Double; var md5: String }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var dirty = false
    private let fileURL = AppPaths.file("md5cache.json")

    init() {
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func md5(for url: URL, size: Int64) -> String? {
        let modified = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast).timeIntervalSince1970
        lock.lock()
        if let entry = entries[url.path], entry.size == size, entry.modified == modified {
            lock.unlock()
            return entry.md5
        }
        lock.unlock()
        guard let digest = SyncPlanner.md5(of: url) else { return nil }
        lock.lock()
        entries[url.path] = Entry(size: size, modified: modified, md5: digest)
        dirty = true
        lock.unlock()
        return digest
    }

    func save() {
        lock.lock()
        guard dirty, let data = try? JSONEncoder().encode(entries) else { lock.unlock(); return }
        dirty = false
        lock.unlock()
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
