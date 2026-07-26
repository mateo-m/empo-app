import Foundation

/// Persisted identity of the runtime a game is assigned to.
/// Stored in `Metadata/metadata.json` as `coreKind` (see
/// `GameMetadata`) and mapped to a live `GameCore` through
/// `CoreRegistry`.
///
/// Any value outside the first-class cases decodes as
/// `.unsupported(raw:)` and encodes back to the same raw string,
/// so metadata written by a future Empo build with a core this
/// build doesn't know about round-trips losslessly instead of
/// breaking the decode. Same forward-compat pattern as
/// `JgpRuntime` in `Jgp.swift`.
enum CoreKind: Codable, Equatable, Sendable {
    case mkxp  // RGSS 1/2/3 via mkxp-z-apple-mobile
    case rmWeb  // RPG Maker MV/MZ via WKWebView + NW.js shim
    case unsupported(raw: String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "mkxp": self = .mkxp
        case "rmWeb": self = .rmWeb
        default: self = .unsupported(raw: raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .mkxp: try c.encode("mkxp")
        case .rmWeb: try c.encode("rmWeb")
        case .unsupported(let r): try c.encode(r)
        }
    }

    var displayName: String {
        switch self {
        case .mkxp: "mkxp-z"
        case .rmWeb: "RPG Maker Web (MV/MZ)"
        case .unsupported(let r): r
        }
    }
}
