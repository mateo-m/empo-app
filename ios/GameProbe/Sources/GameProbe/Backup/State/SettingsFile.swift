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
}
