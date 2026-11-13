import SwiftUI

// MARK: - Global status bar

/// Always-visible strip at the top of the window whenever the queue has
/// work: overall progress plus pause / resume / stop for everything.
struct QueueStatusBar: View {
    @Environment(AppModel.self) private var model
    @State private var confirmStop = false

    var body: some View {
        let queue = model.queue
        if !queue.jobs.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    statusIcon
                        .font(.system(size: 18))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(headline)
                                .font(.callout.weight(.semibold))
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(detail)
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        ProgressView(value: queue.fraction)
                            .progressViewStyle(.linear)
                            .tint(queue.failedCount > 0 ? .orange : .accentColor)
                    }
                    Spacer(minLength: 8)
                    controls
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            .background(.bar)
            .confirmationDialog("Stop all uploads?", isPresented: $confirmStop) {
                Button("Stop All", role: .destructive) { queue.stopAll() }
                Button("Keep Uploading", role: .cancel) {}
            } message: {
                Text("Files in progress are aborted. Finished files stay on archive.org. Stopped files stay in the queue so you can resume or remove them.")
            }
        }
    }

    private var headline: String {
        let queue = model.queue
        if queue.isRunning {
            return "Uploading \(queue.activeJobs.count) of \(queue.unfinishedCount) remaining"
        }
        if queue.isPaused && queue.unfinishedCount > 0 { return "Paused — \(queue.unfinishedCount) file\(queue.unfinishedCount == 1 ? "" : "s") waiting" }
        if queue.failedCount > 0 { return "\(queue.failedCount) upload\(queue.failedCount == 1 ? "" : "s") failed" }
        if queue.pausedCount > 0 { return "\(queue.pausedCount) stopped or paused" }
        if queue.waitingCount > 0 { return model.credentials == nil ? "Sign in to upload" : "Waiting…" }
        return "All uploads complete"
    }

    private var detail: String {
        let queue = model.queue
        var parts = ["\(ByteCountFormatter.shortString(queue.sentBytes)) of \(ByteCountFormatter.shortString(queue.totalBytes))",
                     "\(queue.doneCount)/\(queue.jobs.count) files"]
        if queue.isRunning, queue.speedBytesPerSecond > 0 {
            parts.append(ByteCountFormatter.shortString(Int64(queue.speedBytesPerSecond)) + "/s")
        }
        if let eta = queue.etaSeconds, eta.isFinite {
            parts.append("\(TimeInterval(eta).clockString) left")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        let queue = model.queue
        if queue.isRunning {
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.accentColor).symbolEffect(.pulse)
        } else if queue.failedCount > 0 {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if queue.unfinishedCount == 0 {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var controls: some View {
        let queue = model.queue
        HStack(spacing: 6) {
            if queue.isRunning || (queue.waitingCount > 0 && !queue.isPaused) {
                Button { queue.pauseAll() } label: { Label("Pause All", systemImage: "pause.fill") }
                    .help("Pause every upload. Files in progress restart from the beginning when resumed.")
            } else if queue.unfinishedCount > 0 && queue.failedCount < queue.unfinishedCount {
                Button { queue.resumeAll() } label: { Label("Resume", systemImage: "play.fill") }
                    .help("Resume paused uploads")
            }
            if queue.failedCount > 0 {
                Button { queue.retryFailed() } label: { Label("Retry Failed", systemImage: "arrow.clockwise") }
            }
            if queue.isRunning {
                Button(role: .destructive) { confirmStop = true } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Stop all uploads")
            }
            if queue.unfinishedCount == 0 {
                Button { queue.clearFinished() } label: { Label("Clear", systemImage: "xmark") }
                    .help("Remove finished uploads from the queue")
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .buttonStyle(.bordered)
    }
}

// MARK: - Upload column

/// The upload queue as a column: what's uploading, what needs attention,
/// what's done. Fine-grained controls live in the right-click menu.
struct UploadColumn: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<UUID>()
    @State private var editingJob: UploadJob?
    @State private var confirmRemoveUnfinished = false

    /// On an item, show only that item's uploads unless "All Items" is on.
    private var identifier: String? {
        guard let id = model.route.identifier else { return nil }
        return ViewMemory.shared.flag("upload.allItems", default: false) ? nil : id
    }

    private var jobs: [UploadJob] {
        model.queue.jobs.filter { identifier == nil || $0.identifier == identifier }
    }

    var body: some View {
        let queue = model.queue
        let jobs = jobs
        let active = jobs.filter { $0.status == .uploading || $0.status == .queued }
        let attention = jobs.filter { $0.status == .failed || $0.status == .paused || $0.status == .cancelled }
        let done = jobs.filter { $0.status == .done }

        VStack(spacing: 0) {
            ColumnHeader(title: "Upload", subtitle: subtitle(active: active.count, attention: attention.count, done: done.count), systemImage: "arrow.up.circle") {
                if queue.isRunning || (queue.waitingCount > 0 && !queue.isPaused) {
                    Button { queue.pauseAll() } label: { Image(systemName: "pause.fill") }
                        .help("Pause all uploads")
                } else if queue.unfinishedCount > 0 {
                    Button { queue.resumeAll() } label: { Image(systemName: "play.fill") }
                        .help("Resume uploads")
                }
                Menu {
                    if model.route.identifier != nil {
                        Toggle("Show All Items", isOn: ViewMemory.shared.flagBinding("upload.allItems", default: false))
                        Divider()
                    }
                    Button("Retry Failed") { queue.retryFailed() }.disabled(queue.failedCount == 0)
                    Button("Restart All Unfinished") { queue.restartAll() }.disabled(queue.unfinishedCount == 0)
                    Button("Stop All") { queue.stopAll() }.disabled(!queue.hasWork)
                    Button("Remove All Unfinished…", role: .destructive) { confirmRemoveUnfinished = true }
                        .disabled(queue.unfinishedCount == 0)
                    Divider()
                    Button("Clear Finished") { queue.clearFinished() }.disabled(queue.doneCount == 0)
                    Button("Activity Log…") { model.showActivityLog = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if model.route == .newItem {
                CreateItemCard()
                Divider()
            }

            if model.hasSyncTasksForCurrentItem {
                SyncTasksPanel()
                Divider()
            }

            if jobs.isEmpty && model.hasSyncTasksForCurrentItem {
                Spacer(minLength: 0)
            } else if jobs.isEmpty {
                EmptyState(
                    symbol: "tray",
                    title: "Nothing uploading",
                    message: model.route == .newItem ? "Uploads appear here once the item is created." : "Drop files on the Files column to upload them."
                )
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    group("Uploading", key: "active", jobs: active, defaultExpanded: true)
                    group("Needs attention", key: "attention", jobs: attention, defaultExpanded: true)
                    group("Done", key: "done", jobs: done, defaultExpanded: false)
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    contextMenu(ids)
                } primaryAction: { ids in
                    if let id = ids.first, let job = queue.job(id) { FilePicker.revealInFinder(job.localURL) }
                }
                .onDeleteCommand {
                    queue.remove(selection)
                    selection.removeAll()
                }
            }
        }
        .confirmationDialog("Remove all unfinished uploads?", isPresented: $confirmRemoveUnfinished) {
            Button("Remove \(model.queue.unfinishedCount) Uploads", role: .destructive) {
                let ids = Set(model.queue.jobs.filter { $0.status != .done }.map(\.id))
                model.queue.remove(ids)
                selection.subtract(ids)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops anything uploading and clears every waiting, paused, stopped and failed upload, for all items. Files already on archive.org are not touched.")
        }
        .sheet(item: $editingJob) { job in
            NameSheet(
                title: "Change destination",
                message: "Where “\(job.fileName)” goes inside “\(job.identifier)”. Use / for folders.",
                actionTitle: "Save",
                initial: job.remotePath
            ) { model.queue.editRemotePath(job.id, to: $0) }
        }
    }

    private func subtitle(active: Int, attention: Int, done: Int) -> String {
        var parts: [String] = []
        if active > 0 { parts.append("\(active) to go") }
        if attention > 0 { parts.append("\(attention) need attention") }
        if done > 0 { parts.append("\(done) done") }
        if model.queue.isPaused && active + attention > 0 { parts.insert("Paused", at: 0) }
        return parts.isEmpty ? (identifier.map { "Only \($0)" } ?? "All items") : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func group(_ title: String, key: String, jobs: [UploadJob], defaultExpanded: Bool) -> some View {
        if !jobs.isEmpty {
            Section(isExpanded: ViewMemory.shared.flagBinding("upload.section.\(key)", default: defaultExpanded)) {
                ForEach(jobs.prefix(key == "done" ? 300 : 2000)) { job in
                    QueueRow(job: job, compact: true, showIdentifier: identifier == nil)
                        .tag(job.id)
                }
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(jobs.count)").monospacedDigit()
                    if key == "done" {
                        Button("Clear") { model.queue.clearFinished() }.buttonStyle(.borderless).font(.caption)
                    } else if key == "attention" {
                        Button("Retry All") { model.queue.resume(Set(jobs.map(\.id))) }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<UUID>) -> some View {
        let queue = model.queue
        let jobs = ids.compactMap { queue.job($0) }
        if !jobs.isEmpty {
            Button("Resume / Retry") { queue.resume(ids) }
                .disabled(!jobs.contains { [.paused, .cancelled, .failed].contains($0.status) })
            Button("Pause") { queue.pause(ids) }
                .disabled(!jobs.contains { $0.status.isActive })
            Button("Restart from Beginning") { queue.forceRestart(ids) }
            Divider()
            Button("Upload Next") { queue.moveToTop(ids) }
            if jobs.count == 1, let job = jobs.first, job.status != .uploading, job.status != .done {
                Button("Change Destination…") { editingJob = job }
            }
            Button("Show in Finder") { FilePicker.revealInFinder(jobs[0].localURL) }
            Divider()
            Button("Remove", role: .destructive) {
                queue.remove(ids)
                selection.subtract(ids)
            }
        }
    }
}

// MARK: - Row

struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let job: UploadJob
    var compact = false
    var showIdentifier = false

    var body: some View {
        HStack(spacing: 8) {
            icon.font(UIScale.font(14)).frame(width: UIScale.size(20))
            VStack(alignment: .leading, spacing: 2) {
                Text(job.fileName)
                    .font(UIScale.font(13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(UIScale.font(11))
                    .foregroundStyle(job.status == .failed ? .red : .secondary)
                    .lineLimit(compact ? 1 : 2)
                    .truncationMode(.middle)
                if job.status == .uploading {
                    ProgressView(value: job.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 4)
            if !compact {
                Text(ByteCountFormatter.shortString(job.byteSize))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            Text(statusText)
                .font(UIScale.font(11.5))
                .monospacedDigit()
                .foregroundStyle(statusColor)
                .frame(width: UIScale.size(compact ? 48 : 64), alignment: .trailing)
            rowButtons
        }
        .padding(.vertical, UIScale.size(3))
        .help(job.error ?? "\(job.identifier)/\(job.remotePath)")
    }

    private var subtitle: String {
        if let error = job.error, job.status != .done { return error }
        if model.queue.isStalled(job) { return "No progress for a while — try Force Restart" }
        if job.status == .queued, model.queue.jobs.contains(where: { $0.identifier == job.identifier && $0.createsItem && $0.id != job.id && $0.status != .done }) {
            return "Waiting for the item to be created…"
        }
        let folder = RemotePath.parent(of: job.remotePath)
        var text = folder.isEmpty ? "/ (item root)" : folder
        if showIdentifier { text = job.identifier + " › " + text }
        if job.replacesExisting { text += " · replaces existing" }
        if job.createsItem { text += " · creates item" }
        return text
    }

    private var statusText: String {
        switch job.status {
        case .uploading: return "\(Int((job.fraction * 100).rounded()))%"
        case .done: return job.attempts > 1 ? "\(job.attempts) tries" : "Done"
        default: return job.status.title
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .done: return .green
        case .failed: return .red
        case .uploading: return model.queue.isStalled(job) ? .orange : .secondary
        default: return .secondary
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch job.status {
        case .queued: Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .uploading:
            Image(systemName: model.queue.isStalled(job) ? "exclamationmark.circle.fill" : "arrow.up.circle.fill")
                .foregroundStyle(model.queue.isStalled(job) ? Color.orange : Color.accentColor)
        case .paused: Image(systemName: "pause.circle").foregroundStyle(.secondary)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var rowButtons: some View {
        let queue = model.queue
        HStack(spacing: 2) {
            switch job.status {
            case .uploading where queue.isStalled(job):
                Button { queue.forceRestart([job.id]) } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Stuck — restart from the beginning")
            case .uploading, .queued:
                Button { queue.pause([job.id]) } label: { Image(systemName: "pause.fill") }
                    .help("Pause")
            case .paused, .cancelled, .failed:
                Button { queue.resume([job.id]) } label: { Image(systemName: job.status == .failed ? "arrow.clockwise" : "play.fill") }
                    .help(job.status == .failed ? "Retry" : "Resume")
            case .done:
                EmptyView()
            }
            Button { queue.remove([job.id]) } label: { Image(systemName: "xmark") }
                .help("Remove from the list")
        }
        .buttonStyle(.borderless)
        .font(UIScale.font(13))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Activity log

struct ActivityLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Done") { model.showActivityLog = false }
                    .keyboardShortcut(.cancelAction)
                Label("Activity log", systemImage: "terminal")
                    .font(.callout.weight(.medium))
                Text("\(model.queue.log.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    FilePicker.copyToPasteboard(model.queue.log.map { "\(Self.timeFormatter.string(from: $0.date))  \($0.message)" }.joined(separator: "\n"))
                }
                Button("Clear") { model.queue.clearLog() }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.queue.log) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(Self.timeFormatter.string(from: line.date)).foregroundStyle(.tertiary)
                                Text(line.message)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .onChange(of: model.queue.log.count) { _, _ in
                    if let last = model.queue.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - Sync tasks (top of the Upload column)

/// The ordered sync steps for the current item: folders, moves, uploads,
/// removals. Prepared by "Review & Sync", run from here.
struct SyncTasksPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.syncProgress
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.accentColor)
                Text(title).font(UIScale.font(13, .semibold))
                Spacer()
                if model.syncStarted {
                    Text("\(progress.done)/\(progress.total)").font(UIScale.font(12)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if model.syncStarted {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            } else {
                Text("Choose what to sync, then Run. Steps run top to bottom; removals happen last, and only if every selected step before them succeeds.")
                    .font(UIScale.font(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([AppModel.SyncTask.Kind.folder, .move, .upload, .delete], id: \.rawValue) { kind in
                        let tasks = model.syncTasks.filter { $0.kind == kind }
                        if !tasks.isEmpty { phase(kind, tasks) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: UIScale.size(260))


            HStack {
                if model.isApplyingSync {
                    Button("Stop Sync", role: .destructive) { model.cancelSync() }
                        .disabled(model.syncCancelRequested)
                } else {
                    Button(model.syncStarted ? "Close" : "Discard") { model.discardSyncTasks() }
                }
                Spacer()
                if !model.syncStarted {
                    Button("Run \(model.selectedSyncTaskCount) Selected") { model.runSyncTasks() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedSyncTaskCount == 0)
                }
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.05))
    }

    private var title: String {
        if model.syncCancelRequested { return "Stopping sync…" }
        if model.isApplyingSync { return "Syncing with Finder" }
        if model.syncStarted { return "Sync finished" }
        return "Sync tasks"
    }

    @State private var expanded: Set<Int> = []

    @ViewBuilder
    private func phase(_ kind: AppModel.SyncTask.Kind, _ tasks: [AppModel.SyncTask]) -> some View {
        let statuses = tasks.map { model.liveStatus(of: $0) }
        let done = statuses.filter { $0 == .done }.count
        let failed = statuses.filter { if case .failed = $0 { return true }; return false }.count
        let isOpen = expanded.contains(kind.rawValue) || (kind != .upload && tasks.count <= 6)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
            if !model.syncStarted {
                let selected = tasks.filter(\.isSelected).count
                Toggle("", isOn: Binding(
                    get: { selected > 0 },
                    set: { model.setSyncPhase(kind, selected: $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(selected == tasks.count ? "All selected" : "\(selected) of \(tasks.count) selected")
            }
            Button {
                if expanded.contains(kind.rawValue) { expanded.remove(kind.rawValue) } else { expanded.insert(kind.rawValue) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(UIScale.font(9, .bold)).foregroundStyle(.secondary)
                    Text(kind.phase).font(UIScale.font(12, .medium))
                        .foregroundStyle(tasks.contains(where: \.isSelected) || model.syncStarted ? .primary : .secondary)
                    Spacer()
                    if failed > 0 { Text("\(failed) failed").foregroundStyle(.red).font(UIScale.font(11)) }
                    Text(model.syncStarted ? "\(done)/\(tasks.count)" : "\(tasks.filter(\.isSelected).count)/\(tasks.count)")
                        .font(UIScale.font(11)).monospacedDigit().foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            }
            if isOpen {
                ForEach(tasks.prefix(300)) { task in
                    row(task)
                }
                if tasks.count > 300 { Text("…and \(tasks.count - 300) more").font(UIScale.font(11)).foregroundStyle(.secondary) }
            }
        }
    }

    private func row(_ task: AppModel.SyncTask) -> some View {
        let status = model.liveStatus(of: task)
        return HStack(alignment: .top, spacing: 6) {
            if !model.syncStarted {
                Toggle("", isOn: Binding(get: { task.isSelected }, set: { _ in model.toggleSyncTask(task.id) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            Group {
                switch status {
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .running: ProgressView().controlSize(.mini)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .skipped: Image(systemName: "forward.circle").foregroundStyle(.orange)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            .font(UIScale.font(12))
            .frame(width: UIScale.size(16))
            VStack(alignment: .leading, spacing: 1) {
                Text((task.title as NSString).lastPathComponent).font(UIScale.font(12)).lineLimit(1).truncationMode(.middle)
                Text(detail(task, status)).font(UIScale.font(10.5)).foregroundStyle(isFailure(status) ? .red : .secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
        }
        .padding(.leading, 14)
        .help(task.title)
    }

    private func detail(_ task: AppModel.SyncTask, _ status: AppModel.SyncTask.Status) -> String {
        switch status {
        case .skipped(let why), .failed(let why): return why
        default: return task.kind == .move ? (task.detail ?? "") + " → " + RemotePath.parent(of: task.title) : (task.detail ?? RemotePath.parent(of: task.title))
        }
    }

    private func isFailure(_ status: AppModel.SyncTask.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }
}
