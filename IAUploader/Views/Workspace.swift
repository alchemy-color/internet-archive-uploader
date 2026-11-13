import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Layout

/// Header shared by the three columns so they line up and read the same.
struct ColumnHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(UIScale.font(14, .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: UIScale.size(28), height: UIScale.size(28))
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(UIScale.font(15, .bold))
                    if let subtitle {
                        Text(subtitle)
                            .font(UIScale.font(11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                trailing
                    .buttonStyle(.borderless)
                    .font(UIScale.font(14))
                    .imageScale(.large)
            }
            .padding(.horizontal, 12)
            .frame(height: UIScale.size(54))
            Divider()
        }
        .background(.bar)
    }
}

extension ColumnHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}

/// Three columns with draggable dividers. Widths are remembered.
struct ThreeColumns<Left: View, Center: View, Right: View>: View {
    @ViewBuilder var left: Left
    @ViewBuilder var center: Center
    @ViewBuilder var right: Right

    @State private var dragStartLeft: CGFloat?
    @State private var dragStartRight: CGFloat?

    private var memory: ViewMemory { ViewMemory.shared }
    private var storedLeft: CGFloat { CGFloat(Double(memory.string("layout.leftWidth", default: "340")) ?? 340) }
    private var storedRight: CGFloat { CGFloat(Double(memory.string("layout.rightWidth", default: "330")) ?? 330) }

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let leftWidth = min(max(storedLeft, 260), max(260, total * 0.45))
            let rightWidth = min(max(storedRight, 240), max(240, total - leftWidth - 340))
            HStack(spacing: 0) {
                left.frame(width: leftWidth)
                SplitHandle { translation in
                    if dragStartLeft == nil { dragStartLeft = leftWidth }
                    memory.setString("layout.leftWidth", String(Double(dragStartLeft! + translation)))
                } onEnd: { dragStartLeft = nil }
                center.frame(maxWidth: .infinity)
                SplitHandle { translation in
                    if dragStartRight == nil { dragStartRight = rightWidth }
                    memory.setString("layout.rightWidth", String(Double(dragStartRight! - translation)))
                } onEnd: { dragStartRight = nil }
                right.frame(width: rightWidth)
            }
        }
    }
}

private struct SplitHandle: View {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(hovering ? Color.accentColor.opacity(0.5) : Color.clear)
                    .frame(width: 3)
            )
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .padding(.horizontal, -3)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.width) }
                    .onEnded { _ in onEnd() }
            )
            .help("Drag to resize")
    }
}

// MARK: - Workspace

/// Archive Entry | Files | Upload — the same three columns for a new item
/// and for an existing one.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ThreeColumns {
            Group {
                if model.route == .newItem { NewEntryColumn() } else { ItemEntryColumn() }
            }
        } center: {
            Group {
                if model.route == .newItem { NewItemFilesColumn() } else { ItemFilesColumn() }
            }
        } right: {
            UploadColumn()
        }
    }
}

// MARK: - New item: Archive Entry

private struct NewEntryColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(title: "Archive Entry", subtitle: "New item", systemImage: "doc.text") {
                Button("Clear") { model.clearNewItem() }
                    .help("Start over with an empty form")
            }
            NewEntryForm()
        }
    }
}

// MARK: - New item: Files

private struct NewItemFilesColumn: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false
    @State private var dropTargetFolder: String?
    @State private var newFolderParent: String?
    @State private var renaming: TreeNode?
    @State private var moving: Set<String>?

    private let expansionKey = "files.expanded"

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 0) {
            ColumnHeader(title: "Files", subtitle: subtitle, systemImage: "folder") {
                Button { newFolderParent = selectedFolder } label: { Image(systemName: "folder.badge.plus") }
                    .help("New folder")
                Button { model.presentFilePicker(intoFolder: selectedFolder) } label: { Image(systemName: "doc.badge.plus") }
                    .help("Add files")
                Button { model.presentFolderPicker(intoFolder: selectedFolder) } label: { Image(systemName: "plus.rectangle.on.folder") }
                    .help("Add a folder")
                Menu {
                    Toggle("Keep the dropped folder's name", isOn: $settings.keepTopFolder)
                    Toggle("Make file names web-safe", isOn: $settings.sanitizeFileNames)
                    Toggle("Include hidden files", isOn: $settings.includeHiddenFiles)
                    Divider()
                    Button("Remove All Files", role: .destructive) { model.clearFiles() }
                        .disabled(model.files.isEmpty && model.planFolders.isEmpty)
                } label: { Image(systemName: "slider.horizontal.3") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Options")
            }
            if model.files.isEmpty && model.planFolders.isEmpty {
                dropZone
            } else {
                tree
                footer
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            TreeDrop.handle(providers, onFiles: { model.addFiles($0) }, onNodes: { model.moveFileNodes(Set($0), to: "") })
        }
        .sheet(item: Binding(get: { newFolderParent.map { IdentifiedString(value: $0) } }, set: { newFolderParent = $0?.value })) { parent in
            NameSheet(
                title: parent.value.isEmpty ? "New folder" : "New folder in “\(parent.value)”",
                message: "Empty folders aren't uploaded. Add or drag files into it.",
                actionTitle: "Create",
                initial: "New Folder"
            ) { name in
                model.createPlanFolder(named: name, inside: parent.value)
                if !parent.value.isEmpty { ViewMemory.shared.setMember(expansionKey, parent.value, true) }
            }
        }
        .sheet(item: $renaming) { node in
            NameSheet(title: "Rename “\(node.name)”", actionTitle: "Rename", initial: node.name) { model.renameFileNode(node.id, to: $0) }
        }
        .sheet(item: Binding(get: { moving.map { IdentifiedSet(value: $0) } }, set: { moving = $0?.value })) { ids in
            MoveSheet(title: "Move \(ids.value.count) item\(ids.value.count == 1 ? "" : "s") to…", folders: model.planFolderPaths) { destination in
                model.moveFileNodes(ids.value, to: destination)
                if !destination.isEmpty { ViewMemory.shared.setMember(expansionKey, destination, true) }
            }
        }
    }

    private var subtitle: String {
        guard !model.files.isEmpty else { return "Nothing added yet" }
        return "\(model.files.count) file\(model.files.count == 1 ? "" : "s") · \(ByteCountFormatter.shortString(model.totalBytes))"
    }

    private var selectedFolder: String {
        guard model.fileSelection.count == 1, let id = model.fileSelection.first else { return "" }
        if let folder = TreeNode.folderPath(fromID: id) { return folder }
        if let key = TreeNode.fileKey(fromID: id), let file = model.files.first(where: { $0.id.uuidString == key }) {
            return RemotePath.parent(of: file.rawRelativePath)
        }
        return ""
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "folder.badge.plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text("Drop a folder or files here")
                .font(.title3.weight(.semibold))
            Text("Folders keep their structure. Drop a single folder and the item stays linked to it, so you can sync later changes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack {
                Button("Add Folder…") { model.presentFolderPicker() }
                    .buttonStyle(.borderedProminent)
                Button("Add Files…") { model.presentFilePicker() }
            }
            .controlSize(.large)
            if model.isScanning { ProgressView("Reading files…").controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .padding(16)
        )
    }

    private var tree: some View {
        let nodes = model.fileTree
        return List(selection: Binding(get: { model.fileSelection }, set: { model.fileSelection = $0 })) {
            TreeOutline(nodes: nodes, expansionKey: expansionKey) { node in
                row(node)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids, nodes: nodes)
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first, let node = FileTreeBuilder.find(id, in: nodes) else { return }
            if node.isFolder {
                ViewMemory.shared.setMember(expansionKey, node.path, !ViewMemory.shared.contains(expansionKey, node.path))
            } else {
                renaming = node
            }
        }
        .onDeleteCommand { model.removeFileNodes(model.fileSelection) }
        .overlay(alignment: .bottom) {
            if model.isScanning { ProgressView("Reading files…").controlSize(.small).padding(8).background(.regularMaterial, in: Capsule()).padding() }
        }
    }

    private func row(_ node: TreeNode) -> some View {
        let secondary: String? = {
            guard !node.isFolder, let key = TreeNode.fileKey(fromID: node.id),
                  let file = model.files.first(where: { $0.id.uuidString == key }) else { return nil }
            let planned = model.plannedRemotePath(for: file)
            return planned == file.rawRelativePath ? nil : "uploads as \(planned)"
        }()
        return TreeRowLabel(node: node, secondary: secondary, isDropTarget: dropTargetFolder == node.path && node.isFolder)
            .onDrag { TreeDrop.provider(for: model.fileSelection.contains(node.id) ? model.fileSelection : [node.id]) }
            .onDrop(of: [UTType.fileURL, UTType.plainText], isTargeted: Binding(
                get: { dropTargetFolder == node.path },
                set: { dropTargetFolder = $0 ? node.path : (dropTargetFolder == node.path ? nil : dropTargetFolder) }
            )) { providers in
                let folder = node.isFolder ? node.path : RemotePath.parent(of: node.path)
                return TreeDrop.handle(providers, onFiles: { model.addFiles($0, intoFolder: folder) }, onNodes: { ids in
                    model.moveFileNodes(Set(ids), to: folder)
                    if !folder.isEmpty { ViewMemory.shared.setMember(expansionKey, folder, true) }
                })
            }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<String>, nodes: [TreeNode]) -> some View {
        if ids.isEmpty {
            Button("New Folder…") { newFolderParent = "" }
            Button("Add Files…") { model.presentFilePicker() }
            Button("Add Folder…") { model.presentFolderPicker() }
        } else {
            let single = ids.count == 1 ? ids.first.flatMap { FileTreeBuilder.find($0, in: nodes) } : nil
            if let node = single, node.isFolder {
                Button("New Subfolder…") { newFolderParent = node.path }
                Button("Add Files Here…") { model.presentFilePicker(intoFolder: node.path) }
                Button("Add Folder Here…") { model.presentFolderPicker(intoFolder: node.path) }
                Divider()
            }
            if let node = single { Button("Rename…") { renaming = node } }
            Button("Move to…") { moving = ids }
            Button("Move to Item Root") { model.moveFileNodes(ids, to: "") }
            if let node = single, !node.isFolder, let key = TreeNode.fileKey(fromID: node.id),
               let file = model.files.first(where: { $0.id.uuidString == key }) {
                Divider()
                Button("Show in Finder") { FilePicker.revealInFinder(file.url) }
            }
            Divider()
            Button("Remove", role: .destructive) { model.removeFileNodes(ids) }
        }
    }

    private var footer: some View {
        HStack {
            Text("Drag to move · Double-click to rename · Delete to remove")
            Spacer()
        }
        .font(UIScale.font(11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - New item: create card (top of the Upload column)

struct CreateItemCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            check("Title", ok: !model.metadata.title.trimmingCharacters(in: .whitespaces).isEmpty)
            check("Identifier available", ok: IdentifierRules.issue(for: model.metadata.identifier) == nil && model.identifierCheck != .taken, pending: model.identifierCheck == .checking)
            check("Description", ok: !model.metadata.descriptionText.trimmingCharacters(in: .whitespaces).isEmpty)
            check("At least one subject", ok: !model.metadata.parsedSubjects.isEmpty)
            check(model.files.isEmpty ? "Files" : "\(model.files.count) files · \(ByteCountFormatter.shortString(model.totalBytes))", ok: !model.files.isEmpty)
            if let blocker = model.uploadBlocker {
                Text(blocker).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.startUpload()
            } label: {
                HStack {
                    if model.isPreparingUpload { ProgressView().controlSize(.small) }
                    Text(model.isPreparingUpload ? "Checking archive.org…" : "Create Item & Upload")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canStartUpload)
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
        .padding(10)
    }

    private func check(_ label: String, ok: Bool, pending: Bool = false) -> some View {
        HStack(spacing: 6) {
            if pending {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(ok ? .green : .secondary)
            }
            Text(label).font(UIScale.font(13)).foregroundStyle(ok ? .primary : .secondary)
        }
    }
}

// MARK: - Existing item: Archive Entry

private struct ItemEntryColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ColumnHeader(title: "Archive Entry", subtitle: model.managedIdentifier, systemImage: "doc.text") {
                Button {
                    if let url = model.itemURL { FilePicker.open(url) }
                } label: { Image(systemName: "safari") }
                .help("Open the item page on archive.org")
                Button {
                    if let url = model.itemURL { FilePicker.copyToPasteboard(url.absoluteString) }
                } label: { Image(systemName: "link") }
                .help("Copy the item link")
            }
            if model.isLoadingManagedItem && model.managedMetadata.title.isEmpty {
                ProgressView("Loading…").frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    editor.padding(12)
                }
                Divider()
                HStack {
                    if model.managedMetadataIsDirty {
                        Label("Unsaved changes", systemImage: "circle.fill").font(.caption).foregroundStyle(.orange).labelStyle(.titleOnly)
                    }
                    Spacer()
                    Button("Revert") { model.revertManagedMetadata() }
                        .disabled(!model.managedMetadataIsDirty)
                    Button {
                        Task { await model.saveManagedMetadata() }
                    } label: {
                        if model.isSavingMetadata { ProgressView().controlSize(.small) } else { Text("Save") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.managedMetadataIsDirty || model.isSavingMetadata)
                    .keyboardShortcut("s", modifiers: .command)
                }
                .controlSize(.small)
                .padding(10)
                .background(.bar)
            }
        }
    }

    private var editor: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            field("Title") { TextField("Title", text: $model.managedMetadata.title).textFieldStyle(.roundedBorder).font(.title3) }
            field("Description") {
                DescriptionEditor(text: $model.managedMetadata.descriptionText, minHeight: 140, maxHeight: 320)
            }
            field("Subjects") { SubjectsEditor(subjects: $model.managedMetadata.subjects) }
            field("Creator") { TextField("Creator", text: $model.managedMetadata.creator).textFieldStyle(.roundedBorder) }
            HStack(alignment: .top) {
                field("Date") { TextField("YYYY-MM-DD", text: $model.managedMetadata.date).textFieldStyle(.roundedBorder) }
                field("Language") { TextField("eng", text: $model.managedMetadata.language).textFieldStyle(.roundedBorder) }
                    .frame(width: 80)
            }
            field("License URL") { TextField("https://creativecommons.org/…", text: $model.managedMetadata.licenseURL).textFieldStyle(.roundedBorder) }
            field("Type and collection") {
                HStack(spacing: 6) {
                    StatusPill(text: model.managedMetadata.mediatype.title, systemImage: model.managedMetadata.mediatype.symbol)
                    if !model.managedMetadata.collections.isEmpty {
                        StatusPill(text: model.managedMetadata.collections, systemImage: "rectangle.stack")
                    }
                }
                .help("archive.org doesn't allow changing these after the item is created.")
            }
            Divider()
            HStack {
                Text("Other fields").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.managedMetadata.customFields.append(CustomMetadataField())
                } label: { Label("Add", systemImage: "plus") }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            ForEach($model.managedMetadata.customFields) { $field in
                HStack(spacing: 4) {
                    TextField("key", text: $field.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 100)
                    TextField("value", text: $field.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button {
                        model.managedMetadata.customFields.removeAll { $0.id == field.id }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove this field")
                }
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Small wrappers so optional values can drive `.sheet(item:)`.
struct IdentifiedString: Identifiable { let value: String; var id: String { value } }
struct IdentifiedSet: Identifiable { let value: Set<String>; var id: String { value.sorted().joined(separator: "|") } }
