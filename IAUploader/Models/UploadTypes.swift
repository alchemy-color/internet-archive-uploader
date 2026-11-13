import Foundation

struct UploadOptions: Sendable, Equatable {
    var concurrency: Int = 3
    var maxRetries: Int = 4
    var queueDerive: Bool = true
    var interactivePriority: Bool = true
    var keepOldVersions: Bool = false
    var userAgent: String = "InternetArchiveUploader/1.1 (macOS)"

    static let `default` = UploadOptions()
}

struct PlannedFile: Identifiable, Sendable, Equatable {
    let id: UUID
    let localURL: URL
    let remotePath: String
    let byteSize: Int64
    let contentType: String?
}

struct UploadPlan: Sendable {
    let identifier: String
    let metadataHeaders: [(String, String)]
    let files: [PlannedFile]
    let options: UploadOptions

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.byteSize }
    }
}

/// Builds the exact remote paths a selection will have inside an item.
enum UploadPlanBuilder {
    static func build(
        identifier: String,
        metadata: ItemMetadata,
        files: [PickedFile],
        sanitizeNames: Bool,
        destinationFolder: String = "",
        options: UploadOptions
    ) -> UploadPlan {
        let normalizedFolder = normalizedFolder(destinationFolder, sanitize: sanitizeNames)
        var usedKeys = Set<String>()
        let planned = files.map { file -> PlannedFile in
            let path = RemotePath.deduplicated(
                RemotePath.join(normalizedFolder, file.remotePath(sanitize: sanitizeNames)),
                used: &usedKeys
            )
            return PlannedFile(
                id: file.id,
                localURL: file.url,
                remotePath: path,
                byteSize: file.byteSize,
                contentType: file.contentType
            )
        }
        return UploadPlan(
            identifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines),
            metadataHeaders: MetadataHeaderBuilder.headers(for: metadata),
            files: planned,
            options: options
        )
    }

    /// Cleans a user-typed folder such as " /Season 1//Extras/ " into
    /// "Season_1/Extras" (or "Season 1/Extras" when not sanitizing).
    static func normalizedFolder(_ folder: String, sanitize: Bool) -> String {
        let parts = folder
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard !parts.isEmpty else { return "" }
        let joined = parts.joined(separator: "/")
        return sanitize ? RemotePath.sanitized(joined) : joined
    }
}

// MARK: - Queue

enum JobStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case uploading
    case paused
    case done
    case failed
    case cancelled

    var isActive: Bool { self == .queued || self == .uploading }
    var isFinished: Bool { self == .done }
    var isUnfinished: Bool { self != .done }

    var title: String {
        switch self {
        case .queued: return "Waiting"
        case .uploading: return "Uploading"
        case .paused: return "Paused"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        }
    }
}

struct HeaderPair: Codable, Sendable, Equatable, Hashable {
    var name: String
    var value: String
}

/// One file waiting to go (or already gone) to archive.org.
struct UploadJob: Identifiable, Codable, Sendable, Equatable {
    var id: UUID = UUID()
    var batchID: UUID
    var identifier: String
    var localPath: String
    var remotePath: String
    var byteSize: Int64
    var contentType: String?
    /// Only set on the job that creates a brand-new item. Other jobs of the
    /// same batch wait until it succeeds so the bucket exists before they
    /// start (parallel first PUTs to a new identifier race on archive.org).
    var createsItem: Bool = false
    var metadataHeaders: [HeaderPair] = []
    var replacesExisting: Bool = false
    var status: JobStatus = .queued
    var sent: Int64 = 0
    var attempts: Int = 0
    var error: String?
    var addedAt: Date = Date()
    var startedAt: Date?
    var finishedAt: Date?

    var localURL: URL { URL(fileURLWithPath: localPath) }
    var fileName: String { (remotePath as NSString).lastPathComponent }

    var fraction: Double {
        guard byteSize > 0 else { return status == .done ? 1 : 0 }
        return min(max(Double(sent) / Double(byteSize), 0), 1)
    }
}

/// A group of jobs added together (one "Add to queue" action).
struct UploadBatch: Identifiable, Codable, Sendable, Equatable {
    var id: UUID = UUID()
    var identifier: String
    var title: String
    var createdAt: Date = Date()
    var isNewItem: Bool
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        var chunks: [[Element]] = []
        chunks.reserveCapacity((count + size - 1) / size)
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            chunks.append(Array(self[index..<end]))
            index = end
        }
        return chunks
    }
}
