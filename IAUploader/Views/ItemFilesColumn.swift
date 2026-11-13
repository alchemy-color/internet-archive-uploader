import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The "Files" column of an existing item: its folder tree on archive.org,
/// with the linked Finder folder's pending changes overlaid (like git status).
struct ItemFilesColumn: View {
    @Environment(AppModel.self) private var model
    @State private var newFolderParent: String?
    @State private var renaming: TreeNode?
    @State private var moving: Set<String>?
    @State private var confirmDelete: Set<String>?
    @State private var showSyncReview = false
    @State private var showLinkSheet = false
    @State private var dropTargetFolder: String?
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(title: "Files", subtitle: subtitle, systemImage: "folder") {
                Button { newFolderParent = targetFolder } label: { Image(systemName: "folder.badge.plus") }
                    .help("New folder")
                Menu {
                    // Destinations are always explicit, so nothing lands in a
                    // folder just because it happened to be selected.
                    Section("Item root") {
                        Button("Upload Files to Item Root…") { upload(FilePicker.chooseFiles(), into: "") }
                        Button("Upload Folder to Item Root…") { upload(FilePicker.chooseFolders(), into: "") }
                    }
                    if !selectedFolderOnly.isEmpty {
                        Section("Into “\(selectedFolderOnly)”") {
                            Button("Upload Files into “\((selectedFolderOnly as NSString).lastPathComponent)”…") { upload(FilePicker.chooseFiles(), into: selectedFolderOnly) }
                            Button("Upload Folder into “\((selectedFolderOnly as NSString).lastPathComponent)”…") { upload(FilePicker.chooseFolders(), into: selectedFolderOnly) }
                        }
                    }
                } label: { Image(systemName: "square.and.arrow.up") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Upload files or folders")
                Menu {
                    Toggle("Show Only Changes", isOn: Binding(get: { model.showOnlyChanges }, set: { model.showOnlyChanges = $0 }))
                        .disabled(model.syncPlan == nil)
                    Toggle("Show Files archive.org Generated", isOn: Binding(get: { model.showDerivedFiles }, set: { model.showDerivedFiles = $0 }))
                    Divider()
                    Button("Expand All") { ViewMemory.shared.replaceMembers(model.manageExpandedKey, Set(model.managedFolderPaths)) }
                    Button("Collapse All") { ViewMemory.shared.replaceMembers(model.manageExpandedKey, []) }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("View options")
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh from archive.org")
                    .disabled(model.isLoadingManagedItem || model.isCheckingSync)
            }
            SyncBar(showLinkSheet: $showLinkSheet, showSyncReview: $showSyncReview)
            ArchiveTasksBar()
            if let operation = model.serverOperation {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: Double(operation.done), total: Double(max(operation.total, 1))) {
                        Text("\(operation.title) \(operation.done) of \(operation.total)").font(.caption)
                    }
                    if let detail = operation.detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            if let error = model.managedItemError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { model.managedItemError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1))
            }
            tree
            footer
        }
        .sheet(item: Binding(get: { newFolderParent.map { IdentifiedString(value: $0) } }, set: { newFolderParent = $0?.value })) { parent in
            NameSheet(
                title: parent.value.isEmpty ? "New folder" : "New folder in “\(parent.value)”",
                message: "archive.org has no empty folders. The folder appears here and is created on archive.org when you upload or move files into it.",
                actionTitle: "Create",
                initial: "New Folder"
            ) { model.createManagedFolder(named: $0, inside: parent.value) }
        }
        .sheet(item: $renaming) { node in
            NameSheet(
                title: "Rename “\(node.name)”",
                message: node.isFolder && node.fileCount > 0 ? "Renames \(node.fileCount) file\(node.fileCount == 1 ? "" : "s") on archive.org." : nil,
                actionTitle: "Rename",
                initial: node.name
            ) { name in Task { await model.renameManagedNode(node.id, to: name) } }
        }
        .sheet(item: Binding(get: { moving.map { IdentifiedSet(value: $0) } }, set: { moving = $0?.value })) { ids in
            MoveSheet(title: "Move \(ids.value.count) item\(ids.value.count == 1 ? "" : "s") to…", folders: model.managedFolderPaths) { destination in
                Task { await model.moveManagedNodes(ids.value, to: destination) }
                if !destination.isEmpty { ViewMemory.shared.setMember(model.manageExpandedKey, destination, true) }
            }
        }
        .onChange(of: showSyncReview) { _, show in
            // "Review & Sync" puts the ordered task list in the Upload column.
            guard show else { return }
            if !model.isApplyingSync { model.prepareSyncTasks(includeRemovals: model.syncIncludeRemovals) }
            showSyncReview = false
        }
        .sheet(isPresented: $showLinkSheet) { LinkFolderSheet() }
        .confirmationDialog(
            "Delete from archive.org?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
        ) {
            Button("Delete \(model.remotePaths(forNodeIDs: confirmDelete ?? []).count) File(s)", role: .destructive) {
                if let ids = confirmDelete { Task { await model.deleteManagedNodes(ids) } }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("This permanently removes the selected files (and everything inside selected folders) from “\(model.managedIdentifier)”.")
        }
    }

    private var subtitle: String {
        let originals = model.managedFiles.filter(\.isOriginal)
        var text = "\(originals.count) files · \(ByteCountFormatter.shortString(originals.reduce(0) { $0 + ($1.size ?? 0) }))"
        if !model.managedPending.isEmpty { text += " · \(model.managedPending.count) processing" }
        return text
    }

    private func refresh() async {
        await model.loadManagedItem()
        if model.linkedFolder != nil { await model.checkSync() }
    }

    private var targetFolder: String {
        guard model.manageSelection.count == 1, let id = model.manageSelection.first else { return "" }
        if let folder = TreeNode.folderPath(fromID: id) { return folder }
        if let path = TreeNode.fileKey(fromID: id) { return RemotePath.parent(of: path) }
        return ""
    }

    /// The selected folder, only when exactly one folder is selected.
    private var selectedFolderOnly: String {
        guard model.manageSelection.count == 1, let id = model.manageSelection.first else { return "" }
        return TreeNode.folderPath(fromID: id) ?? ""
    }

    private func upload(_ urls: [URL], into folder: String) {
        guard !urls.isEmpty else { return }
        let destination = folder
        if !destination.isEmpty { ViewMemory.shared.setMember(model.manageExpandedKey, destination, true) }
        Task { await model.uploadToManagedItem(urls, folder: destination) }
    }

    // MARK: Tree

    private var displayedTree: [TreeNode] {
        let tree = model.managedTree
        guard !filter.isEmpty else { return tree }
        func prune(_ nodes: [TreeNode]) -> [TreeNode] {
            nodes.compactMap { node in
                if node.isFolder {
                    var copy = node
                    copy.children = prune(node.children)
                    return copy.children.isEmpty && !node.name.localizedCaseInsensitiveContains(filter) ? nil : copy
                }
                return node.path.localizedCaseInsensitiveContains(filter) ? node : nil
            }
        }
        return prune(tree)
    }

    private var tree: some View {
        let nodes = displayedTree
        return List(selection: Binding(get: { model.manageSelection }, set: { model.manageSelection = $0 })) {
            TreeOutline(nodes: nodes, expansionKey: model.manageExpandedKey) { node in
                TreeRowLabel(node: node, secondary: node.note, isDropTarget: dropTargetFolder == node.path)
                    .onDrag { TreeDrop.provider(for: model.manageSelection.contains(node.id) ? model.manageSelection : [node.id]) }
                    .onDrop(of: [UTType.fileURL, UTType.plainText], isTargeted: Binding(
                        get: { dropTargetFolder == node.path },
                        set: { dropTargetFolder = $0 ? node.path : (dropTargetFolder == node.path ? nil : dropTargetFolder) }
                    )) { providers in
                        let folder = node.isFolder ? node.path : RemotePath.parent(of: node.path)
                        return TreeDrop.handle(providers, onFiles: { upload($0, into: folder) }, onNodes: { ids in
                            let moving = Set(ids).filter { id in
                                let path = TreeNode.folderPath(fromID: id) ?? TreeNode.fileKey(fromID: id) ?? ""
                                return path != folder && RemotePath.parent(of: path) != folder
                            }
                            guard !moving.isEmpty else { return }
                            Task { await model.moveManagedNodes(moving, to: folder) }
                        })
                    }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids, nodes: nodes)
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first, let node = FileTreeBuilder.find(id, in: nodes) else { return }
            if node.isFolder {
                ViewMemory.shared.setMember(model.manageExpandedKey, node.path, !ViewMemory.shared.contains(model.manageExpandedKey, node.path))
            } else if let url = URL(string: "https://archive.org/download/\(model.managedIdentifier)/\(RemotePath.encoded(node.path))") {
                FilePicker.open(url)
            }
        }
        .onDeleteCommand {
            if !model.manageSelection.isEmpty { confirmDelete = model.manageSelection }
        }
        .onDrop(of: [UTType.fileURL, UTType.plainText], isTargeted: nil) { providers in
            TreeDrop.handle(providers, onFiles: { upload($0, into: "") }, onNodes: { ids in
                Task { await model.moveManagedNodes(Set(ids), to: "") }
            })
        }
        .overlay {
            if model.isLoadingManagedItem && model.managedFiles.isEmpty {
                ProgressView("Loading item…")
            } else if nodes.isEmpty && !model.isLoadingManagedItem {
                EmptyState(symbol: "tray", title: model.showOnlyChanges ? "No changes" : "No files yet", message: "Drop files or folders here to upload them into this item.")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<String>, nodes: [TreeNode]) -> some View {
        if ids.isEmpty {
            Button("New Folder…") { newFolderParent = "" }
            Button("Upload Files…") { upload(FilePicker.chooseFiles(), into: "") }
            Button("Upload Folder…") { upload(FilePicker.chooseFolders(), into: "") }
        } else {
            let single = ids.count == 1 ? ids.first.flatMap { FileTreeBuilder.find($0, in: nodes) } : nil
            if let node = single, node.isFolder {
                Button("New Subfolder…") { newFolderParent = node.path }
                Button("Upload Files Here…") { upload(FilePicker.chooseFiles(), into: node.path) }
                Button("Upload Folder Here…") { upload(FilePicker.chooseFolders(), into: node.path) }
                Divider()
            }
            if let node = single { Button("Rename…") { renaming = node } }
            Button("Move to…") { moving = ids }
            Button("Move to Item Root") { Task { await model.moveManagedNodes(ids, to: "") } }
            Divider()
            Button("Download…") { download(ids) }
            if let node = single, !node.isFolder {
                Button("Open in Browser") {
                    if let url = URL(string: "https://archive.org/download/\(model.managedIdentifier)/\(RemotePath.encoded(node.path))") { FilePicker.open(url) }
                }
            }
            Button("Copy Path") {
                FilePicker.copyToPasteboard(ids.compactMap { TreeNode.folderPath(fromID: $0) ?? TreeNode.fileKey(fromID: $0) }.joined(separator: "\n"))
            }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete = ids }
        }
    }

    private func download(_ ids: Set<String>) {
        let panel = NSOpenPanel()
        panel.title = "Choose a download folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.downloadManagedNodes(ids, to: url) }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter", text: $filter).textFieldStyle(.plain)
            Spacer()
            if !model.manageSelection.isEmpty {
                Text("\(model.manageSelection.count) selected").foregroundStyle(.secondary)
                Button("Rename") {
                    if let id = model.manageSelection.first, let node = FileTreeBuilder.find(id, in: model.managedTree) { renaming = node }
                }
                .disabled(model.manageSelection.count != 1)
                Button("Move") { moving = model.manageSelection }
                Button("Download") { download(model.manageSelection) }
                Button("Delete", role: .destructive) { confirmDelete = model.manageSelection }
            }
        }
        .font(UIScale.font(12))
        .buttonStyle(.borderless)
        .disabled(model.serverOperation != nil)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Sync bar

/// One line under the Files header: which Finder folder the item follows,
/// and how far apart they are.
private struct SyncBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showLinkSheet: Bool
    @Binding var showSyncReview: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let link = model.linkedFolder {
                    Image(systemName: "link")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.displayPath)
                            .font(UIScale.font(12, .medium))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(status)
                            .font(UIScale.font(11.5))
                            .foregroundStyle(statusColor)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if model.isApplyingSync {
                        Button("Stop", role: .destructive) { model.cancelSync() }
                            .disabled(model.syncCancelRequested)
                    } else if model.isCheckingSync {
                        ProgressView().controlSize(.small)
                            .help("The first check of a large folder reads every file once to compare checksums. Later checks use a cache and are fast.")
                    } else if let plan = model.syncPlan, !plan.isInSync {
                        Button(model.hasSyncTasksForCurrentItem ? "Rebuild Tasks" : "Review & Sync") { showSyncReview = true }
                            .buttonStyle(.borderedProminent)
                            .help("List the sync steps in the Upload column")
                    } else {
                        Button("Check") { Task { await model.checkSync() } }
                    }
                    Menu {
                        Button("Check Again") { Task { await model.checkSync() } }
                        Button("Show in Finder") { FilePicker.revealInFinder(link.localURL) }
                        Button("Change Link…") { showLinkSheet = true }
                        Divider()
                        Button("Unlink Folder") { model.unlinkFolder() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    Image(systemName: "link.badge.plus").foregroundStyle(.secondary)
                    Text("Link a Finder folder to keep this item in sync with it.")
                        .font(UIScale.font(12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Link Folder…") { showLinkSheet = true }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
        }
        .background(Color.accentColor.opacity(model.linkedFolder == nil ? 0 : 0.05))
    }

    private var status: String {
        if let message = model.syncMessage { return message }
        if model.isApplyingSync { return "Syncing — \(model.syncProgress.done) of \(model.syncProgress.total) tasks done" }
        guard let link = model.linkedFolder, let plan = model.syncPlan else { return "Not checked yet" }
        let target = link.remoteFolder.isEmpty ? "item root" : link.remoteFolder
        if plan.isInSync { return "In sync with \(target) · \(plan.unchanged) files" }
        var parts: [String] = []
        if !plan.uploads.isEmpty { parts.append("\(plan.uploads.count) new") }
        if !plan.updates.isEmpty { parts.append("\(plan.updates.count) changed") }
        if !plan.moves.isEmpty { parts.append("\(plan.moves.count) moved") }
        if !plan.removals.isEmpty { parts.append("\(plan.removals.count) not in Finder") }
        return parts.joined(separator: " · ") + " → \(target)"
    }

    private var statusColor: Color {
        if model.syncMessage != nil { return .secondary }
        guard let plan = model.syncPlan else { return .secondary }
        return plan.isInSync ? .green : .orange
    }
}

// MARK: - Link folder

private struct LinkFolderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var remoteFolder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Link a Finder folder").font(.title3.weight(.semibold))
            Text("The Finder folder is the reference. The app compares it with the item and shows what to upload, move, or remove so archive.org matches it exactly.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen")
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Choose…", action: choose)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Mirror it into").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Mirror into", selection: $remoteFolder) {
                    Text("The item root").tag("")
                    if let folder, !model.managedFolderPaths.contains(folderName(folder)) {
                        Text("A folder named “\(folderName(folder))”").tag(folderName(folder))
                    }
                    ForEach(model.managedFolderPaths, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Text(remoteFolder.isEmpty
                     ? "The folder's contents become the item's contents."
                     : "The folder's contents go inside “\(remoteFolder)”. Other folders in the item are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Link & Compare") {
                    if let folder { model.linkFolder(folder, remoteFolder: remoteFolder) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(folder == nil)
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear {
            if let link = model.linkedFolder {
                folder = link.localURL
                remoteFolder = link.remoteFolder
            }
        }
    }

    private func folderName(_ url: URL) -> String {
        model.settings.sanitizeFileNames ? RemotePath.sanitizedComponent(url.lastPathComponent) : url.lastPathComponent
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Link"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        // Guess: if the item already has a top folder with that name, mirror into it.
        let name = folderName(url)
        let topFolders = Set(model.managedFolderPaths.filter { !$0.contains("/") })
        remoteFolder = topFolders.contains(name) ? name : ""
    }
}


// MARK: - archive.org task queue

/// What archive.org itself still has to do for this item. Changes appear on
/// the item page only after these tasks finish.
private struct ArchiveTasksBar: View {
    @Environment(AppModel.self) private var model
    @State private var showDetails = false

    var body: some View {
        if let status = model.itemTaskStatus, status.pending > 0 {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: status.needsAttention ? "exclamationmark.triangle.fill" : "gearshape.2")
                        .foregroundStyle(status.needsAttention ? Color.orange : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(headline(status)).font(UIScale.font(12, .medium))
                        Text(detail(status)).font(UIScale.font(11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button("Details") { showDetails = true }
                    Button {
                        Task { await model.refreshItemTasks() }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .help("Check archive.org's task queue again")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                Divider()
            }
            .background((status.needsAttention ? Color.orange : Color.secondary).opacity(0.07))
            .sheet(isPresented: $showDetails) { ArchiveTasksSheet(status: status) }
        }
    }

    private func headline(_ s: ItemTaskStatus) -> String {
        var parts: [String] = []
        if s.running > 0 { parts.append("\(s.running) running") }
        if s.queued > 0 { parts.append("\(s.queued) waiting") }
        if s.paused > 0 { parts.append("\(s.paused) paused") }
        if s.error > 0 { parts.append("\(s.error) failed") }
        return "archive.org is processing: " + parts.joined(separator: " · ")
    }

    private func detail(_ s: ItemTaskStatus) -> String {
        if s.paused > 0 {
            return "archive.org paused some tasks for review by their staff. Later tasks wait behind them, so the item page won't update until they're released."
        }
        if s.error > 0 { return "Some tasks failed on archive.org's side. Their staff usually retry them." }
        return "The item page updates as these finish. This can take minutes to hours."
    }
}

private struct ArchiveTasksSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let status: ItemTaskStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("archive.org tasks for \(model.managedIdentifier)").font(.title3.weight(.semibold))
            Text("These run one at a time on archive.org's servers. A paused task blocks the ones after it until archive.org staff release it. If tasks stay paused for a long time, email info@archive.org with the item identifier.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(status.tasks) { task in
                HStack {
                    Text(task.state.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(task.state == "paused" || task.state == "error" ? .orange : .secondary)
                        .frame(width: 64, alignment: .leading)
                    Text(task.description).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(task.submitted?.prefix(16) ?? "").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack {
                Link("Open task history on archive.org", destination: URL(string: "https://archive.org/history/\(model.managedIdentifier)")!)
                Spacer()
                Button("Copy Email Text") {
                    FilePicker.copyToPasteboard("Hello, some tasks on my item \(model.managedIdentifier) have been paused (\(status.paused) paused). Could you please release them? Thank you.")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 680, height: 520)
    }
}
