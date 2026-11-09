import Foundation

/// Each reader is a function, because one listing holds hundreds of stamps and one formatter
/// reads them all.
public enum ProviderDate {

    /// Some services add a fraction of a second and some do not.
    public static func rfc3339Reader() -> (String) -> Date? {
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        let fraction = ISO8601DateFormatter()
        fraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return { fraction.date(from: $0) ?? whole.date(from: $0) }
    }

    /// A few WebDAV servers write RFC 3339 where HTTP states an HTTP date, so this reads both.
    public static func httpReader() -> (String) -> Date? {
        let http = DateFormatter()
        http.locale = Locale(identifier: "en_US_POSIX")
        http.timeZone = TimeZone(secondsFromGMT: 0)
        http.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let rfc3339 = rfc3339Reader()
        return { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return http.date(from: trimmed) ?? rfc3339(trimmed)
        }
    }
}
