import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    // MARK: Types

    /// Where the main window is: creating a new item, or working on one.
    enum Route: Equatable, Hashable {
        case newItem
        case item(String)

        var identifier: String? {
            if case .item(let id) = self { return id }
            return nil
        }

        var storageValue: String {
            switch self {
            case .newItem: return "new"
            case .item(let id): return "item:" + id
            }
        }

        init?(storageValue: String) {
            if storageValue == "new" { self = .newItem }
            else if storageValue.hasPrefix("item:") { self = .item(String(storageValue.dropFirst(5))) }
            else { return nil }
        }
    }

    enum AccountState: Equatable {
        case signedOut
        case signingIn
        case signedIn
    }

    enum IdentifierCheck: Equatable {
        case idle
        case checking
        case available
        case taken
        case invalid(String)
        case failed(String)
    }

    struct Banner: Identifiable, Equatable {
        enum Kind: Equatable { case info, warning, error, success }
        let id = UUID()
        let kind: Kind
        let message: String
    }

    /// The outcome of turning a selection into queue jobs.
    struct EnqueueReport: Equatable {
        var identifier = ""
        var queued = 0
        var queuedBytes: Int64 = 0
        var skippedIdentical: [String] = []
        var skippedDifferent: [String] = []
        var replaced: [String] = []
        var renamed: [String] = []
        var alreadyQueued: [String] = []
        /// Identical content already elsewhere in the item: (local target, existing path).
        var existsElsewhere: [(target: String, existing: String)] = []

        static func == (a: EnqueueReport, b: EnqueueReport) -> Bool {
            a.identifier == b.identifier && a.queued == b.queued && a.queuedBytes == b.queuedBytes && a.skippedIdentical == b.skippedIdentical
                && a.replaced == b.replaced && a.error == b.error && a.existsElsewhere.map(\.target) == b.existsElsewhere.map(\.target)
        }
        var error: String?

        var summary: String {
            if let error { return error }
            var parts = ["Queued \(queued) file\(queued == 1 ? "" : "s") (\(ByteCountFormatter.shortString(queuedBytes)))"]
            if !skippedIdentical.isEmpty { parts.append("\(skippedIdentical.count) already on archive.org (identical, skipped)") }
            if !replaced.isEmpty { parts.append("\(replaced.count) will replace a different file") }
            if !renamed.isEmpty { parts.append("\(renamed.count) renamed to keep both") }
            if !skippedDifferent.isEmpty { parts.append("\(skippedDifferent.count) skipped (a different file exists)") }
            if !alreadyQueued.isEmpty { parts.append("\(alreadyQueued.count) already in the queue") }
            if !existsElsewhere.isEmpty { parts.append("\(existsElsewhere.count) skipped: already in the item in another folder (link the folder and Sync to move them instead of uploading again)") }
            return parts.joined(separator: " · ")
        }
    }

    /// A long server-side operation (move, delete, download) in Manage.
    struct ServerOperation: Equatable {
        var title: String
        var done: Int
        var total: Int
        var detail: String?
    }

    // MARK: Navigation and account

    var route: Route = .newItem
    var showActivityLog = false
    var settings = AppSettings()
    var history = UploadHistory()
    let queue: UploadQueue

    var credentials: ArchiveCredentials?
    var accountState: AccountState = .signedOut
    var loginError: String?

    // MARK: Files step

    var files: [PickedFile] = []
    /// Tree node IDs (see `TreeNode`): "f:<uuid>" for files, "d:<path>" for folders.
    var fileSelection = Set<String>()
    /// Empty folders created in the Files step (paths inside the item).
    var planFolders = Set<String>()
    var isScanning = false

    // MARK: Metadata / upload

    var metadata = ItemMetadata()
    var identifierAuto = true
    var identifierCheck: IdentifierCheck = .idle
    var uploadDestinationFolder: String = ""
    /// Folders dropped into the new item, by top-folder name, so the item can
    /// be linked to that Finder folder after upload.
    var sourceRoots: [String: URL] = [:]
    var existingFiles: [RemoteFile] = []
    var isLoadingExistingFiles = false
    var isPreparingUpload = false
    var lastEnqueueReport: EnqueueReport?
    var banner: Banner?
    var showSettings = false

    private var mediatypeTouched = false
    private var collectionTouched = false

    // MARK: Manage state

    var managedIdentifier: String = ""
    var managedMetadata = ItemMetadata()
    var managedOriginalMetadata = ItemMetadata()
    /// Server files merged with this app's recent changes.
    var managedFiles: [RemoteFile] = []
    /// Paths whose state on archive.org is still catching up.
    var managedPending = Set<String>()
    var manageSelection = Set<String>()
    var showDerivedFiles = false
    var isLoadingManagedItem = false
    var managedItemError: String?
    var serverOperation: ServerOperation?
    var managedVirtualFolders: [String: Set<String>] = [:]
    var isSavingMetadata = false

    var myUploads: [RemoteItem] = []
    var isLoadingMyUploads = false

    // Folder sync (Manage)
    /// Finder folders linked to items (identifier → link). Finder is the reference.
    var linkedFolders: [String: LinkedFolder] = [:]
    var syncPlan: SyncPlan?
    var isCheckingSync = false
    var isApplyingSync = false
    var syncMessage: String?
    var showOnlyChanges = false

    var overlay = RemoteOverlay()

    var undoManager: UndoManager?
    private let lastEmailKey = "IAUploader.lastEmail"
    let archiveClient: ArchiveClient

    // MARK: Init

    init(archiveClient: ArchiveClient = .shared, queue: UploadQueue? = nil) {
        self.archiveClient = archiveClient
        self.queue = queue ?? UploadQueue()
        metadata.mediatype = settings.defaultMediatype
        metadata.collections = settings.defaultMediatype.defaultCollection
        restoreSession()
        restoreState()
        configureQueue()
    }

    private func configureQueue() {
        queue.credentials = credentials
        queue.concurrency = settings.concurrency
        queue.maxRetries = settings.maxRetries
        queue.optionsProvider = { [weak self] in self?.settings.uploadOptions ?? .default }
        queue.onJobSucceeded = { [weak self] job in
            self?.jobSucceeded(job)
        }
    }

    /// Call when concurrency/retry settings change.
    func applyQueueSettings() {
        queue.concurrency = settings.concurrency
        queue.maxRetries = settings.maxRetries
    }

    // MARK: State persistence

    func saveState() {
        let snapshot = AppStateSnapshot(
            step: route.storageValue,
            files: [],
            includeHiddenFiles: settings.includeHiddenFiles,
            metadata: metadata,
            identifierAuto: identifierAuto,
            mediatypeTouched: mediatypeTouched,
            collectionTouched: collectionTouched,
            allowExistingIdentifier: false,
            skipExistingFiles: true,
            uploadDestinationFolder: uploadDestinationFolder,
            managedIdentifier: managedIdentifier,
            managedMetadata: managedMetadata,
            pickedFiles: files,
            planFolders: Array(planFolders),
            overlay: overlay,
            managedVirtualFolders: managedVirtualFolders.mapValues { Array($0) },
            uploadMode: nil,
            linkedFolders: linkedFolders
        )
        StateStore.save(snapshot)
        queue.saveNow()
        ViewMemory.shared.flush()
    }

    private func restoreState() {
        guard let snapshot = StateStore.load() else { return }
        if let raw = snapshot.step, let route = Route(storageValue: raw) {
            self.route = route
        } else if !snapshot.managedIdentifier.isEmpty, ["manage", "existingUpload", "queue"].contains(snapshot.step ?? "") {
            self.route = .item(snapshot.managedIdentifier)
        }
        if let links = snapshot.linkedFolders { linkedFolders = links }
        identifierAuto = snapshot.identifierAuto
        mediatypeTouched = snapshot.mediatypeTouched
        collectionTouched = snapshot.collectionTouched
        uploadDestinationFolder = snapshot.uploadDestinationFolder
        managedIdentifier = snapshot.managedIdentifier
        if let mm = snapshot.managedMetadata { managedMetadata = mm; managedOriginalMetadata = mm }
        if let m = snapshot.metadata { metadata = m }
        if let overlay = snapshot.overlay { self.overlay = overlay }
        if let virtual = snapshot.managedVirtualFolders { managedVirtualFolders = virtual.mapValues(Set.init) }
        planFolders = Set(snapshot.planFolders ?? [])
        // Restore the exact file records (path inside the item included).
        // Re-scanning bare file URLs here used to flatten folders.
        if let picked = snapshot.pickedFiles {
            files = picked.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
    }

    // MARK: Account

    var lastEmail: String {
        get { AppPaths.defaults.string(forKey: lastEmailKey) ?? "" }
        set {
            if settings.rememberEmail {
                AppPaths.defaults.set(newValue, forKey: lastEmailKey)
            } else {
                AppPaths.defaults.removeObject(forKey: lastEmailKey)
            }
        }
    }

    private func restoreSession() {
        guard let saved = CredentialStore.load(), saved.hasUsableKeys else { return }
        credentials = saved
        accountState = .signedIn
    }

    func signIn(email: String, password: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            loginError = "Enter your email address and password."
            return
        }
        accountState = .signingIn
        loginError = nil
        do {
            let credentials = try await archiveClient.login(email: email, password: password)
            didSignIn(credentials)
            lastEmail = email
        } catch {
            accountState = .signedOut
            loginError = error.localizedDescription
        }
    }

    func signInWithKeys(accessKey: String, secretKey: String) {
        let access = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty, !secret.isEmpty else {
            loginError = "Enter both the access key and the secret key."
            return
        }
        didSignIn(ArchiveCredentials(accessKey: access, secretKey: secret, screenName: nil, email: nil))
    }

    private func didSignIn(_ credentials: ArchiveCredentials) {
        self.credentials = credentials
        CredentialStore.save(credentials)
        loginError = nil
        accountState = .signedIn
        queue.credentials = credentials
        queue.resumeScheduling()
        Task { await loadMyUploads() }
    }

    func signOut() {
        queue.pauseAll()
        CredentialStore.clear()
        credentials = nil
        queue.credentials = nil
        accountState = .signedOut
    }

    func clearRememberedEmail() {
        AppPaths.defaults.removeObject(forKey: lastEmailKey)
    }

    // MARK: - Files step

    /// Adds files and folders. Folders keep their structure; with
    /// `keepTopFolder` the dropped folder's own name is the top folder.
    func addFiles(_ urls: [URL], intoFolder folder: String = "") {
        guard !urls.isEmpty else { return }
        isScanning = true
        let includeHidden = settings.includeHiddenFiles
        let keepTop = settings.keepTopFolder
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FileScanner.scan(urls: urls, includeHidden: includeHidden)
            }.value
            if folder.isEmpty {
                for url in urls where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    sourceRoots[url.standardizedFileURL.lastPathComponent] = url.standardizedFileURL
                }
            }
            var seen = Set(files.map { $0.url.standardizedFileURL.path })
            var added: [PickedFile] = []
            for scanned in result.files {
                guard seen.insert(scanned.url.standardizedFileURL.path).inserted else { continue }
                var relative = scanned.relativePath
                if !keepTop, let root = scanned.rootName, relative.hasPrefix(root + "/") {
                    relative = String(relative.dropFirst(root.count + 1))
                }
                added.append(PickedFile(
                    url: scanned.url,
                    rootName: scanned.rootName,
                    rawRelativePath: RemotePath.join(folder, relative),
                    byteSize: scanned.byteSize
                ))
            }
            let previous = files
            files.append(contentsOf: added)
            files.sort { $0.rawRelativePath.localizedStandardCompare($1.rawRelativePath) == .orderedAscending }
            if !folder.isEmpty { planFolders.remove(folder) }
            if !added.isEmpty {
                prepareMetadataDefaultsIfNeeded()
                registerUndo("Add Files") { [weak self] in self?.files = previous }
            }
            if !result.unreadable.isEmpty {
                banner = Banner(kind: .warning, message: "Could not read: \(result.unreadable.prefix(3).joined(separator: ", "))\(result.unreadable.count > 3 ? "…" : "")")
            }
            isScanning = false
        }
    }

    func presentFilePicker(intoFolder folder: String = "") {
        addFiles(FilePicker.chooseFiles(), intoFolder: folder)
    }

    func presentFolderPicker(intoFolder folder: String = "") {
        addFiles(FilePicker.chooseFolders(), intoFolder: folder)
    }

    /// The path a file will have in the item (sanitized, with destination folder).
    func plannedRemotePath(for file: PickedFile) -> String {
        RemotePath.join(
            UploadPlanBuilder.normalizedFolder(uploadDestinationFolder, sanitize: settings.sanitizeFileNames),
            file.remotePath(sanitize: settings.sanitizeFileNames)
        )
    }

    var fileTree: [TreeNode] {
        FileTreeBuilder.build(
            files.map { TreeEntry(key: $0.id.uuidString, path: $0.rawRelativePath, size: $0.byteSize) },
            extraFolders: planFolders
        )
    }

    /// Files under the given tree node IDs (folders expand to their contents).
    func files(forNodeIDs ids: Set<String>) -> [PickedFile] {
        let fileIDs = Set(ids.compactMap(TreeNode.fileKey(fromID:)))
        let folders = ids.compactMap(TreeNode.folderPath(fromID:))
        return files.filter { file in
            fileIDs.contains(file.id.uuidString) || folders.contains { RemotePath.isInside(file.rawRelativePath, folder: $0) }
        }
    }

    func removeFileNodes(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let previousFiles = files, previousFolders = planFolders
        let removing = Set(files(forNodeIDs: ids).map(\.id))
        let folders = ids.compactMap(TreeNode.folderPath(fromID:))
        files.removeAll { removing.contains($0.id) }
        planFolders = planFolders.filter { path in !folders.contains { RemotePath.isInside(path, folder: $0) } }
        fileSelection.subtract(ids)
        registerUndo("Remove") { [weak self] in
            self?.files = previousFiles
            self?.planFolders = previousFolders
        }
    }

    func clearFiles() {
        guard !files.isEmpty || !planFolders.isEmpty else { return }
        let previousFiles = files, previousFolders = planFolders
        files.removeAll()
        planFolders.removeAll()
        fileSelection.removeAll()
        registerUndo("Clear Files") { [weak self] in
            self?.files = previousFiles
            self?.planFolders = previousFolders
        }
    }

    func createPlanFolder(named name: String, inside parent: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return }
        let previous = planFolders
        planFolders.insert(RemotePath.join(parent, clean))
        registerUndo("New Folder") { [weak self] in self?.planFolders = previous }
    }

    /// Renames a file or folder in the Files plan.
    func renameFileNode(_ id: String, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return }
        let previousFiles = files, previousFolders = planFolders
        if let folder = TreeNode.folderPath(fromID: id) {
            let target = RemotePath.join(RemotePath.parent(of: folder), clean)
            reparentPlan(from: folder, to: target)
        } else if let key = TreeNode.fileKey(fromID: id), let index = files.firstIndex(where: { $0.id.uuidString == key }) {
            files[index].rawRelativePath = RemotePath.join(RemotePath.parent(of: files[index].rawRelativePath), clean)
        }
        registerUndo("Rename") { [weak self] in
            self?.files = previousFiles
            self?.planFolders = previousFolders
        }
    }

    /// Moves files and folders into `destination` ("" = item root).
    func moveFileNodes(_ ids: Set<String>, to destination: String) {
        let previousFiles = files, previousFolders = planFolders
        for id in ids {
            if let folder = TreeNode.folderPath(fromID: id) {
                guard !RemotePath.isInside(destination, folder: folder) else { continue } // no moving into itself
                let target = RemotePath.join(destination, (folder as NSString).lastPathComponent)
                reparentPlan(from: folder, to: target)
            } else if let key = TreeNode.fileKey(fromID: id), let index = files.firstIndex(where: { $0.id.uuidString == key }) {
                files[index].rawRelativePath = RemotePath.join(destination, files[index].displayName)
            }
        }
        if !destination.isEmpty { planFolders.remove(destination) }
        registerUndo("Move") { [weak self] in
            self?.files = previousFiles
            self?.planFolders = previousFolders
        }
    }

    private func reparentPlan(from folder: String, to target: String) {
        for index in files.indices where RemotePath.isInside(files[index].rawRelativePath, folder: folder) {
            files[index].rawRelativePath = RemotePath.reparent(files[index].rawRelativePath, from: folder, to: target)
        }
        planFolders = Set(planFolders.map { RemotePath.isInside($0, folder: folder) ? RemotePath.reparent($0, from: folder, to: target) : $0 })
        let key = "files.expanded"
        if ViewMemory.shared.contains(key, folder) {
            ViewMemory.shared.setMember(key, target, true)
        }
    }

    var planFolderPaths: [String] {
        FileTreeBuilder.folderPaths(fileTree)
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteSize } }
    var totalFiles: Int { files.count }

    private func prepareMetadataDefaultsIfNeeded() {
        if metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let inferred = inferredTitle() {
            metadata.title = inferred
            if identifierAuto {
                metadata.identifier = IdentifierRules.suggestion(from: inferred)
            }
        }
        if metadata.date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata.date = ItemMetadata.todayString()
        }
        if !mediatypeTouched, let inferred = Mediatype.inferred(from: files.map(\.url)) {
            metadata.mediatype = inferred
            if !collectionTouched {
                metadata.collections = inferred.defaultCollection
            }
        }
    }

    private func inferredTitle() -> String? {
        let roots = Set(files.compactMap { $0.rootName?.trimmedNonEmpty })
        if roots.count == 1, let root = roots.first { return root }
        if files.count == 1, let only = files.first {
            let base = (only.displayName as NSString).deletingPathExtension
            return base.isEmpty ? only.displayName : base
        }
        return nil
    }

    // MARK: - Metadata

    func titleDidChange() {
        guard identifierAuto else { return }
        let suggestion = IdentifierRules.suggestion(from: metadata.title)
        if metadata.identifier != suggestion {
            metadata.identifier = suggestion
        }
    }

    func setIdentifierAuto(_ enabled: Bool) {
        identifierAuto = enabled
        if enabled { titleDidChange() }
    }

    func setMediatype(_ mediatype: Mediatype) {
        let previous = metadata.mediatype
        let previousCollections = metadata.collections
        let previousTouched = collectionTouched
        mediatypeTouched = true
        metadata.mediatype = mediatype
        if !collectionTouched {
            metadata.collections = mediatype.defaultCollection
        }
        registerUndo("Change Mediatype") { [weak self] in
            guard let self else { return }
            self.metadata.mediatype = previous
            if !previousTouched { self.metadata.collections = previousCollections }
            self.mediatypeTouched = false
        }
    }

    func updateCollections(_ value: String) {
        let previous = metadata.collections
        let previousTouched = collectionTouched
        collectionTouched = true
        metadata.collections = value
        registerUndo("Edit Collections") { [weak self] in
            guard let self else { return }
            self.metadata.collections = previous
            self.collectionTouched = previousTouched
        }
    }

    func checkIdentifierAvailability() async {
        let identifier = metadata.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let issue = IdentifierRules.issue(for: identifier) {
            identifierCheck = .invalid(issue.message)
            return
        }
        guard credentials != nil else {
            identifierCheck = .idle
            return
        }
        identifierCheck = .checking
        do {
            try await Task.sleep(nanoseconds: 600_000_000)
        } catch {
            return
        }
        if Task.isCancelled { return }
        do {
            let exists = try await archiveClient.itemExists(identifier)
            if Task.isCancelled { return }
            identifierCheck = exists ? .taken : .available
            if exists {
                await loadExistingFiles()
            } else {
                existingFiles = []
            }
        } catch {
            if Task.isCancelled { return }
            identifierCheck = .failed(error.localizedDescription)
        }
    }

    func loadExistingFiles() async {
        let identifier = metadata.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        isLoadingExistingFiles = true
        defer { isLoadingExistingFiles = false }
        do {
            let server = try await archiveClient.fetchItemFiles(identifier)
            existingFiles = overlay.merge(identifier: identifier, server: server).files
        } catch ArchiveError.notFound {
            existingFiles = []
        } catch {
            existingFiles = []
            banner = Banner(kind: .error, message: "Could not load existing files: \(error.localizedDescription)")
        }
    }

    func addCustomField() {
        let previous = metadata.customFields
        metadata.customFields.append(CustomMetadataField())
        registerUndo("Add Custom Field") { [weak self] in self?.metadata.customFields = previous }
    }

    func removeCustomField(_ id: UUID) {
        let previous = metadata.customFields
        metadata.customFields.removeAll { $0.id == id }
        registerUndo("Remove Custom Field") { [weak self] in self?.metadata.customFields = previous }
    }

    // MARK: - Upload step → queue

    var canStartUpload: Bool {
        credentials != nil && !files.isEmpty && !isPreparingUpload && metadata.isReadyToUpload && identifierCheck != .taken
    }

    /// Why the new item can't be uploaded yet (nil when ready).
    var uploadBlocker: String? {
        if credentials == nil { return "Sign in first." }
        if files.isEmpty { return "Add files or folders." }
        if let issue = metadata.issues.first { return issue.message }
        if identifierCheck == .taken { return "That identifier is already used. Pick another one, or open the item from My Items to add files to it." }
        return nil
    }

    var isUploading: Bool { queue.isRunning }

    var itemURL: URL? {
        let identifier = (route.identifier ?? metadata.identifier).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }
        return URL(string: "https://archive.org/details/\(identifier)")
    }

    /// Creates the new item: queues its files, links the dropped folder
    /// (if there was exactly one) and opens the item.
    func startUpload() {
        guard canStartUpload else { return }
        Task {
            let identifier = metadata.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let report = await enqueue(
                files: files,
                identifier: identifier,
                destinationFolder: "",
                newItemMetadata: metadata,
                allowExisting: false,
                title: metadata.title
            )
            lastEnqueueReport = report
            guard report.error == nil else {
                banner = Banner(kind: .error, message: report.error ?? "")
                return
            }
            // One dropped folder and nothing else → link it, so later changes
            // in Finder can be synced to the item.
            let roots = Set(files.map { $0.rootName })
            if roots.count == 1, let name = roots.first ?? nil, let url = sourceRoots[name] {
                let prefix = files.allSatisfy { $0.rawRelativePath.hasPrefix(name + "/") } ? name : ""
                linkedFolders[identifier] = LinkedFolder(localPath: url.path, remoteFolder: prefix)
            }
            let title = metadata.title
            myUploads.insert(RemoteItem(identifier: identifier, title: title, fileCount: files.count, itemSize: totalBytes, isDark: false), at: 0)
            clearNewItem()
            openItem(identifier)
        }
    }

    /// The single entry point that turns local files into queue jobs, for
    /// new items, existing items, Manage drops and folder sync alike.
    func enqueue(
        files selection: [PickedFile],
        identifier rawIdentifier: String,
        destinationFolder: String,
        newItemMetadata: ItemMetadata?,
        allowExisting: Bool,
        title: String,
        policy: ExistingFilePolicy? = nil,
        forceReplace: Set<String> = [],
        sanitizeOverride: Bool? = nil
    ) async -> EnqueueReport {
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        var report = EnqueueReport(identifier: identifier)
        guard credentials != nil else { report.error = "Sign in before uploading."; return report }
        guard !selection.isEmpty else { report.error = "Nothing to upload."; return report }
        if let issue = IdentifierRules.issue(for: identifier) { report.error = issue.message; return report }

        isPreparingUpload = true
        defer { isPreparingUpload = false }

        // 1. What is already in the item?
        var remote: [RemoteFile] = []
        var itemExists = false
        do {
            if try await archiveClient.fetchItem(identifier, allowMissing: true) != nil {
                itemExists = true
                remote = try await archiveClient.fetchItemFiles(identifier)
            }
        } catch {
            report.error = "Could not check the item on archive.org: \(error.localizedDescription)"
            return report
        }
        remote = overlay.merge(identifier: identifier, server: remote).files
        let queuedForItem = queue.jobs.contains { $0.identifier == identifier && $0.status != .done }
        if itemExists && newItemMetadata != nil && !allowExisting {
            report.error = "The identifier “\(identifier)” is already used by an item. Choose another identifier, or turn on “Add to existing item”."
            return report
        }
        if !itemExists && newItemMetadata == nil && !queuedForItem {
            report.error = "There is no item called “\(identifier)” on archive.org yet. Create it from Files → Metadata → Upload first."
            return report
        }

        // 2. Exact remote paths.
        let plan = UploadPlanBuilder.build(
            identifier: identifier,
            metadata: newItemMetadata ?? ItemMetadata(),
            files: selection,
            sanitizeNames: sanitizeOverride ?? settings.sanitizeFileNames,
            destinationFolder: destinationFolder,
            options: settings.uploadOptions
        )

        // 3. Checksums only where they matter: same path and same size.
        let remoteByPath = Dictionary(remote.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let verify = settings.verifyChecksums
        // Also hash files whose size matches an original somewhere else in the
        // item: same content in another folder must not be uploaded again.
        let originals = remote.filter(\.isOriginal)
        let sizesElsewhere = Set(originals.compactMap(\.size))
        let needsMD5 = plan.files.filter { file in
            if verify, let existing = remoteByPath[file.remotePath], existing.md5 != nil,
               existing.size == nil || existing.size == file.byteSize { return true }
            return remoteByPath[file.remotePath] == nil && sizesElsewhere.contains(file.byteSize)
        }
        let md5s: [UUID: String] = await Task.detached(priority: .userInitiated) {
            var result: [UUID: String] = [:]
            for file in needsMD5 {
                if let digest = MD5Cache.shared.md5(for: file.localURL, size: file.byteSize) { result[file.id] = digest }
            }
            MD5Cache.shared.save()
            return result
        }.value
        var byContent: [String: String] = [:]   // "size:md5" -> existing path
        for file in originals {
            if let md5 = file.md5?.lowercased(), let size = file.size { byContent["\(size):\(md5)"] = byContent["\(size):\(md5)"] ?? file.name }
        }

        let candidates = plan.files.map {
            SyncPlanner.Candidate(remotePath: $0.remotePath, byteSize: $0.byteSize, localMD5: md5s[$0.id])
        }
        let decisions = SyncPlanner.decide(
            candidates,
            remote: remote,
            queuedPaths: queue.pendingPaths(for: identifier),
            policy: policy ?? settings.existingFilePolicy
        )

        // 4. Jobs.
        let batch = UploadBatch(identifier: identifier, title: title.isEmpty ? identifier : title, isNewItem: !itemExists)
        let creatorAlreadyQueued = queue.jobs.contains { $0.identifier == identifier && $0.createsItem }
        let headers = newItemMetadata.map { MetadataHeaderBuilder.headers(for: $0).map { HeaderPair(name: $0.0, value: $0.1) } } ?? []
        var jobs: [UploadJob] = []
        for (file, decision) in zip(plan.files, decisions) {
            var path = file.remotePath
            var replaces = false
            switch decision {
            case .upload:
                if let md5 = md5s[file.id]?.lowercased(), let existing = byContent["\(file.byteSize):\(md5)"], existing != path, !forceReplace.contains(path) {
                    report.existsElsewhere.append((path, existing))
                    continue
                }
            case .skipIdentical:
                if forceReplace.contains(file.remotePath) { replaces = true } else { report.skippedIdentical.append(path); continue }
            case .replace:
                replaces = true
                report.replaced.append(path)
            case .skipDifferent:
                if forceReplace.contains(file.remotePath) { replaces = true } else { report.skippedDifferent.append(path); continue }
            case .rename(let newPath):
                report.renamed.append(newPath)
                path = newPath
            case .alreadyQueued:
                report.alreadyQueued.append(path)
                continue
            }
            var job = UploadJob(
                batchID: batch.id,
                identifier: identifier,
                localPath: file.localURL.path,
                remotePath: path,
                byteSize: file.byteSize,
                contentType: file.contentType
            )
            job.replacesExisting = replaces
            if !itemExists && !creatorAlreadyQueued && jobs.isEmpty {
                job.createsItem = true
                job.metadataHeaders = headers
            }
            jobs.append(job)
        }
        // Upload the smallest file first when creating an item, so the item
        // exists quickly and everything else can run in parallel.
        if let creatorIndex = jobs.firstIndex(where: \.createsItem), jobs.count > 1,
           let smallest = jobs.indices.min(by: { jobs[$0].byteSize < jobs[$1].byteSize }), smallest != creatorIndex {
            jobs[smallest].createsItem = true
            jobs[smallest].metadataHeaders = jobs[creatorIndex].metadataHeaders
            jobs[creatorIndex].createsItem = false
            jobs[creatorIndex].metadataHeaders = []
            jobs.swapAt(0, smallest)
        }
        report.queued = jobs.count
        report.queuedBytes = jobs.reduce(0) { $0 + $1.byteSize }
        queue.enqueue(jobs, batch: batch)
        if !report.skippedIdentical.isEmpty || !report.alreadyQueued.isEmpty {
            queue.appendLog("“\(identifier)”: \(report.summary)")
        }
        return report
    }

    /// Clears the New Item form.
    func clearNewItem() {
        files.removeAll()
        planFolders.removeAll()
        fileSelection.removeAll()
        sourceRoots.removeAll()
        metadata = ItemMetadata()
        metadata.mediatype = settings.defaultMediatype
        metadata.collections = settings.defaultMediatype.defaultCollection
        identifierAuto = true
        identifierCheck = .idle
        existingFiles = []
        mediatypeTouched = false
        collectionTouched = false
        uploadDestinationFolder = ""
    }

    func startNewItem() {
        taskPoller?.cancel()
        taskPoller = nil
        route = .newItem
    }

    /// Shows an item in the workspace and loads it.
    func openItem(_ identifier: String) {
        let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let changed = managedIdentifier != id
        route = .item(id)
        managedIdentifier = id
        if changed {
            manageSelection.removeAll()
            syncPlan = nil
            syncMessage = nil
            managedFiles = []
            lastServerFiles = []
            managedMetadata = ItemMetadata()
            managedOriginalMetadata = ItemMetadata()
        }
        if changed || taskPoller == nil { startTaskPolling() }
        Task {
            await loadManagedItem()
            if linkedFolders[id] != nil { await checkSync() }
        }
    }

    /// Items for the sidebar: account search results, plus anything this app
    /// uploaded or is uploading that search doesn't know about yet.
    var sidebarItems: [RemoteItem] {
        var seen = Set<String>()
        var result: [RemoteItem] = []
        seen.formUnion(hiddenItems)
        seen.formUnion(itemDeletions.keys)   // being deleted right now
        for item in myUploads where seen.insert(item.identifier).inserted { result.append(item) }
        for batch in queue.batches where seen.insert(batch.identifier).inserted {
            result.insert(RemoteItem(identifier: batch.identifier, title: batch.title, fileCount: 0, itemSize: nil, isDark: false), at: 0)
        }
        for record in history.records where seen.insert(record.identifier).inserted {
            result.append(RemoteItem(identifier: record.identifier, title: record.title, fileCount: record.fileCount, itemSize: record.totalBytes, isDark: false))
        }
        return result
    }

    func openItemPage() {
        guard let url = itemURL else { return }
        FilePicker.open(url)
    }

    func copyItemLink() {
        guard let url = itemURL else { return }
        FilePicker.copyToPasteboard(url.absoluteString)
    }

    private func jobSucceeded(_ job: UploadJob) {
        overlay.recordAdded(identifier: job.identifier, path: job.remotePath, size: job.byteSize)
        let title = queue.batch(job.batchID)?.title ?? job.identifier
        history.recordFile(identifier: job.identifier, title: title, bytes: job.byteSize)
        if job.identifier == managedIdentifier {
            refreshManagedFromOverlay()
        }
        if job.identifier == metadata.identifier.trimmingCharacters(in: .whitespaces) {
            existingFiles = overlay.merge(identifier: job.identifier, server: existingFiles).files
        }
    }

    // MARK: - Manage

    func loadMyUploads() async {
        guard let credentials else { return }
        let uploader = credentials.email ?? credentials.screenName ?? credentials.itemName
        guard let uploader, !uploader.isEmpty else { return }
        isLoadingMyUploads = true
        defer { isLoadingMyUploads = false }
        do {
            myUploads = try await archiveClient.searchUploads(by: uploader)
        } catch {
            myUploads = []
        }
    }

    var managedFileManager: ArchiveFileManager? {
        guard let credentials else { return nil }
        let manager = ArchiveFileManager(credentials: credentials)
        manager.onRetry = { [weak self] message in
            Task { @MainActor in self?.serverOperation?.detail = message }
        }
        return manager
    }

    var managedMetadataIsDirty: Bool { managedMetadata != managedOriginalMetadata }

    @ObservationIgnored private var lastServerFiles: [RemoteFile] = []

    func loadManagedItem() async {
        let identifier = managedIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        managedIdentifier = identifier
        isLoadingManagedItem = true
        managedItemError = nil
        defer { isLoadingManagedItem = false }
        do {
            let raw = try await archiveClient.fetchRawMetadata(identifier)
            managedMetadata = Self.itemMetadata(from: raw, identifier: identifier)
            managedOriginalMetadata = managedMetadata
            lastServerFiles = try await archiveClient.fetchItemFiles(identifier)
            refreshManagedFromOverlay()
            let tree = managedTree
            manageSelection = manageSelection.filter { FileTreeBuilder.find($0, in: tree) != nil }
        } catch {
            managedItemError = error.localizedDescription
            lastServerFiles = []
            managedFiles = []
            managedPending = []
        }
    }

    private func refreshManagedFromOverlay() {
        let merged = overlay.merge(identifier: managedIdentifier, server: lastServerFiles)
        managedFiles = merged.files
        managedPending = merged.pending
    }

    var managedVisibleFiles: [RemoteFile] {
        showDerivedFiles ? managedFiles : managedFiles.filter(\.isOriginal)
    }

    var managedTree: [TreeNode] {
        var entries: [String: TreeEntry] = [:]
        for file in managedVisibleFiles {
            entries[file.name] = TreeEntry(key: file.name, path: file.name, size: file.size ?? 0, badge: managedPending.contains(file.name) ? .processing : nil)
        }
        for job in queue.jobs where job.identifier == managedIdentifier && job.status != .done && entries[job.remotePath] == nil {
            entries[job.remotePath] = TreeEntry(key: job.remotePath, path: job.remotePath, size: job.byteSize, badge: .queued)
        }
        // Overlay what syncing with the linked Finder folder would change.
        if let plan = syncPlan {
            for update in plan.updates { entries[update.remotePath]?.badge = .modified }
            for upload in plan.uploads {
                entries[upload.remotePath] = TreeEntry(key: upload.remotePath, path: upload.remotePath, size: upload.byteSize, badge: .added)
            }
            for move in plan.moves {
                entries[move.from]?.badge = .movedAway
                entries[move.from]?.note = "→ " + move.to
                entries[move.to] = TreeEntry(key: move.to, path: move.to, size: move.byteSize, badge: .movedHere, note: "from " + move.from)
            }
            for removal in plan.removals { entries[removal.remotePath]?.badge = .removing }
        }
        var list = Array(entries.values)
        if showOnlyChanges && syncPlan != nil {
            list = list.filter { $0.badge?.isChange == true }
        }
        return FileTreeBuilder.build(list, extraFolders: showOnlyChanges ? [] : (managedVirtualFolders[managedIdentifier] ?? []))
    }

    var managedFolderPaths: [String] {
        FileTreeBuilder.folderPaths(managedTree)
    }

    /// Remote paths (originals) covered by the selected node IDs.
    func remotePaths(forNodeIDs ids: Set<String>) -> [String] {
        let direct = ids.compactMap(TreeNode.fileKey(fromID:))
        let folders = ids.compactMap(TreeNode.folderPath(fromID:))
        let inFolders = managedFiles.filter { file in
            file.isOriginal && folders.contains { RemotePath.isInside(file.name, folder: $0) }
        }.map(\.name)
        let existing = Set(managedFiles.map(\.name))
        return Array(Set(direct.filter { existing.contains($0) } + inFolders)).sorted()
    }

    func saveManagedMetadata() async {
        guard let credentials else { return }
        let identifier = managedIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        isSavingMetadata = true
        defer { isSavingMetadata = false }
        do {
            try await archiveClient.writeMetadata(identifier: identifier, newMetadata: managedMetadata, previous: managedOriginalMetadata, credentials: credentials)
            managedOriginalMetadata = managedMetadata
            managedItemError = nil
            banner = Banner(kind: .success, message: "Metadata saved. archive.org may take a minute to show the change.")
        } catch {
            managedItemError = error.localizedDescription
        }
    }

    func revertManagedMetadata() {
        managedMetadata = managedOriginalMetadata
    }

    // Folders

    func createManagedFolder(named name: String, inside parent: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, !managedIdentifier.isEmpty else { return }
        let path = RemotePath.join(parent, settings.sanitizeFileNames ? RemotePath.sanitizedComponent(clean) : clean)
        managedVirtualFolders[managedIdentifier, default: []].insert(path)
        if !parent.isEmpty { ViewMemory.shared.setMember(manageExpandedKey, parent, true) }
        manageSelection = [TreeNode.folderID(path)]
    }

    var manageExpandedKey: String { "manage.expanded.\(managedIdentifier)" }

    private func dropVirtualFolders(inside folder: String) {
        guard var set = managedVirtualFolders[managedIdentifier] else { return }
        set = set.filter { !RemotePath.isInside($0, folder: folder) }
        managedVirtualFolders[managedIdentifier] = set
    }

    /// Moves files/folders to `destination` on archive.org (copy + delete).
    func moveManagedNodes(_ ids: Set<String>, to destination: String) async {
        var moves: [(String, String)] = []
        for id in ids {
            if let folder = TreeNode.folderPath(fromID: id) {
                guard !RemotePath.isInside(destination, folder: folder) else { continue }
                let target = RemotePath.join(destination, (folder as NSString).lastPathComponent)
                moves += managedFiles.filter { $0.isOriginal && RemotePath.isInside($0.name, folder: folder) }
                    .map { ($0.name, RemotePath.reparent($0.name, from: folder, to: target)) }
                renameVirtualFolders(from: folder, to: target)
                queue.editFolder(identifier: managedIdentifier, from: folder, to: target)
            } else if let path = TreeNode.fileKey(fromID: id) {
                let target = RemotePath.join(destination, (path as NSString).lastPathComponent)
                if managedFiles.contains(where: { $0.name == path }) {
                    moves.append((path, target))
                } else if let job = queue.jobs.first(where: { $0.identifier == managedIdentifier && $0.remotePath == path && $0.status != .done }) {
                    queue.editRemotePath(job.id, to: target)
                }
            }
        }
        if !destination.isEmpty { managedVirtualFolders[managedIdentifier]?.remove(destination) }
        await performMoves(moves.filter { $0.0 != $0.1 })
    }

    /// Renames a single file or folder on archive.org.
    func renameManagedNode(_ id: String, to newName: String) async {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return }
        let name = settings.sanitizeFileNames ? RemotePath.sanitizedComponent(clean) : clean
        if let folder = TreeNode.folderPath(fromID: id) {
            let target = RemotePath.join(RemotePath.parent(of: folder), name)
            guard target != folder else { return }
            let moves = managedFiles.filter { $0.isOriginal && RemotePath.isInside($0.name, folder: folder) }
                .map { ($0.name, RemotePath.reparent($0.name, from: folder, to: target)) }
            renameVirtualFolders(from: folder, to: target)
            queue.editFolder(identifier: managedIdentifier, from: folder, to: target)
            await performMoves(moves)
            manageSelection = [TreeNode.folderID(target)]
        } else if let path = TreeNode.fileKey(fromID: id) {
            let target = RemotePath.join(RemotePath.parent(of: path), name)
            guard target != path else { return }
            if managedFiles.contains(where: { $0.name == path }) {
                await performMoves([(path, target)])
            } else if let job = queue.jobs.first(where: { $0.identifier == managedIdentifier && $0.remotePath == path && $0.status != .done }) {
                queue.editRemotePath(job.id, to: target)
            }
            manageSelection = [TreeNode.fileID(target)]
        }
    }

    private func renameVirtualFolders(from folder: String, to target: String) {
        guard let set = managedVirtualFolders[managedIdentifier] else { return }
        managedVirtualFolders[managedIdentifier] = Set(set.map { RemotePath.isInside($0, folder: folder) ? RemotePath.reparent($0, from: folder, to: target) : $0 })
        if ViewMemory.shared.contains(manageExpandedKey, folder) {
            ViewMemory.shared.setMember(manageExpandedKey, target, true)
        }
    }

    private func performMoves(_ moves: [(String, String)], allowOverwrite: Bool = false) async {
        guard !moves.isEmpty, let manager = managedFileManager else { return }
        let identifier = managedIdentifier
        let taken = Set(managedFiles.map(\.name))
        if !allowOverwrite, let clash = moves.first(where: { taken.contains($0.1) && !moves.map(\.0).contains($0.1) }) {
            managedItemError = "“\(clash.1)” already exists. Rename or delete it first."
            return
        }
        serverOperation = ServerOperation(title: "Moving", done: 0, total: moves.count)
        defer { serverOperation = nil }
        var failures: [String] = []
        for (source, destination) in moves {
            do {
                try await manager.move(item: identifier, from: source, to: destination)
                let size = managedFiles.first(where: { $0.name == source })?.size ?? 0
                overlay.recordAdded(identifier: identifier, path: destination, size: size)
                overlay.recordRemoved(identifier: identifier, path: source)
                refreshManagedFromOverlay()
            } catch {
                failures.append(error.localizedDescription)
            }
            serverOperation?.done += 1
        }
        if !failures.isEmpty {
            managedItemError = "\(failures.count) move(s) failed. \(failures.first ?? "")"
        }
    }

    /// Deletes files and folders (everything inside) from archive.org.
    /// Queued uploads under them are removed from the queue; empty folders
    /// are just forgotten.
    func deleteManagedNodes(_ ids: Set<String>) async {
        let identifier = managedIdentifier
        let paths = remotePaths(forNodeIDs: ids)
        let folders = ids.compactMap(TreeNode.folderPath(fromID:))
        let directFiles = Set(ids.compactMap(TreeNode.fileKey(fromID:)))
        let queuedIDs = queue.jobs.filter { job in
            job.identifier == identifier && job.status != .done &&
            (directFiles.contains(job.remotePath) || folders.contains { RemotePath.isInside(job.remotePath, folder: $0) })
        }.map(\.id)
        queue.remove(Set(queuedIDs))
        folders.forEach(dropVirtualFolders(inside:))
        manageSelection.subtract(ids)

        guard !paths.isEmpty, let manager = managedFileManager else { return }
        serverOperation = ServerOperation(title: "Deleting", done: 0, total: paths.count)
        defer { serverOperation = nil }
        var failures: [String] = []
        for path in paths {
            do {
                try await manager.delete(item: identifier, remotePath: path)
                overlay.recordRemoved(identifier: identifier, path: path)
                refreshManagedFromOverlay()
            } catch {
                failures.append(error.localizedDescription)
            }
            serverOperation?.done += 1
        }
        if !failures.isEmpty {
            managedItemError = "\(failures.count) delete(s) failed. \(failures.first ?? "")"
        }
    }

    func downloadManagedNodes(_ ids: Set<String>, to directory: URL) async {
        let paths = showDerivedFiles
            ? Array(Set(ids.compactMap(TreeNode.fileKey(fromID:)) + remotePaths(forNodeIDs: ids)))
            : remotePaths(forNodeIDs: ids)
        guard !paths.isEmpty, let manager = managedFileManager else { return }
        serverOperation = ServerOperation(title: "Downloading", done: 0, total: paths.count)
        defer { serverOperation = nil }
        var failures = 0
        for path in paths {
            do {
                _ = try await manager.download(item: managedIdentifier, remotePath: path, to: directory)
            } catch {
                failures += 1
                managedItemError = error.localizedDescription
            }
            serverOperation?.done += 1
        }
        if failures == 0 {
            FilePicker.revealInFinder(directory)
        }
    }

    /// Uploads local files/folders into a folder of the managed item.
    func uploadToManagedItem(_ urls: [URL], folder: String) async {
        guard !urls.isEmpty else { return }
        let includeHidden = settings.includeHiddenFiles
        let keepTop = settings.keepTopFolder
        let scanned = await Task.detached(priority: .userInitiated) {
            FileScanner.scan(urls: urls, includeHidden: includeHidden)
        }.value
        let picked = scanned.files.map { file -> PickedFile in
            var relative = file.relativePath
            if !keepTop, let root = file.rootName, relative.hasPrefix(root + "/") {
                relative = String(relative.dropFirst(root.count + 1))
            }
            return PickedFile(url: file.url, rootName: file.rootName, rawRelativePath: relative, byteSize: file.byteSize)
        }
        let report = await enqueue(
            files: picked,
            identifier: managedIdentifier,
            destinationFolder: folder,
            newItemMetadata: nil,
            allowExisting: true,
            title: managedMetadata.title
        )
        if let error = report.error {
            managedItemError = error
        } else {
            managedVirtualFolders[managedIdentifier]?.remove(folder)
            queue.appendLog(report.summary)
            banner = Banner(kind: .info, message: report.summary)
        }
    }

    // MARK: Linked Finder folder sync (Finder is the reference)

    var linkedFolder: LinkedFolder? {
        linkedFolders[managedIdentifier]
    }

    func linkFolder(_ url: URL, remoteFolder: String) {
        guard !managedIdentifier.isEmpty else { return }
        linkedFolders[managedIdentifier] = LinkedFolder(localPath: url.standardizedFileURL.path, remoteFolder: RemotePath.join(remoteFolder))
        syncPlan = nil
        Task { await checkSync() }
    }

    func unlinkFolder() {
        linkedFolders[managedIdentifier] = nil
        syncPlan = nil
        syncMessage = nil
    }

    /// Compares the linked Finder folder with the item (like `git status`).
    func checkSync() async {
        guard let link = linkedFolder else { return }
        guard FileManager.default.fileExists(atPath: link.localPath) else {
            syncMessage = "The linked folder \(link.displayPath) can't be found. Link it again."
            syncPlan = nil
            return
        }
        isCheckingSync = true
        syncMessage = "Comparing \(link.displayPath) with archive.org…"
        defer { isCheckingSync = false }
        do {
            lastServerFiles = try await archiveClient.fetchItemFiles(managedIdentifier)
            refreshManagedFromOverlay()
        } catch {
            syncMessage = "Could not read the item: \(error.localizedDescription)"
            return
        }
        // Files already waiting in the queue count as present.
        var remote = managedFiles
        let present = Set(remote.map(\.name))
        for job in queue.jobs where job.identifier == managedIdentifier && job.status != .done && !present.contains(job.remotePath) {
            remote.append(RemoteFile(name: job.remotePath, size: job.byteSize, md5: nil, source: "original"))
        }
        let includeHidden = settings.includeHiddenFiles
        let sanitize = settings.sanitizeFileNames
        let deep = settings.verifyChecksums
        let progress = SyncProgressBox()
        let reporter = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if let text = progress.text { self?.syncMessage = text }
            }
        }
        defer { reporter.cancel() }
        let plan = await Task.detached(priority: .userInitiated) { () -> SyncPlan in
            progress.set("Reading \(link.displayPath)…")
            let scan = SyncPlanner.scanLocal(link.localURL, includeHidden: includeHidden)
            let totalBytes = scan.files.reduce(Int64(0)) { $0 + $1.byteSize }
            var checked = 0
            var checkedBytes: Int64 = 0
            var plan = SyncPlanner.plan(
                local: scan.files,
                remote: remote,
                remoteFolder: link.remoteFolder,
                sanitize: sanitize,
                deepCompare: deep,
                localMD5: { entry in
                    checked += 1
                    progress.set("Verifying checksums: file \(checked) of up to \(scan.files.count) · \(ByteCountFormatter.shortString(checkedBytes)) of \(ByteCountFormatter.shortString(totalBytes)) read · \(entry.relativePath)")
                    let digest = MD5Cache.shared.md5(for: entry.url, size: entry.byteSize)
                    checkedBytes += entry.byteSize
                    return digest
                }
            )
            plan.emptyLocalFolders = scan.emptyFolders
            MD5Cache.shared.save()
            return plan
        }.value
        syncPlan = plan
        syncMessage = nil
        // Mirror empty Finder folders as (virtual) folders in the tree.
        let empties = plan.emptyLocalFolders.map { RemotePath.join(link.remoteFolder, sanitize ? RemotePath.sanitized($0) : $0) }
        if !empties.isEmpty {
            managedVirtualFolders[managedIdentifier, default: []].formUnion(empties)
        }
    }

    // MARK: Sync task list

    /// One step of a sync, shown in order with live status.
    struct SyncTask: Identifiable, Equatable {
        enum Kind: Int, Comparable {
            case folder = 0, move, upload, delete
            static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

            var phase: String {
                switch self {
                case .folder: return "1. Folders"
                case .move: return "2. Move & rename on archive.org"
                case .upload: return "3. Upload new & changed files"
                case .delete: return "4. Remove files not in Finder"
                }
            }
        }
        enum Status: Equatable {
            case pending, running, done, skipped(String), failed(String)
        }
        let id = UUID()
        let kind: Kind
        let title: String
        var detail: String?
        /// For uploads: the remote path, so status can follow the queue job.
        var remotePath: String?
        var status: Status = .pending
        /// Chosen by the user before running. Unselected tasks are skipped.
        var isSelected = true
    }

    /// archive.org's own task queue for the open item (needs S3 keys).
    var itemTaskStatus: ItemTaskStatus?
    @ObservationIgnored private var taskPoller: Task<Void, Never>?

    func refreshItemTasks() async {
        guard let credentials, !managedIdentifier.isEmpty else { return }
        let id = managedIdentifier
        if let status = try? await archiveClient.fetchTaskStatus(id, credentials: credentials), id == managedIdentifier {
            itemTaskStatus = status
        }
    }

    /// Polls the open item's task queue every 30 s.
    private func startTaskPolling() {
        taskPoller?.cancel()
        itemTaskStatus = nil
        taskPoller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshItemTasks()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    var syncTasks: [SyncTask] = []
    var syncIdentifier: String = ""
    var syncCancelRequested = false
    var syncIncludeRemovals = false
    /// True once the prepared task list has been started (it stays visible
    /// with its results until discarded).
    var syncStarted = false

    var hasSyncTasksForCurrentItem: Bool {
        !syncTasks.isEmpty && syncIdentifier == managedIdentifier && route.identifier == managedIdentifier
    }

    func discardSyncTasks() {
        guard !isApplyingSync else { return }
        syncTasks = []
        syncStarted = false
    }

    var selectedSyncTaskCount: Int { syncTasks.filter(\.isSelected).count }

    func setSyncPhase(_ kind: SyncTask.Kind, selected: Bool) {
        for index in syncTasks.indices where syncTasks[index].kind == kind { syncTasks[index].isSelected = selected }
        if kind == .delete { syncIncludeRemovals = selected }
    }

    func toggleSyncTask(_ id: UUID) {
        guard let index = syncTasks.firstIndex(where: { $0.id == id }) else { return }
        syncTasks[index].isSelected.toggle()
    }

    func runSyncTasks() {
        guard !isApplyingSync, selectedSyncTaskCount > 0 else { return }
        syncStarted = true
        Task { await applySync(includeRemovals: syncIncludeRemovals) }
    }

    /// Stops a running sync: the current step finishes, later steps are
    /// skipped, and the sync's uploads still waiting are removed from the queue.
    func cancelSync() {
        guard isApplyingSync else { return }
        syncCancelRequested = true
        let paths = Set(syncTasks.filter { $0.kind == .upload }.compactMap(\.remotePath))
        let pending = queue.jobs.filter { $0.identifier == syncIdentifier && paths.contains($0.remotePath) && $0.status != .done }
        queue.remove(Set(pending.map(\.id)))
        for index in syncTasks.indices {
            switch syncTasks[index].status {
            case .pending: syncTasks[index].status = .skipped("Cancelled")
            case .running where syncTasks[index].kind == .upload: syncTasks[index].status = .skipped("Cancelled")
            default: break
            }
        }
    }

    var syncProgress: (done: Int, total: Int) {
        let finished = syncTasks.filter {
            switch liveStatus(of: $0) { case .done, .skipped, .failed: return true; default: return false }
        }.count
        return (finished, syncTasks.count)
    }

    /// Upload tasks follow their queue job; everything else is stored.
    func liveStatus(of task: SyncTask) -> SyncTask.Status {
        guard task.kind == .upload, let path = task.remotePath, task.status != .pending || isApplyingSync else { return task.status }
        guard let job = queue.jobs.last(where: { $0.identifier == syncIdentifier && $0.remotePath == path }) else { return task.status }
        switch job.status {
        case .done: return .done
        case .failed: return .failed(job.error ?? "Failed")
        case .uploading: return .running
        case .paused, .cancelled: return .skipped(job.status.title)
        case .queued: return task.status == .pending ? .pending : .running
        }
    }

    /// Turns the plan into an ordered task list (shown before and during sync).
    func prepareSyncTasks(includeRemovals: Bool) {
        guard let plan = syncPlan, let link = linkedFolder else { syncTasks = []; return }
        var tasks: [SyncTask] = []
        let existingFolders = Set(FileTreeBuilder.folderPaths(FileTreeBuilder.build(managedFiles.filter(\.isOriginal).map { TreeEntry(key: $0.name, path: $0.name, size: 0) })))
        var neededFolders = Set<String>()
        for path in plan.moves.map(\.to) + plan.uploads.map(\.remotePath) {
            var folder = RemotePath.parent(of: path)
            while !folder.isEmpty && !existingFolders.contains(folder) {
                neededFolders.insert(folder)
                folder = RemotePath.parent(of: folder)
            }
        }
        let sanitize = settings.sanitizeFileNames
        for empty in plan.emptyLocalFolders {
            neededFolders.insert(RemotePath.join(link.remoteFolder, sanitize ? RemotePath.sanitized(empty) : empty))
        }
        for folder in neededFolders.sorted() {
            tasks.append(SyncTask(kind: .folder, title: folder, detail: "Created on archive.org when files are placed in it"))
        }
        for move in plan.moves {
            tasks.append(SyncTask(kind: .move, title: move.to, detail: "from " + move.from))
        }
        for upload in plan.uploads {
            tasks.append(SyncTask(kind: .upload, title: upload.remotePath, detail: "New · " + ByteCountFormatter.shortString(upload.byteSize), remotePath: upload.remotePath))
        }
        for update in plan.updates {
            tasks.append(SyncTask(kind: .upload, title: update.remotePath, detail: "Changed, replaces the old file · " + ByteCountFormatter.shortString(update.byteSize), remotePath: update.remotePath))
        }
        for removal in plan.removals {
            tasks.append(SyncTask(kind: .delete, title: removal.remotePath, detail: "Not in Finder", isSelected: includeRemovals))
        }
        syncTasks = tasks
        syncIdentifier = managedIdentifier
        syncStarted = false
    }

    /// Runs the task list in order (like `git push`): folders, server-side
    /// moves, uploads (waiting until they finish), then removals — removals
    /// only if nothing failed before them, so nothing is ever lost.
    func applySync(includeRemovals: Bool) async {
        guard let plan = syncPlan, !plan.isInSync, !isApplyingSync else { return }
        if syncTasks.isEmpty || syncIdentifier != managedIdentifier { prepareSyncTasks(includeRemovals: includeRemovals) }
        let identifier = managedIdentifier
        isApplyingSync = true
        syncCancelRequested = false
        defer { isApplyingSync = false; syncCancelRequested = false }
        var failed = false
        for index in syncTasks.indices where !syncTasks[index].isSelected {
            syncTasks[index].status = .skipped("Not selected")
        }

        // 1. Folders: remembered so empty ones show; archive.org creates the rest.
        for index in syncTasks.indices where syncTasks[index].kind == .folder && syncTasks[index].isSelected {
            managedVirtualFolders[identifier, default: []].insert(syncTasks[index].title)
            syncTasks[index].status = .done
        }

        // 2. Moves.
        if let manager = managedFileManager {
            for index in syncTasks.indices where syncTasks[index].kind == .move && syncTasks[index].isSelected {
                if syncCancelRequested { break }
                guard let move = plan.moves.first(where: { $0.to == syncTasks[index].title }) else { continue }
                syncTasks[index].status = .running
                do {
                    try await manager.move(item: identifier, from: move.from, to: move.to)
                    overlay.recordAdded(identifier: identifier, path: move.to, size: move.byteSize)
                    overlay.recordRemoved(identifier: identifier, path: move.from)
                    refreshManagedFromOverlay()
                    syncTasks[index].status = .done
                } catch {
                    syncTasks[index].status = .failed(error.localizedDescription)
                    failed = true
                }
            }
        }

        // 3. Uploads, through the queue; wait for them.
        let selectedUploads = Set(syncTasks.filter { $0.kind == .upload && $0.isSelected }.compactMap(\.remotePath))
        let uploads = (plan.uploads + plan.updates).filter { selectedUploads.contains($0.remotePath) }
        if !uploads.isEmpty && !syncCancelRequested {
            for index in syncTasks.indices where syncTasks[index].kind == .upload && syncTasks[index].isSelected { syncTasks[index].status = .running }
            let picked = uploads.map { PickedFile(url: $0.localURL, rootName: nil, rawRelativePath: $0.remotePath, byteSize: $0.byteSize) }
            let report = await enqueue(
                files: picked,
                identifier: identifier,
                destinationFolder: "",
                newItemMetadata: nil,
                allowExisting: true,
                title: managedMetadata.title.isEmpty ? identifier : managedMetadata.title,
                policy: .replace,
                forceReplace: Set(plan.updates.map(\.remotePath)),
                sanitizeOverride: false
            )
            if let error = report.error {
                managedItemError = error
                failed = true
                for index in syncTasks.indices where syncTasks[index].kind == .upload && syncTasks[index].isSelected { syncTasks[index].status = .failed(error) }
            } else {
                let paths = Set(uploads.map(\.remotePath))
                while true {
                    let jobs = queue.jobs.filter { $0.identifier == identifier && paths.contains($0.remotePath) }
                    if syncCancelRequested || jobs.allSatisfy({ $0.status == .done || $0.status == .failed || $0.status == .cancelled || $0.status == .paused }) { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                for index in syncTasks.indices where syncTasks[index].kind == .upload && syncTasks[index].isSelected {
                    if case .skipped = syncTasks[index].status { failed = true; continue }
                    syncTasks[index].status = liveStatus(of: syncTasks[index])
                    if case .done = syncTasks[index].status {} else { failed = true }
                }
            }
        }

        // 4. Removals — last, and only when everything else succeeded.
        let removals = syncTasks.indices.filter { syncTasks[$0].kind == .delete && syncTasks[$0].isSelected }
        if !removals.isEmpty {
            if syncCancelRequested {
                for index in removals { syncTasks[index].status = .skipped("Cancelled") }
            } else if failed {
                for index in removals { syncTasks[index].status = .skipped("Skipped: an earlier step failed, so nothing is removed") }
            } else if let manager = managedFileManager {
                for index in removals {
                    if syncCancelRequested { syncTasks[index].status = .skipped("Cancelled"); continue }
                    syncTasks[index].status = .running
                    do {
                        try await manager.delete(item: identifier, remotePath: syncTasks[index].title)
                        overlay.recordRemoved(identifier: identifier, path: syncTasks[index].title)
                        refreshManagedFromOverlay()
                        syncTasks[index].status = .done
                    } catch {
                        syncTasks[index].status = .failed(error.localizedDescription)
                    }
                }
            }
        }
        if syncCancelRequested {
            for index in syncTasks.indices where syncTasks[index].status == .pending { syncTasks[index].status = .skipped("Cancelled") }
        }
        await checkSync()
    }

    // MARK: Deleting items

    /// Items hidden from My Items (deleted or dismissed).
    var hiddenItems: Set<String> { ViewMemory.shared.members("items.hidden") }

    func hideItem(_ identifier: String) {
        ViewMemory.shared.setMember("items.hidden", identifier, true)
        if route.identifier == identifier { route = .newItem }
    }

    /// Items being deleted in the background: identifier → progress.
    var itemDeletions: [String: ServerOperation] = [:]

    func unhideItem(_ identifier: String) {
        ViewMemory.shared.setMember("items.hidden", identifier, false)
    }

    /// Deletes items in the background. They leave My Items immediately;
    /// progress shows in the sidebar; a failure brings the item back.
    func deleteItems(_ identifiers: [String]) {
        for identifier in identifiers where itemDeletions[identifier] == nil {
            if route.identifier == identifier { route = .newItem }
            itemDeletions[identifier] = ServerOperation(title: identifier, done: 0, total: 0)
            Task { await deleteItemContents(identifier) }
        }
    }

    /// archive.org doesn't let uploaders delete an item itself. This deletes
    /// every file in it (4 at a time, with derivatives), and forgets its
    /// queue, link and history.
    func deleteItemContents(_ identifier: String) async {
        guard let credentials else { return }
        defer { itemDeletions[identifier] = nil }
        queue.remove(Set(queue.jobs.filter { $0.identifier == identifier }.map(\.id)))
        let files: [RemoteFile]
        do {
            files = try await archiveClient.fetchItemFiles(identifier).filter(\.isOriginal)
        } catch {
            unhideItem(identifier)
            banner = Banner(kind: .error, message: "Could not delete “\(identifier)”: \(error.localizedDescription)")
            return
        }
        itemDeletions[identifier]?.total = files.count
        let manager = ArchiveFileManager(credentials: credentials)
        manager.onRetry = { [weak self] message in
            Task { @MainActor in self?.itemDeletions[identifier]?.detail = message }
        }
        var failures = 0
        await withTaskGroup(of: (String, Bool).self) { group in
            var iterator = files.makeIterator()
            func addNext() -> Bool {
                guard let file = iterator.next() else { return false }
                group.addTask {
                    do { try await manager.delete(item: identifier, remotePath: file.name); return (file.name, true) }
                    catch { return (file.name, false) }
                }
                return true
            }
            for _ in 0..<4 { if !addNext() { break } }
            for await (path, ok) in group {
                if ok { overlay.recordRemoved(identifier: identifier, path: path) } else { failures += 1 }
                itemDeletions[identifier]?.done += 1
                _ = addNext()
            }
        }
        if failures > 0 {
            unhideItem(identifier)
            banner = Banner(kind: .error, message: "“\(identifier)”: \(failures) of \(files.count) files could not be deleted. It's back in My Items so you can try again.")
            return
        }
        linkedFolders[identifier] = nil
        history.remove(Set(history.records.filter { $0.identifier == identifier }.map(\.id)))
        myUploads.removeAll { $0.identifier == identifier }
        hideItem(identifier)   // only once everything is gone
        queue.appendLog("Deleted all \(files.count) files from “\(identifier)”.")
    }

    private static func itemMetadata(from raw: [String: Any], identifier: String) -> ItemMetadata {
        var metadata = ItemMetadata()
        metadata.identifier = identifier
        metadata.title = raw["title"] as? String ?? ""
        metadata.creator = (raw["creator"] as? String) ?? (raw["creator"] as? [String])?.joined(separator: "; ") ?? ""
        metadata.descriptionText = raw["description"] as? String ?? ""
        metadata.date = raw["date"] as? String ?? ""
        metadata.language = raw["language"] as? String ?? "eng"
        metadata.licenseURL = raw["licenseurl"] as? String ?? ""
        if let mediatype = raw["mediatype"] as? String, let type = Mediatype(rawValue: mediatype) {
            metadata.mediatype = type
        }
        if let subjects = raw["subject"] {
            if let array = subjects as? [String] { metadata.subjects = array }
            else if let single = subjects as? String {
                metadata.subjects = single.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        if let collections = raw["collection"] {
            if let array = collections as? [String] { metadata.collections = array.joined(separator: ", ") }
            else if let single = collections as? String { metadata.collections = single }
        }
        // Everything else that is a simple user field becomes an editable custom field.
        let reserved: Set<String> = [
            "identifier", "title", "creator", "description", "date", "language", "licenseurl", "mediatype", "subject",
            "collection", "uploader", "addeddate", "publicdate", "updatedate", "updater", "curation", "backup_location",
            "scanner", "ppi", "repub_state", "access-restricted-item", "is_dark", "noindex", "boxid", "boxid_2",
            "notes_from_uploader", "sponsor", "contributor_old", "identifier-access", "identifier-ark", "ocr", "scandate", "imagecount"
        ]
        for key in raw.keys.sorted() where !reserved.contains(key) {
            if let value = raw[key] as? String {
                metadata.customFields.append(CustomMetadataField(key: key, value: value))
            }
        }
        return metadata
    }

    // MARK: - Helpers

    private func registerUndo(_ actionName: String, _ undo: @escaping () -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { _ in undo() }
        undoManager.setActionName(actionName)
    }
}

/// Thread-safe holder for progress text written by a background task.
final class SyncProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var text: String? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ text: String) { lock.lock(); value = text; lock.unlock() }
}
