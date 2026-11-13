import Foundation

/// Snapshot of the app's working state, persisted across launches.
struct AppStateSnapshot: Codable {
    var step: String?
    var files: [String] = []               // file URLs as strings
    var includeHiddenFiles: Bool = false
    var metadata: ItemMetadata?
    var identifierAuto: Bool = true
    var mediatypeTouched: Bool = false
    var collectionTouched: Bool = false
    var allowExistingIdentifier: Bool = false
    var skipExistingFiles: Bool = true
    var uploadDestinationFolder: String = ""
    var managedIdentifier: String = ""
    var managedMetadata: ItemMetadata?
    // v2 — full file records so folder structure survives relaunch.
    var pickedFiles: [PickedFile]?
    var planFolders: [String]?
    var overlay: RemoteOverlay?
    var managedVirtualFolders: [String: [String]]?
    var uploadMode: String?
    var linkedFolders: [String: LinkedFolder]?
}

enum StateStore {
    private static let directory = AppPaths.configDirectory
    private static let file = (directory as NSString).appendingPathComponent("state.json")

    static func save(_ snapshot: AppStateSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }

    static func load() -> AppStateSnapshot? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { return nil }
        return try? JSONDecoder().decode(AppStateSnapshot.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: file)
    }
}
