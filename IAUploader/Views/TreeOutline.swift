import SwiftUI
import UniformTypeIdentifiers

/// Recursive outline for `TreeNode`s inside a `List`. Which folders are
/// expanded is stored in `ViewMemory`, so it survives tab switches,
/// refreshes, and relaunches.
struct TreeOutline<Row: View>: View {
    let nodes: [TreeNode]
    let expansionKey: String
    let row: (TreeNode) -> Row

    init(nodes: [TreeNode], expansionKey: String, @ViewBuilder row: @escaping (TreeNode) -> Row) {
        self.nodes = nodes
        self.expansionKey = expansionKey
        self.row = row
    }

    var body: some View {
        ForEach(nodes) { node in
            if node.isFolder {
                DisclosureGroup(isExpanded: ViewMemory.shared.memberBinding(expansionKey, node.path)) {
                    TreeOutline(nodes: node.children, expansionKey: expansionKey, row: row)
                } label: {
                    row(node)
                }
                .tag(node.id)
            } else {
                row(node)
                    .tag(node.id)
            }
        }
    }
}

/// Standard label for a tree row.
struct TreeRowLabel: View {
    let node: TreeNode
    var secondary: String?
    var isDropTarget = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(UIScale.font(14))
                .foregroundStyle(node.isFolder ? Color.accentColor : .secondary)
                .frame(width: UIScale.size(20))
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(UIScale.font(13, node.isFolder ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(node.badge == .movedAway || node.badge == .removing)
                    .foregroundStyle(node.badge == .movedAway || node.badge == .removing ? .secondary : .primary)
                if let secondary {
                    Text(secondary)
                        .font(UIScale.font(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if let badge = node.badge {
                badgeView(badge)
            }
            if node.isFolder && node.changeCount > 0 {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                    .help("\(node.changeCount) change\(node.changeCount == 1 ? "" : "s") inside")
            }
            if node.isFolder {
                Text("\(node.fileCount)")
                    .font(UIScale.font(11, .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            Text(node.totalBytes > 0 ? ByteCountFormatter.shortString(node.totalBytes) : "")
                .font(UIScale.font(12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: UIScale.size(60), alignment: .trailing)
        }
        .padding(.vertical, UIScale.size(2.5))
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor, lineWidth: isDropTarget ? 2 : 0)
        )
    }

    private var icon: String {
        if node.isFolder { return node.badge == .emptyFolder ? "folder.badge.plus" : "folder.fill" }
        return "doc"
    }

    @ViewBuilder
    private func badgeView(_ badge: TreeNode.Badge) -> some View {
        switch badge {
        case .processing:
            StatusPill(text: "Processing", color: .orange, systemImage: "clock")
                .help("Changed by this app. archive.org hasn't finished processing it yet.")
        case .queued:
            StatusPill(text: "Queued", color: .blue, systemImage: "arrow.up.circle")
        case .emptyFolder:
            StatusPill(text: "Empty", color: .secondary)
                .help("archive.org has no empty folders. This folder is created when you upload into it.")
        case .added:
            StatusPill(text: "New", color: .green, systemImage: "plus")
                .help("In Finder, not on archive.org yet. Sync uploads it.")
        case .modified:
            StatusPill(text: "Changed", color: .orange, systemImage: "pencil")
                .help("Different in Finder. Sync replaces it.")
        case .movedHere:
            StatusPill(text: "Moved", color: .blue, systemImage: "arrow.right")
                .help("Sync moves it here on archive.org (no re-upload).")
        case .movedAway:
            StatusPill(text: "Moving", color: .blue, systemImage: "arrow.right")
        case .removing:
            StatusPill(text: "Not in Finder", color: .red, systemImage: "minus")
                .help("Sync removes it from archive.org.")
        }
    }
}

/// Reads dropped file URLs and/or internal node IDs from a drop.
enum TreeDrop {
    static let nodeIDsType = UTType.plainText

    static func handle(
        _ providers: [NSItemProvider],
        onFiles: @escaping @MainActor ([URL]) -> Void,
        onNodes: @escaping @MainActor ([String]) -> Void
    ) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            Task { @MainActor in
                var urls: [URL] = []
                for provider in fileProviders {
                    if let url = await provider.loadFileURL() { urls.append(url) }
                }
                if !urls.isEmpty { onFiles(urls) }
            }
            return true
        }
        let textProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(nodeIDsType.identifier) }
        guard !textProviders.isEmpty else { return false }
        for provider in textProviders {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? String, string.hasPrefix("iauploader-nodes\n") else { return }
                let ids = string.split(separator: "\n").dropFirst().map(String.init)
                Task { @MainActor in onNodes(ids) }
            }
        }
        return true
    }

    static func provider(for ids: Set<String>) -> NSItemProvider {
        NSItemProvider(object: (["iauploader-nodes"] + ids.sorted()).joined(separator: "\n") as NSString)
    }
}

/// A small sheet asking for a name (new folder, rename).
struct NameSheet: View {
    let title: String
    let message: String?
    let actionTitle: String
    @State var text: String
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(title: String, message: String? = nil, actionTitle: String, initial: String, onCommit: @escaping (String) -> Void) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self._text = State(initialValue: initial)
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: commit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private func commit() {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        onCommit(value)
        dismiss()
    }
}

/// Lets the user pick a destination folder (or type a new path).
struct MoveSheet: View {
    let title: String
    let folders: [String]
    let onCommit: (String) -> Void
    @State private var selection: String = ""
    @State private var typed: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            List(selection: Binding(get: { selection }, set: { selection = $0 ?? ""; typed = selection })) {
                Label("Item root", systemImage: "archivebox").tag(Optional(""))
                ForEach(folders, id: \.self) { folder in
                    let depth = folder.split(separator: "/").count
                    Label((folder as NSString).lastPathComponent, systemImage: "folder")
                        .padding(.leading, CGFloat(depth) * 14)
                        .help(folder)
                        .tag(Optional(folder))
                }
            }
            .frame(height: 260)
            TextField("Destination folder path (new folders are created as needed)", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move Here") {
                    onCommit(RemotePath.join(typed))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}
