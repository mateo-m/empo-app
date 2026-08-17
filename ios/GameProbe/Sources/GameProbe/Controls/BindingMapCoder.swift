import Foundation

extension ControlsTarget {
    /// Text form in files and in stored maps. nil is the JSON null
    /// that spells an explicit unbind.
    public var name: String? {
        switch self {
        case .key(let code): return code
        case .element(let name): return name
        case .action(let id): return id
        case .unbound: return nil
        }
    }

    /// nil for a word in no vocabulary.
    public init?(name: String) {
        if name.hasPrefix("$") {
            // An unknown action still parses. Every load-modify-save
            // path rewrites the whole map, so dropping the entry here
            // would erase a binding written by a newer Empo.
            self = .action(name)
        } else if KeyCodeTable.scancode(for: name) != nil {
            self = .key(name)
        } else if ControllerElement.allNames.contains(name) {
            self = .element(name)
        } else {
            return nil
        }
    }
}

/// The one reader and writer of a bindings object, shared by the
/// manifest loader, the manifest writer and the app's own defaults
/// store. Each caller reports issues its own way. None of them gets
/// to invent a different grammar.
public enum BindingMapCoder {
    public enum Issue: Equatable, Sendable {
        /// Neither a controller element nor a key code.
        case unknownSource
        /// The value was not a string and not null.
        case targetNotText
        /// A word in no vocabulary.
        case unknownTarget(String)
        /// A `$action` this Empo does not know. The entry is KEPT.
        case unknownAction(String)
        /// An element bound to an element. One hop only, so this is
        /// dropped: a chain of elements could loop.
        case elementChain(String)
    }

    /// Entries with an issue other than `unknownAction` are dropped.
    public static func decode(
        _ object: [String: Any],
        report: (_ source: String, _ issue: Issue) -> Void = { _, _ in }
    ) -> BindingMap {
        var entries: [BindingSource: ControlsTarget] = [:]

        for (name, value) in object {
            guard let source = BindingSource(name: name) else {
                report(name, .unknownSource)
                continue
            }

            if value is NSNull {
                entries[source] = .unbound
                continue
            }

            guard let text = value as? String else {
                report(name, .targetNotText)
                continue
            }

            guard let target = ControlsTarget(name: text) else {
                report(name, .unknownTarget(text))
                continue
            }

            if case .action(let id) = target, !EmpoActionCatalog.allIDs.contains(id) {
                report(name, .unknownAction(id))
            }

            if case .element(let element) = target, source.isElement {
                report(name, .elementChain(element))
                continue
            }

            entries[source] = target
        }

        return BindingMap(entries: entries)
    }

    /// JSON object form, for `JSONSerialization`-backed storage.
    public static func encode(_ map: BindingMap) -> [String: Any] {
        var object: [String: Any] = [:]
        for (source, target) in map.entries {
            object[source.name] = target.name ?? NSNull()
        }
        return object
    }

    /// Vocabulary order, elements before keys. The manifest writer
    /// emits in this order, so a load-save round trip is byte stable.
    public static let sourceOrder: [BindingSource] =
        ControllerElement.allElements.map { .element($0) }
        + KeyCodeTable.allCodes.map { .key($0) }
}
