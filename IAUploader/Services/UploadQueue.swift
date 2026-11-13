import Foundation
import Observation

/// The one and only upload queue. Every upload in the app — new items,
/// files added to existing items, folder syncs — goes through here, so there
/// is a single place to see progress, pause, stop, restart, or edit work.
///
/// Jobs are persisted to disk, so a quit or crash never loses the queue.
/// IAS3 has no resumable uploads: pausing or restarting a file aborts the
/// current PUT, and the file starts again from zero when it resumes.
@MainActor
@Observable
final class UploadQueue {
    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let message: String
    }

    private(set) var jobs: [UploadJob] = []
    private(set) var batches: [UploadBatch] = []
    /// When true no new job starts. Running jobs are paused too.
    private(set) var isPaused = false
    private(set) var log: [LogLine] = []
    private(set) var speedBytesPerSecond: Double = 0
    /// Last time each running job reported bytes; used to flag stuck uploads.
    private(set) var lastProgressAt: [UUID: Date] = [:]

    var concurrency: Int = 3 { didSet { pump() } }
    var maxRetries: Int = 4
    var credentials: ArchiveCredentials?
    var optionsProvider: () -> UploadOptions = { .default }
    /// Called on the main actor after each file is accepted by archive.org.
    var onJobSucceeded: ((UploadJob) -> Void)?
    /// Called when the queue drains with no work left.
    var onQueueDrained: (() -> Void)?

    @ObservationIgnored private let transport = UploadTransport()
    @ObservationIgnored private let throttler = ProgressThrottler()
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var cancelIntent: [UUID: CancelIntent] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var samples: [(date: Date, bytes: Int64)] = []
    @ObservationIgnored private var sentCounter: Int64 = 0
    /// Held while uploads run: stops App Nap from throttling them, idle sleep
    /// from cutting them off, and macOS from auto-terminating the app.
    @ObservationIgnored private var activity: NSObjectProtocol?

    private enum CancelIntent {
        case pause, stop, restart, remove
    }

    static let stallInterval: TimeInterval = 90

    /// `persistent: false` keeps the queue in memory only (tests, previews),
    /// so it can never overwrite the real queue file.
    private let persistent: Bool

    init(restore: Bool = true, persistent: Bool? = nil) {
        self.persistent = persistent ?? restore
        if restore { load() }
    }

    // MARK: - Derived state

    var hasWork: Bool { jobs.contains { $0.status.isActive } }
    var isRunning: Bool { !running.isEmpty }
    var activeJobs: [UploadJob] { jobs.filter { $0.status == .uploading } }
    var unfinishedCount: Int { jobs.filter { $0.status != .done }.count }
    var failedCount: Int { jobs.filter { $0.status == .failed }.count }
    var pausedCount: Int { jobs.filter { $0.status == .paused || $0.status == .cancelled }.count }
    var waitingCount: Int { jobs.filter { $0.status == .queued }.count }
    var doneCount: Int { jobs.filter { $0.status == .done }.count }

    /// Bytes in the current "session" of work: everything not stopped by the user.
    var totalBytes: Int64 {
        jobs.filter { $0.status != .cancelled }.reduce(0) { $0 + $1.byteSize }
    }

    var sentBytes: Int64 {
        jobs.filter { $0.status != .cancelled }.reduce(0) { $0 + ($1.status == .done ? $1.byteSize : $1.sent) }
    }

    var fraction: Double {
        let total = totalBytes
        guard total > 0 else { return 0 }
        return min(max(Double(sentBytes) / Double(total), 0), 1)
    }

    var etaSeconds: Double? {
        guard speedBytesPerSecond > 1, isRunning else { return nil }
        let remaining = jobs.filter { $0.status.isActive }.reduce(Int64(0)) { $0 + max(0, $1.byteSize - $1.sent) }
        return Double(remaining) / speedBytesPerSecond
    }

    func isStalled(_ job: UploadJob, now: Date = Date()) -> Bool {
        guard job.status == .uploading else { return false }
        let last = lastProgressAt[job.id] ?? job.startedAt ?? now
        return now.timeIntervalSince(last) > Self.stallInterval
    }

    func job(_ id: UUID) -> UploadJob? {
        jobs.first { $0.id == id }
    }

    func batch(_ id: UUID) -> UploadBatch? {
        batches.first { $0.id == id }
    }

    /// Remote paths already waiting for (or in) upload in an item.
    func pendingPaths(for identifier: String) -> Set<String> {
        Set(jobs.filter { $0.identifier == identifier && $0.status != .done && $0.status != .cancelled }.map(\.remotePath))
    }

    // MARK: - Adding work

    func enqueue(_ newJobs: [UploadJob], batch: UploadBatch) {
        guard !newJobs.isEmpty else { return }
        if !batches.contains(where: { $0.id == batch.id }) {
            batches.append(batch)
        }
        jobs.append(contentsOf: newJobs)
        appendLog("Queued \(newJobs.count) file\(newJobs.count == 1 ? "" : "s") for “\(batch.identifier)”.")
        scheduleSave()
        pump()
    }

    // MARK: - Global controls

    func pauseAll() {
        isPaused = true
        for id in running.keys { cancel(id, intent: .pause) }
        for index in jobs.indices where jobs[index].status == .queued {
            jobs[index].status = .paused
        }
        appendLog("Paused all uploads.")
        scheduleSave()
    }

    func resumeAll() {
        isPaused = false
        for index in jobs.indices where jobs[index].status == .paused {
            jobs[index].status = .queued
            jobs[index].error = nil
        }
        appendLog("Resumed uploads.")
        scheduleSave()
        pump()
    }

    /// Stops everything: running uploads are aborted and nothing else starts
    /// until the user resumes or restarts individual files.
    func stopAll() {
        for id in running.keys { cancel(id, intent: .stop) }
        for index in jobs.indices where jobs[index].status == .queued || jobs[index].status == .paused {
            jobs[index].status = .cancelled
            jobs[index].error = "Stopped"
        }
        appendLog("Stopped all uploads.")
        scheduleSave()
    }

    /// Requeues every unfinished job from zero, including stuck ones.
    func restartAll() {
        isPaused = false
        for id in running.keys { cancel(id, intent: .restart) }
        for index in jobs.indices where jobs[index].status != .done && jobs[index].status != .uploading {
            reset(index)
        }
        appendLog("Restarted all unfinished uploads.")
        scheduleSave()
        pump()
    }

    func retryFailed() {
        for index in jobs.indices where jobs[index].status == .failed {
            reset(index)
        }
        scheduleSave()
        pump()
    }

    func clearFinished() {
        jobs.removeAll { $0.status == .done }
        pruneBatches()
        scheduleSave()
    }

    // MARK: - Per-job controls

    func pause(_ ids: Set<UUID>) {
        for id in ids {
            if running[id] != nil {
                cancel(id, intent: .pause)
            } else if let index = index(of: id), jobs[index].status == .queued {
                jobs[index].status = .paused
            }
        }
        scheduleSave()
    }

    func resume(_ ids: Set<UUID>) {
        for id in ids {
            guard let index = index(of: id) else { continue }
            if [.paused, .cancelled, .failed].contains(jobs[index].status) {
                jobs[index].status = .queued
                jobs[index].error = nil
                jobs[index].sent = 0
            }
        }
        isPaused = false
        scheduleSave()
        pump()
    }

    /// Aborts the file if it is running and starts it again from zero.
    func forceRestart(_ ids: Set<UUID>) {
        for id in ids {
            if running[id] != nil {
                cancel(id, intent: .restart)
            } else if let index = index(of: id), jobs[index].status != .done {
                reset(index)
            } else if let index = index(of: id), jobs[index].status == .done {
                // Re-upload a finished file on request.
                reset(index)
            }
        }
        isPaused = false
        scheduleSave()
        pump()
    }

    func remove(_ ids: Set<UUID>) {
        for id in ids where running[id] != nil {
            cancel(id, intent: .remove)
        }
        jobs.removeAll { ids.contains($0.id) && running[$0.id] == nil }
        pruneBatches()
        scheduleSave()
    }

    func removeBatch(_ batchID: UUID) {
        remove(Set(jobs.filter { $0.batchID == batchID }.map(\.id)))
    }

    func moveToTop(_ ids: Set<UUID>) {
        let moving = jobs.filter { ids.contains($0.id) }
        jobs.removeAll { ids.contains($0.id) }
        jobs.insert(contentsOf: moving, at: 0)
        scheduleSave()
    }

    func moveToBottom(_ ids: Set<UUID>) {
        let moving = jobs.filter { ids.contains($0.id) }
        jobs.removeAll { ids.contains($0.id) }
        jobs.append(contentsOf: moving)
        scheduleSave()
    }

    /// Changes where a not-yet-uploaded file will land inside the item.
    @discardableResult
    func editRemotePath(_ id: UUID, to newPath: String) -> Bool {
        let cleaned = RemotePath.join(newPath)
        guard !cleaned.isEmpty, let index = index(of: id), jobs[index].status != .uploading, jobs[index].status != .done else { return false }
        jobs[index].remotePath = cleaned
        scheduleSave()
        return true
    }

    /// Moves every unfinished job under `oldFolder` into `newFolder`.
    func editFolder(identifier: String, from oldFolder: String, to newFolder: String) {
        for index in jobs.indices where jobs[index].identifier == identifier
            && jobs[index].status != .uploading && jobs[index].status != .done
            && RemotePath.isInside(jobs[index].remotePath, folder: oldFolder) {
            jobs[index].remotePath = RemotePath.reparent(jobs[index].remotePath, from: oldFolder, to: newFolder)
        }
        scheduleSave()
    }

    // MARK: - Scheduling

    private func updateActivity() {
        if !running.isEmpty, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .automaticTerminationDisabled, .suddenTerminationDisabled],
                reason: "Uploading files to archive.org"
            )
        } else if running.isEmpty, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
    }

    private func pump() {
        defer { updateActivity() }
        guard !isPaused, credentials != nil else { return }
        while running.count < max(1, concurrency), let index = nextRunnableIndex() {
            start(index)
        }
        if running.isEmpty && !jobs.contains(where: { $0.status == .queued }) {
            speedBytesPerSecond = 0
            onQueueDrained?()
        }
    }

    private func nextRunnableIndex() -> Int? {
        // Items being created: other files in the same item wait for the
        // creating upload to succeed.
        let blockedIdentifiers = Set(jobs.filter { $0.createsItem && $0.status != .done }.map(\.identifier))
        return jobs.firstIndex { job in
            guard job.status == .queued, running[job.id] == nil else { return false }
            if blockedIdentifiers.contains(job.identifier) && !job.createsItem { return false }
            return true
        }
    }

    private func start(_ index: Int) {
        let jobID = jobs[index].id
        jobs[index].status = .uploading
        jobs[index].sent = 0
        jobs[index].error = nil
        jobs[index].startedAt = Date()
        lastProgressAt[jobID] = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(jobID)
        }
        running[jobID] = task
    }

    private func run(_ jobID: UUID) async {
        guard let snapshot = job(jobID), let credentials else { return }
        let options = optionsProvider()
        let encoded = RemotePath.encoded(snapshot.remotePath)
        guard let url = URL(string: "https://s3.us.archive.org/\(snapshot.identifier)/\(encoded)") else {
            finish(jobID, outcome: .failure("The upload URL for \(snapshot.remotePath) is invalid."))
            return
        }
        guard FileManager.default.isReadableFile(atPath: snapshot.localPath) else {
            finish(jobID, outcome: .failure("The local file is missing or unreadable: \(snapshot.localPath)"))
            return
        }

        var attempt = 0
        var lastMessage = "The upload did not start."
        while attempt <= maxRetries {
            if Task.isCancelled { finish(jobID, outcome: .cancelled); return }
            attempt += 1
            setAttempts(jobID, attempt)
            let headers = Self.headers(for: snapshot, credentials: credentials, options: options)
            do {
                let (response, data) = try await transport.put(
                    url: url,
                    fileURL: snapshot.localURL,
                    headers: headers,
                    onProgress: { [weak self, throttler] sent, _ in
                        guard throttler.shouldEmit(jobID) else { return }
                        Task { @MainActor in self?.progress(jobID, sent: sent) }
                    }
                )
                if (200...299).contains(response.statusCode) {
                    finish(jobID, outcome: .success)
                    return
                }
                let s3Error = S3ErrorParser.parse(data)
                lastMessage = UploadTransport.friendlyMessage(status: response.statusCode, error: s3Error, identifier: snapshot.identifier)
                if RetryPolicy.shouldRetry(status: response.statusCode), attempt <= maxRetries {
                    let delay = RetryPolicy.delay(forAttempt: attempt, retryAfter: RetryPolicy.retryAfter(from: response))
                    appendLog("Retrying \(snapshot.remotePath) in \(Int(delay.rounded()))s (HTTP \(response.statusCode))")
                    setError(jobID, "Retrying: \(lastMessage)")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                finish(jobID, outcome: .failure(lastMessage))
                return
            } catch is CancellationError {
                finish(jobID, outcome: .cancelled)
                return
            } catch let error as URLError {
                if error.code == .cancelled { finish(jobID, outcome: .cancelled); return }
                lastMessage = UploadTransport.friendlyNetworkMessage(error)
                if RetryPolicy.isRetryable(error), attempt <= maxRetries {
                    let delay = RetryPolicy.delay(forAttempt: attempt)
                    appendLog("Retrying \(snapshot.remotePath) in \(Int(delay.rounded()))s (\(lastMessage))")
                    setError(jobID, "Retrying: \(lastMessage)")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                finish(jobID, outcome: .failure(lastMessage))
                return
            } catch {
                finish(jobID, outcome: .failure(error.localizedDescription))
                return
            }
        }
        finish(jobID, outcome: .failure(lastMessage))
    }

    private enum Outcome {
        case success
        case failure(String)
        case cancelled
    }

    private func finish(_ jobID: UUID, outcome: Outcome) {
        running[jobID] = nil
        defer { updateActivity() }
        lastProgressAt[jobID] = nil
        let intent = cancelIntent.removeValue(forKey: jobID)
        guard let index = index(of: jobID) else { pump(); return }

        switch outcome {
        case .success:
            jobs[index].status = .done
            jobs[index].sent = jobs[index].byteSize
            jobs[index].error = nil
            jobs[index].finishedAt = Date()
            let detail = jobs[index].attempts > 1 ? " after \(jobs[index].attempts) attempts" : ""
            appendLog("Uploaded \(jobs[index].identifier)/\(jobs[index].remotePath)\(detail)")
            if jobs[index].createsItem {
                jobs[index].createsItem = false   // unblock the rest of the item
            }
            onJobSucceeded?(jobs[index])
        case .failure(let message):
            jobs[index].status = .failed
            jobs[index].error = message
            appendLog("Failed \(jobs[index].remotePath): \(message)")
        case .cancelled:
            switch intent {
            case .pause:
                jobs[index].status = .paused
                jobs[index].sent = 0
                jobs[index].error = "Paused — restarts from the beginning"
            case .restart:
                reset(index)
                appendLog("Restarting \(jobs[index].remotePath)")
            case .remove:
                jobs.remove(at: index)
                pruneBatches()
            case .stop, .none:
                jobs[index].status = .cancelled
                jobs[index].sent = 0
                jobs[index].error = "Stopped"
            }
        }
        scheduleSave()
        pump()
    }

    private func cancel(_ id: UUID, intent: CancelIntent) {
        cancelIntent[id] = intent
        running[id]?.cancel()
    }

    private func reset(_ index: Int) {
        jobs[index].status = .queued
        jobs[index].sent = 0
        jobs[index].error = nil
        jobs[index].attempts = 0
        jobs[index].finishedAt = nil
    }

    private func progress(_ jobID: UUID, sent: Int64) {
        guard let index = index(of: jobID), jobs[index].status == .uploading else { return }
        let previous = jobs[index].sent
        let clamped = min(sent, jobs[index].byteSize)
        guard clamped > previous else { return }
        jobs[index].sent = clamped
        lastProgressAt[jobID] = Date()
        sentCounter += clamped - previous
        recordSample()
    }

    private func setAttempts(_ jobID: UUID, _ attempts: Int) {
        guard let index = index(of: jobID) else { return }
        jobs[index].attempts = attempts
        if attempts > 1 { jobs[index].sent = 0 }
    }

    private func setError(_ jobID: UUID, _ message: String?) {
        guard let index = index(of: jobID) else { return }
        jobs[index].error = message
    }

    private func recordSample() {
        let now = Date()
        samples.append((now, sentCounter))
        samples.removeAll { now.timeIntervalSince($0.date) > 6 }
        guard let first = samples.first else { return }
        let elapsed = now.timeIntervalSince(first.date)
        guard elapsed > 0.5 else { return }
        speedBytesPerSecond = Double(sentCounter - first.bytes) / elapsed
    }

    private func index(of id: UUID) -> Int? {
        jobs.firstIndex { $0.id == id }
    }

    private func pruneBatches() {
        let used = Set(jobs.map(\.batchID))
        batches.removeAll { !used.contains($0.id) }
    }

    func appendLog(_ message: String) {
        log.append(LogLine(date: Date(), message: message))
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
    }

    func clearLog() {
        log.removeAll()
    }

    /// Kicks the scheduler, e.g. after signing in.
    func resumeScheduling() {
        pump()
    }

    // MARK: - Headers

    static func headers(for job: UploadJob, credentials: ArchiveCredentials, options: UploadOptions) -> [String: String] {
        var headers: [String: String] = [:]
        headers["Authorization"] = credentials.authorizationHeader
        headers["x-amz-auto-make-bucket"] = "1"
        headers["x-archive-queue-derive"] = options.queueDerive ? "1" : "0"
        headers["x-archive-size-hint"] = String(job.byteSize)
        if options.interactivePriority {
            headers["x-archive-interactive-priority"] = "1"
        }
        if options.keepOldVersions {
            headers["x-archive-keep-old-version"] = "1"
        }
        for pair in job.metadataHeaders {
            headers[pair.name] = pair.value
        }
        headers["Content-Type"] = job.contentType ?? "application/octet-stream"
        return headers
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var jobs: [UploadJob]
        var batches: [UploadBatch]
        var isPaused: Bool
    }

    private static var fileURL: URL {
        AppPaths.file("queue.json")
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard persistent else { return }
        // Running uploads come back as waiting: their PUT restarts from zero.
        let persisted = jobs.map { job -> UploadJob in
            var copy = job
            if copy.status == .uploading {
                copy.status = .queued
                copy.sent = 0
            }
            return copy
        }
        let snapshot = Snapshot(jobs: persisted, batches: batches, isPaused: isPaused)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let directory = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: Self.fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    private func scheduleSave() {
        guard persistent else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        jobs = snapshot.jobs.map { job in
            var copy = job
            if copy.status == .uploading { copy.status = .queued; copy.sent = 0 }
            return copy
        }
        batches = snapshot.batches
        // Never start uploading by surprise after a relaunch: unfinished work
        // comes back paused and the status bar offers Resume.
        if jobs.contains(where: { $0.status == .queued }) {
            for index in jobs.indices where jobs[index].status == .queued {
                jobs[index].status = .paused
                jobs[index].error = nil
            }
            isPaused = true
            appendLog("Restored \(jobs.filter { $0.status == .paused }.count) unfinished upload(s) from the last session. Press Resume to continue.")
        } else {
            isPaused = snapshot.isPaused
        }
    }

    /// Cancels in-flight requests on quit.
    func shutdown() {
        saveNow()
        for task in running.values { task.cancel() }
        transport.cancelAll()
    }
}
