import Foundation

enum ArchiveError: LocalizedError, Equatable {
    case invalidCredentials(String)
    case network(String)
    case server(String)
    case unexpectedResponse(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidCredentials(let message): return message
        case .network(let message): return message
        case .server(let message): return message
        case .unexpectedResponse(let message): return message
        case .notFound: return "That item does not exist."
        }
    }
}

struct RemoteFile: Sendable, Equatable, Hashable {
    let name: String
    let size: Int64?
    let md5: String?
    let source: String?
}

struct RemoteItem: Sendable, Equatable {
    let identifier: String
    let title: String?
    let fileCount: Int
    let itemSize: Int64?
    let isDark: Bool
}

/// Talks to the public archive.org endpoints that are not part of IAS3:
/// xauthn login and the metadata read API.
final class ArchiveClient: @unchecked Sendable {
    static let shared = ArchiveClient()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = true
            configuration.httpAdditionalHeaders = ["User-Agent": "InternetArchiveUploader/1.0 (macOS)"]
            self.session = URLSession(configuration: configuration, delegate: ArchiveRedirectGuard.shared, delegateQueue: nil)
        }
    }

    func login(email: String, password: String) async throws -> ArchiveCredentials {
        guard let url = URL(string: "https://archive.org/services/xauthn/?op=login") else {
            throw ArchiveError.unexpectedResponse("Could not build the sign-in URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncode([
            ("email", email),
            ("password", password)
        ]).data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ArchiveError.network(Self.friendlyNetworkMessage(error))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let payload = try? JSONDecoder().decode(LoginPayload.self, from: data) else {
            let snippet = String(data: data.prefix(160), encoding: .utf8) ?? ""
            if status >= 500 {
                throw ArchiveError.server("archive.org is having trouble right now. Try again in a moment.")
            }
            throw ArchiveError.unexpectedResponse("Unexpected response from archive.org. \(snippet)".trimmingCharacters(in: .whitespaces))
        }

        guard payload.success, let values = payload.values, let s3 = values.s3 else {
            throw ArchiveError.invalidCredentials(Self.loginFailureMessage(reason: payload.values?.reason ?? payload.error))
        }
        guard s3.access.trimmedNonEmpty != nil, s3.secret.trimmedNonEmpty != nil else {
            throw ArchiveError.invalidCredentials("archive.org did not return S3 keys for this account. Check your account settings, then try again.")
        }

        return ArchiveCredentials(
            accessKey: s3.access,
            secretKey: s3.secret,
            screenName: values.screenname,
            email: email,
            itemName: values.itemname
        )
    }

    /// Returns `true` when the identifier is already used by an item.
    func itemExists(_ identifier: String) async throws -> Bool {
        let item = try await fetchItem(identifier, allowMissing: true)
        return item != nil
    }

    func fetchItem(_ identifier: String, allowMissing: Bool = false) async throws -> RemoteItem? {
        guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://archive.org/metadata/\(encoded)") else {
            throw ArchiveError.unexpectedResponse("That identifier cannot be used in a URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ArchiveError.network(Self.friendlyNetworkMessage(error))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            if allowMissing { return nil }
            throw ArchiveError.notFound
        }
        guard status == 200 else {
            throw ArchiveError.server("archive.org returned HTTP \(status).")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ArchiveError.unexpectedResponse("Could not read the response from archive.org.")
        }
        guard let metadata = object["metadata"] as? [String: Any], !metadata.isEmpty else {
            if allowMissing { return nil }
            throw ArchiveError.notFound
        }

        let files = object["files"] as? [[String: Any]] ?? []
        let size = (object["item_size"] as? NSNumber)?.int64Value
        let isDark = (object["is_dark"] as? Bool) ?? ((metadata["is_dark"] as? String) == "true")
        return RemoteItem(
            identifier: (metadata["identifier"] as? String) ?? identifier,
            title: metadata["title"] as? String,
            fileCount: files.count,
            itemSize: size,
            isDark: isDark
        )
    }

    func fetchItemFiles(_ identifier: String) async throws -> [RemoteFile] {
        let item = try await fetchItem(identifier, allowMissing: false)
        _ = item
        guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://archive.org/metadata/\(encoded)") else {
            throw ArchiveError.unexpectedResponse("That identifier cannot be used in a URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ArchiveError.network(Self.friendlyNetworkMessage(error))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ArchiveError.server("archive.org returned HTTP \(status).")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["files"] as? [[String: Any]] else {
            return []
        }
        return files.compactMap { entry -> RemoteFile? in
            guard let name = entry["name"] as? String else { return nil }
            let size = (entry["size"] as? NSNumber)?.int64Value
                ?? (entry["size"] as? String).flatMap { Int64($0) }
            return RemoteFile(
                name: name,
                size: size,
                md5: entry["md5"] as? String,
                source: entry["source"] as? String
            )
        }
    }
        func fetchRawMetadata(_ identifier: String) async throws -> [String: Any] {
        let item = try await fetchItem(identifier, allowMissing: false)
        _ = item
        guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://archive.org/metadata/\(encoded)") else {
            throw ArchiveError.unexpectedResponse("That identifier cannot be used in a URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ArchiveError.server("archive.org returned HTTP \(status).") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = object["metadata"] as? [String: Any] else {
            return [:]
        }
        return metadata
    }

    func writeMetadata(identifier: String, newMetadata: ItemMetadata, previous: ItemMetadata? = nil, credentials: ArchiveCredentials) async throws {
        let old = try await fetchRawMetadata(identifier)
        let newDict = Self.metadataDictionary(for: newMetadata)

        var operations: [[String: Any]] = []
        // Only touch fields this editor manages. Everything else on the item
        // (mediatype, collection, scanner, custom keys…) is left untouched —
        // diffing against all keys used to emit "remove" for them.
        var managedKeys: Set<String> = ["title", "creator", "description", "date", "subject", "language", "licenseurl"]
        for field in newMetadata.customFields where field.isValidKey { managedKeys.insert(field.normalizedKey) }
        // Custom fields the user deleted in the editor must be removed too.
        for field in previous?.customFields ?? [] where field.isValidKey { managedKeys.insert(field.normalizedKey) }
        for key in managedKeys.sorted() {
            let oldValue = old[key]
            let newValue = newDict[key]
            if oldValue == nil && newValue != nil {
                operations.append(["op": "add", "path": "/\(key)", "value": newValue!])
            } else if oldValue != nil && newValue == nil {
                operations.append(["op": "remove", "path": "/\(key)"])
            } else if oldValue != nil && newValue != nil && !Self.jsonEqual(oldValue!, newValue!) {
                operations.append(["op": "replace", "path": "/\(key)", "value": newValue!])
            }
        }
        guard !operations.isEmpty else { return }

        let patch: Any = operations.count == 1 ? operations[0] : operations
        let patchData = try JSONSerialization.data(withJSONObject: patch)
        let patchString = String(data: patchData, encoding: .utf8) ?? "[]"

        guard let url = URL(string: "https://archive.org/metadata/\(identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier)") else {
            throw ArchiveError.unexpectedResponse("Could not build the metadata URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        let body = ArchiveClient.formEncode([
            ("-target", "metadata"),
            ("-patch", patchString)
        ])
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ArchiveError.server(message ?? "Metadata update failed with HTTP \(status).")
        }
    }

    private static func metadataDictionary(for metadata: ItemMetadata) -> [String: Any] {
        var dict: [String: Any] = [:]
        if !metadata.title.trimmingCharacters(in: .whitespaces).isEmpty { dict["title"] = metadata.title }
        if !metadata.creator.trimmingCharacters(in: .whitespaces).isEmpty { dict["creator"] = metadata.creator }
        if !metadata.descriptionText.trimmingCharacters(in: .whitespaces).isEmpty { dict["description"] = metadata.descriptionText }
        if !metadata.date.trimmingCharacters(in: .whitespaces).isEmpty { dict["date"] = metadata.date }
        if !metadata.parsedSubjects.isEmpty { dict["subject"] = metadata.parsedSubjects }
        if !metadata.effectiveCollections.isEmpty { dict["collection"] = metadata.effectiveCollections }
        if !metadata.language.trimmingCharacters(in: .whitespaces).isEmpty { dict["language"] = metadata.language }
        if !metadata.licenseURL.trimmingCharacters(in: .whitespaces).isEmpty { dict["licenseurl"] = metadata.licenseURL }
        for field in metadata.customFields where field.isValidKey && !field.value.trimmingCharacters(in: .whitespaces).isEmpty {
            dict[field.normalizedKey] = field.value
        }
        return dict
    }

    private static func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        guard let l = try? JSONSerialization.data(withJSONObject: lhs),
              let r = try? JSONSerialization.data(withJSONObject: rhs) else {
            return String(describing: lhs) == String(describing: rhs)
        }
        return l == r
    }
        func searchUploads(by uploader: String) async throws -> [RemoteItem] {
        let query = "uploader:\"\(uploader)\""
        var components = URLComponents(string: "https://archive.org/advancedsearch.php")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "mediatype"),
            URLQueryItem(name: "sort[]", value: "addeddate desc"),
            URLQueryItem(name: "rows", value: "50"),
            URLQueryItem(name: "output", value: "json")
        ]
        guard let url = components.url else { throw ArchiveError.unexpectedResponse("Could not build the search URL.") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ArchiveError.server("archive.org returned HTTP \(status).") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseObj = object["response"] as? [String: Any],
              let docs = responseObj["docs"] as? [[String: Any]] else {
            return []
        }
        return docs.compactMap { doc in
            guard let id = doc["identifier"] as? String else { return nil }
            return RemoteItem(
                identifier: id,
                title: doc["title"] as? String,
                fileCount: 0,
                itemSize: nil,
                isDark: false
            )
        }
    }
        private static func loginFailureMessage(reason: String?) -> String {
        switch reason {
        case "account_not_found":
            return "No Internet Archive account was found for that email address."
        case "account_bad_password":
            return "Incorrect password. Please try again."
        case "account_locked":
            return "This account is locked. Please contact archive.org support."
        case "account_not_verified":
            return "This account has not been verified yet. Check your inbox for the verification email."
        case .some(let reason) where !reason.isEmpty:
            return "Sign-in failed: \(reason.replacingOccurrences(of: "_", with: " "))."
        default:
            return "Sign-in failed. Check your email and password, then try again."
        }
    }

    private static func friendlyNetworkMessage(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "You appear to be offline. Connect to the internet and try again."
        case .timedOut:
            return "archive.org did not respond in time. Try again."
        case .cannotFindHost, .dnsLookupFailed:
            return "Could not reach archive.org. Check your network connection."
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "The secure connection to archive.org failed."
        default:
            return "Network error: \(error.localizedDescription)"
        }
    }

    static func formEncode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct LoginPayload: Decodable {
    struct Values: Decodable {
        struct S3: Decodable {
            let access: String
            let secret: String
        }
        let s3: S3?
        let screenname: String?
        let itemname: String?
        let reason: String?
        let cookies: [String: String]?
    }

    let success: Bool
    let values: Values?
    let error: String?
}

// MARK: - Item task queue (requires the account's S3 keys)

/// archive.org's processing queue for one item. Uploads, deletes and copies
/// only show on the item page after their task finishes here.
struct ItemTaskStatus: Sendable, Equatable {
    struct Task: Sendable, Equatable, Identifiable {
        let id: Int
        let kind: String        // s3-put, s3-delete, derive, …
        let file: String?
        let state: String       // queued, running, paused, error
        let submitted: String?

        var description: String {
            switch kind {
            case "s3-put": return "Add uploaded file\(file.map { ": \($0)" } ?? "")"
            case "s3-delete": return "Delete \(file ?? "file")"
            case "derive.php", "derive": return "Make derivatives (thumbnails, streams)"
            default: return kind.isEmpty ? "Task" : kind
            }
        }
    }

    var queued = 0
    var running = 0
    var paused = 0
    var error = 0
    var tasks: [Task] = []
    var checkedAt = Date()

    var pending: Int { queued + running + paused + error }
    var needsAttention: Bool { paused > 0 || error > 0 }
}

extension ArchiveClient {
    func fetchTaskStatus(_ identifier: String, credentials: ArchiveCredentials) async throws -> ItemTaskStatus {
        func get(_ query: String) async throws -> [String: Any] {
            guard let id = identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://archive.org/services/tasks.php?identifier=\(id)&\(query)") else {
                throw ArchiveError.unexpectedResponse("Could not build the tasks URL.")
            }
            var request = URLRequest(url: url)
            request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: request, delegate: ArchiveRedirectGuard.shared)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ArchiveError.unexpectedResponse("Unexpected tasks response.")
            }
            guard object["success"] as? Bool == true, let value = object["value"] as? [String: Any] else {
                throw ArchiveError.server((object["error"] as? String) ?? "archive.org did not return the task list.")
            }
            return value
        }
        let value = try await get("summary=1&catalog=1&limit=200")
        var status = ItemTaskStatus()
        if let summary = value["summary"] as? [String: Any] {
            status.queued = (summary["queued"] as? Int) ?? 0
            status.running = (summary["running"] as? Int) ?? 0
            status.paused = (summary["paused"] as? Int) ?? 0
            status.error = (summary["error"] as? Int) ?? 0
        }
        for entry in (value["catalog"] as? [[String: Any]]) ?? [] {
            let args = entry["args"] as? [String: Any] ?? [:]
            let comment = (args["comment"] as? String) ?? (entry["cmd"] as? String) ?? ""
            status.tasks.append(.init(
                id: (entry["task_id"] as? Int) ?? 0,
                kind: comment,
                file: (args["delete_single_file"] as? String) ?? (args["file"] as? String),
                state: (entry["status"] as? String) ?? "queued",
                submitted: entry["submittime"] as? String
            ))
        }
        return status
    }
}
