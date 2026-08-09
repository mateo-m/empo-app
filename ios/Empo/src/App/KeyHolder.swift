import Foundation

/// One physical input holding one game key.
///
/// Touch buttons, controller elements and keyboard keys all press the
/// same small set of game keys, so each press names itself and the
/// engine only sees a release once the last holder lets go.
struct KeyHolder: Hashable {
    enum Source: Hashable {
        case touch
        case controller
        case keyboard
    }

    let source: Source
    /// Identifies the button, element or key inside its source.
    let id: String

    static func touch(_ id: String) -> KeyHolder { KeyHolder(source: .touch, id: id) }
    static func controller(_ id: String) -> KeyHolder { KeyHolder(source: .controller, id: id) }
    static func keyboard(_ scancode: Int32) -> KeyHolder {
        KeyHolder(source: .keyboard, id: String(scancode))
    }
}
