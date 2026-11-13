import AppKit
import UniformTypeIdentifiers

@MainActor
enum FilePicker {
    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Choose files to upload"
        panel.prompt = "Add Files"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Choose folders to upload"
        panel.prompt = "Add Folders"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

extension NSItemProvider {
    /// Loads a file URL from a drag-and-drop provider.
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let string = item as? String,
                          let url = URL(string: string), url.isFileURL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
