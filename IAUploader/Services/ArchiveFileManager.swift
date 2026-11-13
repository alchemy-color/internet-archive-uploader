import Foundation

/// File-level operations against an existing archive.org item:
/// download, delete, copy, and move/rename. All network calls go through
/// IAS3 or the public download endpoint.
final class ArchiveFileManager {
    let credentials: ArchiveCredentials
    private let session: URLSession

    init(credentials: ArchiveCredentials) {
        self.credentials = credentials
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.waitsForConnectivity = true
        configuration.httpAdditionalHeaders = ["User-Agent": "InternetArchiveUploader/1.0 (macOS)"]
        self.session = URLSession(configuration: configuration, delegate: ArchiveRedirectGuard.shared, delegateQueue: nil)
    }

    // MARK: Download

    /// Downloads a single remote file into `directory`, preserving the
    /// relative path. Returns the local file URL.
    func download(item: String, remotePath: String, to directory: URL) async throws -> URL {
        let encoded = RemotePath.encoded(remotePath)
        guard let url = URL(string: "https://archive.org/download/\(item)/\(encoded)") else {
            throw ArchiveError.unexpectedResponse("Could not build the download URL.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 300

        let (temporaryURL, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw ArchiveError.server("Download failed with HTTP \(status).")
        }

        let destination = directory.appendingPathComponent(remotePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    // MARK: Delete

    func delete(item: String, remotePath: String) async throws {
        let encoded = RemotePath.encoded(remotePath)
        guard let url = URL(string: "https://s3.us.archive.org/\(item)/\(encoded)") else {
            throw ArchiveError.unexpectedResponse("Could not build the delete URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "x-archive-cascade-delete")

        let (data, status) = try await send(request)
        // 404 means it is already gone, which is what we wanted.
        guard (200...299).contains(status) || status == 404 else {
            throw ArchiveError.server(Self.describe("Delete of \(remotePath)", status: status, data: data))
        }
    }

    // MARK: Copy / Move

    /// Server-side copy of a file within (or across) items using IAS3.
    func copy(item: String, from sourcePath: String, to destinationPath: String) async throws {
        let encodedDestination = RemotePath.encoded(destinationPath)
        guard let url = URL(string: "https://s3.us.archive.org/\(item)/\(encodedDestination)") else {
            throw ArchiveError.unexpectedResponse("Could not build the copy URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "x-amz-auto-make-bucket")
        request.setValue("/\(item)/\(RemotePath.encoded(sourcePath))", forHTTPHeaderField: "x-amz-copy-source")
        request.setValue("COPY", forHTTPHeaderField: "x-amz-metadata-directive")

        let (data, status) = try await send(request)
        guard (200...299).contains(status) else {
            throw ArchiveError.server(Self.describe("Copy of \(sourcePath)", status: status, data: data))
        }
    }

    /// Optional hook so the UI can show "archive.org is busy, retrying in 20s".
    var onRetry: (@Sendable (String) -> Void)?

    /// Sends a write request, retrying SlowDown / 5xx / network errors with
    /// backoff. archive.org rate-limits per account, so while big uploads run
    /// copy/delete requests often get HTTP 503 SlowDown at first.
    private func send(_ request: URLRequest, maxAttempts: Int = 8) async throws -> (Data, Int) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                let slowDown = S3ErrorParser.parse(data)?.code == "SlowDown"
                if (RetryPolicy.shouldRetry(status: status) || slowDown), attempt < maxAttempts {
                    let delay = max(5, RetryPolicy.delay(forAttempt: attempt, retryAfter: http.flatMap(RetryPolicy.retryAfter(from:))))
                    onRetry?("archive.org is busy (HTTP \(status)). Retrying in \(Int(delay))s…")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                return (data, status)
            } catch let error as URLError where RetryPolicy.isRetryable(error) && attempt < maxAttempts {
                let delay = RetryPolicy.delay(forAttempt: attempt)
                onRetry?("Network problem. Retrying in \(Int(delay))s…")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private static func describe(_ action: String, status: Int, data: Data) -> String {
        if let error = S3ErrorParser.parse(data), let code = error.code {
            return "\(action) failed: \(code)\(error.message.map { " – \($0)" } ?? "") (HTTP \(status))."
        }
        return "\(action) failed with HTTP \(status)."
    }

    /// Server-side move: copy to the new path, then delete the old one.
    /// archive.org has no native rename.
    func move(item: String, from sourcePath: String, to destinationPath: String) async throws {
        try await copy(item: item, from: sourcePath, to: destinationPath)
        try await delete(item: item, remotePath: sourcePath)
    }
}
