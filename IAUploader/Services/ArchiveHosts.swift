import Foundation

/// The only hosts that ever receive the account's S3 keys.
enum ArchiveHosts {
    static func isTrusted(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "archive.org" || host.hasSuffix(".archive.org")
    }
}

/// URLSession delegate that drops redirects leaving archive.org, so an
/// `Authorization` header can never follow a redirect to another server.
final class ArchiveRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ArchiveRedirectGuard()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if ArchiveHosts.isTrusted(request.url) {
            completionHandler(request)
        } else {
            var stripped = request
            stripped.setValue(nil, forHTTPHeaderField: "Authorization")
            completionHandler(stripped)
        }
    }
}
