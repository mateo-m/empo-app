import Foundation

/// The line for `key` from the app's string catalog, with `arguments`
/// in its `%@` and `%lld` slots.
///
/// Where no catalog is loaded, as in the tests and on Linux, the key
/// is the English line. `String(localized:)` does not exist on Linux.
@usableFromInline
func screenText(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: .current, arguments: arguments)
}
