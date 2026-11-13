import Foundation

enum RetryPolicy {
    static let retryableStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504]
    static let maxDelay: TimeInterval = 60

    static func shouldRetry(status: Int) -> Bool {
        retryableStatuses.contains(status)
    }

    static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .resourceUnavailable,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Exponential backoff with a little jitter. `attempt` is 1-based.
    static func delay(forAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter, retryAfter > 0 {
            return min(max(retryAfter, 1), maxDelay)
        }
        let exponential = pow(2, Double(max(1, attempt)))
        let jitter = Double.random(in: 0...0.6)
        return min(exponential + jitter, maxDelay)
    }

    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) {
            return min(max(seconds, 0), 300)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return min(max(date.timeIntervalSinceNow, 0), 300)
        }
        return nil
    }
}
