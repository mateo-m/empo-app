import Foundation

/// The wait before a retry after a throttle, per 8.6 and 9.3.
public enum RetryWait {

    public static let backoffCeilingSeconds: TimeInterval = 64

    /// A far stated wait would overflow the sleep and the whole seconds of the stop line.
    public static let headerCeilingSeconds: TimeInterval = 3600

    /// Attempt 1 waits 1 second, and each next attempt waits twice as long, up to the ceiling.
    public static func backoffSeconds(attempt: Int) -> TimeInterval {
        let step = max(1, attempt)
        guard step < 32 else { return backoffCeilingSeconds }
        return min(backoffCeilingSeconds, TimeInterval(1 << (step - 1)))
    }

    /// HTTP states `Retry-After` as a count of seconds or as a date. `nil` means a missing,
    /// unreadable, or past value.
    public static func headerSeconds(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        let text = header.trimmingCharacters(in: .whitespaces)
        let wait: TimeInterval
        if let seconds = TimeInterval(text) {
            wait = seconds
        } else if let date = ProviderDate.httpReader()(text) {
            wait = date.timeIntervalSince(now)
        } else {
            return nil
        }
        guard wait.isFinite, wait > 0 else { return nil }
        return min(wait, headerCeilingSeconds)
    }

    public static func seconds(
        retryAfter header: String?, attempt: Int, now: Date = Date()
    ) -> TimeInterval {
        headerSeconds(header, now: now) ?? backoffSeconds(attempt: attempt)
    }
}
