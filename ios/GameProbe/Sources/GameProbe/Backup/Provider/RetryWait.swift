import Foundation

/// The wait before a retry after a throttle, per 8.6 and 9.3.
public enum RetryWait {

    public static let backoffCeilingSeconds: TimeInterval = 64

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
        if let seconds = TimeInterval(text), seconds > 0 { return seconds }
        guard let date = ProviderDate.httpReader()(text) else { return nil }
        let wait = date.timeIntervalSince(now)
        return wait > 0 ? wait : nil
    }

    public static func seconds(
        retryAfter header: String?, attempt: Int, now: Date = Date()
    ) -> TimeInterval {
        headerSeconds(header, now: now) ?? backoffSeconds(attempt: attempt)
    }
}
