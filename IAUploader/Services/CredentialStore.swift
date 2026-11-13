import Foundation

/// Stores the archive.org S3 keys in a user-only file under
/// `~/.config/IAUploader/credentials.json` (mode 0600), matching the
/// convention used by the Internet Archive command-line tool.
///
/// No passwords are ever persisted: after sign-in only the S3 access and
/// secret keys are kept. Using a plain file avoids Keychain prompts and
/// keeps the tool self-contained.
enum CredentialStore {
    private static let directory = AppPaths.configDirectory
    private static let file = (directory as NSString)
        .appendingPathComponent("credentials.json")

    static func save(_ credentials: ArchiveCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: URL(fileURLWithPath: file), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        } catch {
            // Best effort: the credentials remain in memory for this session.
        }
    }

    static func load() -> ArchiveCredentials? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { return nil }
        return try? JSONDecoder().decode(ArchiveCredentials.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: file)
    }
}
