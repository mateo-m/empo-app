import Foundation

public enum SettingsFile {
    /// `nil` only when no file is there. Any other read error throws,
    /// so a caller never saves an empty value over a file it could
    /// not read.
    public static func data(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// A file that reads but does not decode gives `empty`, and its
    /// bytes get a copy named by their hash. The next save writes over
    /// the file. A move would race a second reader, and could take a
    /// good file that another reader saved after this read.
    public static func value<Value>(
        at url: URL, empty: () -> Value, decode: (Data) throws -> Value
    ) throws -> Value {
        guard let data = try data(at: url) else { return empty() }
        do {
            return try decode(data)
        } catch is DecodingError {
            try data.write(
                to: url.deletingLastPathComponent().appendingPathComponent(
                    "\(url.lastPathComponent).damaged-\(ContentHash.hex(of: data).prefix(16))"),
                options: .atomic)
            return empty()
        }
    }
}
