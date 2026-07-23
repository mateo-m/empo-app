import Foundation

/// App metadata read from the Info.plist at runtime.
///
/// The source of truth is `PRODUCT_NAME` in `project.yml`, which xcodegen
/// substitutes into `CFBundleName`. This helper holds all user-facing
/// name strings. An app rename is then a one-line change in
/// `project.yml`, not a repo-wide sed.
enum AppInfo {
    /// The app's display name (e.g. "Empo"). Falls back to a literal
    /// when the plist key is missing. That case should not occur in
    /// practice, but the fallback avoids crashes in unusual linker
    /// configurations.
    static let name: String = {
        let info = Bundle.main.infoDictionary
        if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty {
            return display
        }
        if let bundle = info?["CFBundleName"] as? String, !bundle.isEmpty {
            return bundle
        }
        return "App"
    }()

    /// Marketing version string (e.g. "1.0").
    static let version: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }()

    /// Build number (e.g. "1").
    static let build: String = {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }()
}
