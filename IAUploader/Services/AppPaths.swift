import Foundation

/// Where the app keeps its files and preferences.
///
/// Setting `IAUPLOADER_CONFIG_DIR` runs the app against a separate data
/// folder and preferences domain, so a second copy (for testing) never
/// touches the queue or state of the copy you are using.
enum AppPaths {
    static let overrideDirectory: String? = ProcessInfo.processInfo.environment["IAUPLOADER_CONFIG_DIR"]

    static var configDirectory: String {
        overrideDirectory ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/IAUploader")
    }

    static func file(_ name: String) -> URL {
        URL(fileURLWithPath: (configDirectory as NSString).appendingPathComponent(name))
    }

    static let defaults: UserDefaults = {
        if overrideDirectory != nil, let suite = UserDefaults(suiteName: "com.paulomartins.IAUploader.sandbox") {
            return suite
        }
        return .standard
    }()
}
