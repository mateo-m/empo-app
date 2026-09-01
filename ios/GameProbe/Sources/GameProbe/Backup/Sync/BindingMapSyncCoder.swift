import Foundation

/// One global controller binding per document leaf, per SPEC 10.3.
///
/// The binding id is the source name, which is what the stored map
/// keys by, so two devices that bind different buttons never touch
/// one leaf.
public enum BindingMapSyncCoder {

    public static func entries(of map: BindingMap) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (source, target) in map.entries {
            out[source.name] = target.name.map(JSONValue.string) ?? .null
        }
        return out
    }

    public static func map(of entries: [String: JSONValue]) -> BindingMap {
        var out: [BindingSource: ControlsTarget] = [:]
        for (name, value) in entries {
            guard let source = BindingSource(name: name) else { continue }
            switch value {
            case .null:
                out[source] = .unbound
            case .string(let target):
                guard let parsed = ControlsTarget(name: target) else { continue }
                out[source] = parsed
            default:
                continue
            }
        }
        return BindingMap(entries: out)
    }
}
