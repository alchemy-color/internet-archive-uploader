import Foundation

/// Performs single IAS3 PUT requests over one long-lived URLSession.
/// Retries, scheduling, pausing and restarting live in `UploadQueue`;
/// this type only moves bytes and reports progress.
final class UploadTransport: @unchecked Sendable {
    private let delegate: UploadSessionDelegate
    private let session: URLSession

    init(userAgent: String = UploadOptions.default.userAgent) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]

        let delegate = UploadSessionDelegate()
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.session = self.session
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Uploads `fileURL` with a PUT. Cancelling the calling task aborts the
    /// request immediately and throws `CancellationError`.
    func put(
        url: URL,
        fileURL: URL,
        headers: [String: String],
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (HTTPURLResponse, Data) {
        try await delegate.upload(url: url, fileURL: fileURL, headers: headers, onProgress: onProgress)
    }

    func cancelAll() {
        delegate.cancelAll()
    }

    // MARK: Error messages

    static func friendlyMessage(status: Int, error: S3Error?, identifier: String) -> String {
        switch error?.code {
        case "InvalidAccessKeyId", "SignatureDoesNotMatch", "InvalidSecurity":
            return "Authentication failed. Your archive.org keys may have been regenerated. Sign in again."
        case "AccessDenied":
            return "Access denied. The collection may not be writable by your account, or the identifier belongs to someone else."
        case "SlowDown":
            return "archive.org is busy right now (SlowDown)."
        case "BucketAlreadyExists", "BucketAlreadyOwnedByYou":
            return "That identifier is already taken by another item."
        case "RequestTimeTooSkewed":
            return "Your Mac's clock is too far from archive.org's clock. Check the date and time settings."
        case let code?:
            if let message = error?.message {
                return "\(code): \(message) (HTTP \(status))"
            }
            return "The upload failed with \(code) (HTTP \(status))."
        case nil:
            break
        }
        switch status {
        case 401, 403:
            return "archive.org rejected the upload (HTTP \(status)). Check your sign-in and collection permissions."
        case 400:
            return "archive.org rejected the request (HTTP 400). Check the item identifier and metadata."
        case 409:
            return "Conflict (HTTP 409). The identifier may already be taken."
        case 500...599:
            return "archive.org had a server error (HTTP \(status))."
        default:
            return "The upload failed with HTTP \(status)."
        }
    }

    static func friendlyNetworkMessage(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "You appear to be offline."
        case .timedOut: return "The connection timed out."
        case .networkConnectionLost: return "The network connection was lost."
        case .cannotFindHost, .dnsLookupFailed: return "Could not reach s3.us.archive.org."
        case .fileDoesNotExist, .noPermissionsToReadFile: return "The local file can no longer be read."
        default: return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Progress throttling

final class ProgressThrottler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmit: [UUID: TimeInterval] = [:]
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.15) {
        self.interval = interval
    }

    func shouldEmit(_ id: UUID) -> Bool {
        let now = Date.timeIntervalSinceReferenceDate
        lock.lock()
        defer { lock.unlock() }
        if let last = lastEmit[id], now - last < interval {
            return false
        }
        lastEmit[id] = now
        return true
    }
}

// MARK: - URLSession delegate

private final class UploadSessionDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    weak var session: URLSession?

    private struct Context {
        let headers: [String: String]
        let onProgress: @Sendable (Int64, Int64) -> Void
        let continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>
        var body: Data
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: URLSessionTask?
        private var cancelled = false

        func set(_ task: URLSessionTask) -> Bool {
            lock.lock(); defer { lock.unlock() }
            storage = task
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = storage
            lock.unlock()
            task?.cancel()
        }
    }

    private let lock = NSLock()
    private var contexts: [Int: Context] = [:]
    private var activeTasks: [Int: URLSessionTask] = [:]

    func upload(
        url: URL,
        fileURL: URL,
        headers: [String: String],
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let box = TaskBox()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>) in
                guard let session else {
                    continuation.resume(throwing: URLError(.unknown))
                    return
                }
                let task = session.uploadTask(with: request, fromFile: fileURL)
                self.register(task, context: Context(headers: headers, onProgress: onProgress, continuation: continuation, body: Data()))
                let alreadyCancelled = box.set(task)
                task.resume()
                if alreadyCancelled { task.cancel() }
            }
        }, onCancel: {
            box.cancel()
        })
    }

    private func register(_ task: URLSessionTask, context: Context) {
        lock.lock()
        contexts[task.taskIdentifier] = context
        activeTasks[task.taskIdentifier] = task
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let tasks = Array(activeTasks.values)
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        lock.lock()
        let context = contexts[task.taskIdentifier]
        lock.unlock()
        context?.onProgress(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let headers = contexts[task.taskIdentifier]?.headers
        lock.unlock()
        // Never send the S3 keys anywhere but archive.org over HTTPS.
        guard ArchiveHosts.isTrusted(request.url) else {
            completionHandler(nil)
            return
        }
        guard let headers, !headers.isEmpty else {
            completionHandler(request)
            return
        }
        var redirected = request
        for (key, value) in headers where key.lowercased() != "content-length" {
            redirected.setValue(value, forHTTPHeaderField: key)
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        if var context = contexts[dataTask.taskIdentifier] {
            context.body.removeAll(keepingCapacity: true)
            contexts[dataTask.taskIdentifier] = context
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if var context = contexts[dataTask.taskIdentifier], context.body.count < 32_768 {
            context.body.append(data.prefix(32_768 - context.body.count))
            contexts[dataTask.taskIdentifier] = context
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let context = contexts.removeValue(forKey: task.taskIdentifier)
        activeTasks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        guard let context else { return }
        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                context.continuation.resume(throwing: CancellationError())
            } else {
                context.continuation.resume(throwing: error)
            }
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            context.continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        context.continuation.resume(returning: (response, context.body))
    }
}
