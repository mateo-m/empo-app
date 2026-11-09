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

    /// A file that reads but does not decode moves aside under a new
    /// name and gives `empty`. The next save then writes a new file
    /// and keeps the damaged bytes.
    public static func value<Value>(
        at url: URL, empty: () -> Value, decode: (Data) throws -> Value
    ) throws -> Value {
        guard let data = try data(at: url) else { return empty() }
        do {
            return try decode(data)
        } catch is DecodingError {
            try FileManager.default.moveItem(
                at: url,
                to: url.deletingLastPathComponent().appendingPathComponent(
                    "\(url.lastPathComponent).damaged-\(UUID().uuidString)"))
            return empty()
        }
    }
}
