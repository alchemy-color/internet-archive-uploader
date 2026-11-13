import Foundation
import Observation

/// User defaults-backed preferences.
@MainActor
@Observable
final class AppSettings {
    private struct Snapshot: Codable {
        var defaultMediatype: Mediatype = .texts
        var sanitizeFileNames: Bool = true
        var includeHiddenFiles: Bool = false
        var concurrency: Int = 3
        var maxRetries: Int = 4
        var queueDerive: Bool = true
        var interactivePriority: Bool = true
        var keepOldVersions: Bool = false
        var rememberEmail: Bool = true
        var keepTopFolder: Bool? = true
        var existingFilePolicy: ExistingFilePolicy? = .replace
        var verifyChecksums: Bool? = true
        var confirmQuitWhenIdle: Bool? = true
    }

    private static let storageKey = "IAUploader.settings.v1"
    private let defaults: UserDefaults
    private var isApplyingSnapshot = false

    var defaultMediatype: Mediatype { didSet { persist() } }
    var sanitizeFileNames: Bool { didSet { persist() } }
    var includeHiddenFiles: Bool { didSet { persist() } }
    var concurrency: Int { didSet { persist() } }
    var maxRetries: Int { didSet { persist() } }
    var queueDerive: Bool { didSet { persist() } }
    var interactivePriority: Bool { didSet { persist() } }
    var keepOldVersions: Bool { didSet { persist() } }
    var rememberEmail: Bool { didSet { persist() } }
    /// Keep the dropped folder's own name as the top folder in the item.
    var keepTopFolder: Bool { didSet { persist() } }
    /// What to do when a different file already exists at the same path.
    var existingFilePolicy: ExistingFilePolicy { didSet { persist() } }
    /// Compare MD5 checksums (not just size) before treating a file as identical.
    var verifyChecksums: Bool { didSet { persist() } }
    /// Ask before quitting even when nothing is uploading.
    var confirmQuitWhenIdle: Bool { didSet { persist() } }

    init(defaults: UserDefaults = AppPaths.defaults) {
        self.defaults = defaults
        let snapshot = Self.load(from: defaults)
        defaultMediatype = snapshot.defaultMediatype
        sanitizeFileNames = snapshot.sanitizeFileNames
        includeHiddenFiles = snapshot.includeHiddenFiles
        concurrency = snapshot.concurrency
        maxRetries = snapshot.maxRetries
        queueDerive = snapshot.queueDerive
        interactivePriority = snapshot.interactivePriority
        keepOldVersions = snapshot.keepOldVersions
        rememberEmail = snapshot.rememberEmail
        keepTopFolder = snapshot.keepTopFolder ?? true
        existingFilePolicy = snapshot.existingFilePolicy ?? .replace
        verifyChecksums = snapshot.verifyChecksums ?? true
        confirmQuitWhenIdle = snapshot.confirmQuitWhenIdle ?? true
    }

    var uploadOptions: UploadOptions {
        UploadOptions(
            concurrency: min(max(concurrency, 1), 8),
            maxRetries: min(max(maxRetries, 0), 10),
            queueDerive: queueDerive,
            interactivePriority: interactivePriority,
            keepOldVersions: keepOldVersions
        )
    }

    func resetToDefaults() {
        isApplyingSnapshot = true
        defaultMediatype = .texts
        sanitizeFileNames = true
        includeHiddenFiles = false
        concurrency = 3
        maxRetries = 4
        queueDerive = true
        interactivePriority = true
        keepOldVersions = false
        rememberEmail = true
        keepTopFolder = true
        existingFilePolicy = .replace
        verifyChecksums = true
        confirmQuitWhenIdle = true
        isApplyingSnapshot = false
        persist()
    }

    private func persist() {
        guard !isApplyingSnapshot else { return }
        let snapshot = Snapshot(
            defaultMediatype: defaultMediatype,
            sanitizeFileNames: sanitizeFileNames,
            includeHiddenFiles: includeHiddenFiles,
            concurrency: concurrency,
            maxRetries: maxRetries,
            queueDerive: queueDerive,
            interactivePriority: interactivePriority,
            keepOldVersions: keepOldVersions,
            rememberEmail: rememberEmail,
            keepTopFolder: keepTopFolder,
            existingFilePolicy: existingFilePolicy,
            verifyChecksums: verifyChecksums,
            confirmQuitWhenIdle: confirmQuitWhenIdle
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> Snapshot {
        guard let data = defaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot()
        }
        return snapshot
    }
}
