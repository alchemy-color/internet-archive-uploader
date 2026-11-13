import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    /// Quit guard: always confirm, and warn loudly while uploads are running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return MainActor.assumeIsolated {
            let queue = model.queue
            let uploading = queue.isRunning
            let waiting = queue.jobs.filter { $0.status == .queued || $0.status == .uploading }.count
            if !uploading && waiting == 0 && !model.settings.confirmQuitWhenIdle {
                return .terminateNow
            }
            let alert = NSAlert()
            if uploading || waiting > 0 {
                alert.alertStyle = .critical
                alert.messageText = "Uploads are still running"
                alert.informativeText = "\(waiting) file\(waiting == 1 ? " is" : "s are") still uploading or waiting (\(ByteCountFormatter.shortString(max(0, queue.totalBytes - queue.sentBytes))) left). If you quit now, files in progress are aborted. The queue is saved and comes back paused next time you open the app."
                alert.addButton(withTitle: "Keep Uploading")
                alert.addButton(withTitle: "Quit Anyway")
            } else {
                alert.alertStyle = .informational
                alert.messageText = "Quit Internet Archive Uploader?"
                alert.informativeText = "Nothing is uploading right now."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Quit")
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Don't ask when nothing is uploading"
            }
            let response = alert.runModal()
            if alert.suppressionButton?.state == .on {
                model.settings.confirmQuitWhenIdle = false
            }
            return response == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let model {
            MainActor.assumeIsolated {
                model.saveState()
                model.queue.shutdown()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct IAUploaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var model = AppModel()
    @State private var undoManager = UndoManager()

    var body: some Scene {
        WindowGroup {
            RootView(model: model, undoManager: undoManager)
                .frame(minWidth: 980, minHeight: 660)
                .task {
                    model.undoManager = undoManager
                    appDelegate.model = model
                }
        }
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(model: model)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undoManager?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!(model.undoManager?.canUndo ?? false))
            Button("Redo") { model.undoManager?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(model.undoManager?.canRedo ?? false))
        }

        CommandGroup(replacing: .newItem) {
            Button("New Item") { model.startNewItem() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Add Files to New Item…") { model.startNewItem(); model.presentFilePicker() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Add Folder to New Item…") { model.startNewItem(); model.presentFolderPicker() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("Upload") {
            Button("Create Item & Upload") { model.startUpload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.route != .newItem || !model.canStartUpload)
            Divider()
            Button("Pause All Uploads") { model.queue.pauseAll() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!model.queue.hasWork)
            Button("Resume Uploads") { model.queue.resumeAll() }
                .disabled(model.queue.pausedCount == 0 && !model.queue.isPaused)
            Button("Stop All Uploads") { model.queue.stopAll() }
                .disabled(!model.queue.hasWork)
            Button("Retry Failed") { model.queue.retryFailed() }
                .disabled(model.queue.failedCount == 0)
            Divider()
            Button("Check Linked Folder") { Task { await model.checkSync() } }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model.linkedFolder == nil)
            Button("Activity Log") { model.showActivityLog = true }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            Button("Open Item Page") { model.openItemPage() }
                .disabled(model.itemURL == nil)
            Button("Copy Item Link") { model.copyItemLink() }
                .disabled(model.itemURL == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Bigger") { UIScale.bigger() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller") { UIScale.smaller() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { UIScale.reset() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
