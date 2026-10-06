import Foundation

/// The keys and the ids of the on-target layout, per SPEC 5.1 and
/// 5.2.
///
/// ```
/// Empo/
///   format.json
///   devices/<namespaceId>/
///     blobs/<xx>/<hash>
///     games/<gameKey>/<snapshotId>.json
///     prefs/<snapshotId>.json
/// ```
public enum BackupKeys {

    // MARK: - Game key

    /// The hex SHA-256 of the exact container folder name, per 5.2.
    ///
    /// The name itself never reaches a path. A game identity is a
    /// sanitized game title, so it can hold unicode, spaces, and
    /// characters a provider rejects, and Dropbox folds case, which
    /// would collide two titles that differ only in case. The
    /// manifest carries the exact name, so the match ladder of 4.2
    /// still runs on the device.
    public static func gameKey(containerFolderName: String) -> String {
        ContentHash.hex(ofUTF8: containerFolderName)
    }

    // MARK: - Snapshot id

    /// How many hex characters close a snapshot id.
    public static let snapshotSuffixLength = 6

    /// `<UTC yyyymmddTHHMMSSZ>-<6 hex>`, which sorts by name, per
    /// 5.2. Seconds truncate, and the suffix separates two snapshots
    /// of the same second.
    public static func snapshotId(date: Date, suffix: String) -> String {
        let parts = utcParts(of: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ-%@",
            parts.year, parts.month, parts.day,
            parts.hour, parts.minute, parts.second, suffix)
    }

    /// A snapshot id for `date` with a fresh random suffix.
    public static func makeSnapshotId(date: Date) -> String {
        snapshotId(date: date, suffix: randomHex(characters: snapshotSuffixLength))
    }

    /// The UTC second a snapshot id names, or `nil` when the id does
    /// not carry the form of 5.2.
    public static func timestamp(ofSnapshotId id: String) -> Date? {
        let characters = Array(id)
        guard characters.count == 16 + 1 + snapshotSuffixLength else { return nil }
        guard characters[8] == "T", characters[15] == "Z", characters[16] == "-" else {
            return nil
        }
        guard characters[0..<8].allSatisfy(\.isASCIIDigit),
            characters[9..<15].allSatisfy(\.isASCIIDigit),
            characters[17...].allSatisfy(\.isLowercaseHexDigit)
        else { return nil }

        func number(_ range: Range<Int>) -> Int {
            Int(String(characters[range])) ?? 0
        }
        var components = DateComponents()
        components.year = number(0..<4)
        components.month = number(4..<6)
        components.day = number(6..<8)
        components.hour = number(9..<11)
        components.minute = number(11..<13)
        components.second = number(13..<15)
        return utcCalendar.date(from: components)
    }

    // MARK: - Blob path

    /// `blobs/<first characters of the hash>/<hash>`, per 5.1.
    ///
    /// The width comes from `format.json`, per 15.3. A reader must
    /// never assume it.
    public static func blobPath(hash: String, fanOutWidth: Int) -> String {
        guard fanOutWidth > 0, hash.count > fanOutWidth else {
            return "blobs/\(hash)"
        }
        let prefix = hash.prefix(fanOutWidth)
        return "blobs/\(prefix)/\(hash)"
    }

    /// The hash a blob path names, or `nil` when the path is not a
    /// blob path.
    ///
    /// The check is strict, because the sweep of 5.11 deletes what
    /// this function names. A file a provider or a desktop tool
    /// dropped beside the blobs, `blobs/ab/.DS_Store` for one, names
    /// no hash, so the sweep leaves it alone.
    public static func blobHash(atPath path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count == 2 || parts.count == 3, parts[0] == "blobs" else {
            return nil
        }
        let name = parts[parts.count - 1]
        guard !name.isEmpty, name.allSatisfy(\.isLowercaseHexDigit) else { return nil }
        if parts.count == 3 {
            // The fan-out folder is the start of the hash, per 5.1.
            guard name.hasPrefix(parts[1]) else { return nil }
        }
        return String(name)
    }

    // MARK: - Namespace id

    /// A namespace id for this install, per 5.2. Ticket 002 stores
    /// it in the Keychain without `kSecAttrSynchronizable`, so it
    /// never rides iCloud Keychain to a second device.
    public static func makeNamespaceId() -> String {
        randomHex(characters: 32)
    }

    // MARK: - Helpers

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private static func utcParts(
        of date: Date
    ) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        let parts = utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return (
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    static func randomHex(characters: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        var out = ""
        out.reserveCapacity(characters)
        while out.count < characters {
            let block = String(generator.next(), radix: 16)
            out += String(repeating: "0", count: 16 - block.count) + block
        }
        return String(out.prefix(characters))
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool {
        self >= "0" && self <= "9"
    }

    fileprivate var isLowercaseHexDigit: Bool {
        isASCIIDigit || (self >= "a" && self <= "f")
    }
}
