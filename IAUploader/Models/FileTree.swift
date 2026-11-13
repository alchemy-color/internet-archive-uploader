import Foundation

/// A folder tree built from flat archive paths ("a/b/c.txt"). Node IDs are
/// stable across rebuilds (they are derived from paths), so expanded
/// folders and selections survive refreshes and tab switches.
struct TreeNode: Identifiable, Hashable, Sendable {
    enum Badge: String, Hashable, Sendable {
        case processing     // changed by this app, archive.org not caught up yet
        case queued         // waiting in the upload queue
        case emptyFolder    // created here, no files yet
        // Sync status against the linked Finder folder:
        case added          // new in Finder, will be uploaded
        case modified       // changed in Finder, will replace
        case movedHere      // will be moved here from another path
        case movedAway      // will be moved to another path
        case removing       // not in Finder, will be removed from archive.org

        var isChange: Bool {
            switch self {
            case .added, .modified, .movedHere, .movedAway, .removing: return true
            default: return false
            }
        }
    }

    let id: String
    let name: String
    let path: String
    let isFolder: Bool
    var children: [TreeNode]
    var fileCount: Int
    var totalBytes: Int64
    var badge: Badge?
    /// Extra detail, e.g. where a moved file comes from.
    var note: String? = nil
    /// Number of pending sync changes inside a folder (or 1 for a changed file).
    var changeCount: Int = 0

    static func folderID(_ path: String) -> String { "d:" + path }
    static func fileID(_ key: String) -> String { "f:" + key }

    static func isFolderID(_ id: String) -> Bool { id.hasPrefix("d:") }
    static func folderPath(fromID id: String) -> String? { isFolderID(id) ? String(id.dropFirst(2)) : nil }
    static func fileKey(fromID id: String) -> String? { id.hasPrefix("f:") ? String(id.dropFirst(2)) : nil }
}

struct TreeEntry: Sendable {
    /// Unique key for the file (a remote path, or a local file UUID).
    var key: String
    var path: String
    var size: Int64
    var badge: TreeNode.Badge?
    var note: String? = nil
}

enum FileTreeBuilder {
    private final class Box {
        let name: String
        let path: String
        var folders: [String: Box] = [:]
        var files: [TreeNode] = []
        var badge: TreeNode.Badge?
        init(name: String, path: String) { self.name = name; self.path = path }
    }

    /// Builds the tree. `extraFolders` adds folders that hold no files yet.
    static func build(_ entries: [TreeEntry], extraFolders: Set<String> = []) -> [TreeNode] {
        let root = Box(name: "", path: "")

        func folder(for path: String) -> Box {
            var current = root
            var soFar = ""
            for part in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
                soFar = soFar.isEmpty ? part : soFar + "/" + part
                if let next = current.folders[part] {
                    current = next
                } else {
                    let next = Box(name: part, path: soFar)
                    current.folders[part] = next
                    current = next
                }
            }
            return current
        }

        for entry in entries {
            let parent = folder(for: RemotePath.parent(of: entry.path))
            let name = (entry.path as NSString).lastPathComponent
            parent.files.append(TreeNode(
                id: TreeNode.fileID(entry.key),
                name: name,
                path: entry.path,
                isFolder: false,
                children: [],
                fileCount: 1,
                totalBytes: entry.size,
                badge: entry.badge,
                note: entry.note,
                changeCount: entry.badge?.isChange == true ? 1 : 0
            ))
        }
        for extra in extraFolders where !extra.isEmpty {
            let box = folder(for: extra)
            if box.files.isEmpty && box.folders.isEmpty { box.badge = .emptyFolder }
        }

        func convert(_ box: Box) -> [TreeNode] {
            var folders = box.folders.values.map { child -> TreeNode in
                let children = convert(child)
                let isEmpty = children.isEmpty
                return TreeNode(
                    id: TreeNode.folderID(child.path),
                    name: child.name,
                    path: child.path,
                    isFolder: true,
                    children: children,
                    fileCount: children.reduce(0) { $0 + $1.fileCount },
                    totalBytes: children.reduce(0) { $0 + ($1.badge == .movedAway || $1.badge == .removing ? 0 : $1.totalBytes) },
                    badge: isEmpty ? .emptyFolder : nil,
                    changeCount: children.reduce(0) { $0 + $1.changeCount }
                )
            }
            folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let files = box.files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return folders + files
        }
        return convert(root)
    }

    /// All folder paths in a tree, depth first.
    static func folderPaths(_ nodes: [TreeNode]) -> [String] {
        nodes.flatMap { node -> [String] in
            node.isFolder ? [node.path] + folderPaths(node.children) : []
        }
    }

    /// Finds a node by ID.
    static func find(_ id: String, in nodes: [TreeNode]) -> TreeNode? {
        for node in nodes {
            if node.id == id { return node }
            if node.isFolder, let found = find(id, in: node.children) { return found }
        }
        return nil
    }
}
