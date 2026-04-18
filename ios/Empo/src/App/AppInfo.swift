import Foundation

/// App metadata read from the Info.plist at runtime.
///
/// The source of truth is `PRODUCT_NAME` in `project.yml`, which xcodegen
/// substitutes into `CFBundleName`. Keeping user-facing strings behind
/// this helper means renaming the app is a one-line change in
/// `project.yml` rather than a repo-wide sed.
enum AppInfo {
    /// The app's display name (e.g. "Empo"). Falls back to a literal
    /// when the plist key is missing, which shouldn't happen in
    /// practice but avoids crashes in unusual linker configurations.
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
}
