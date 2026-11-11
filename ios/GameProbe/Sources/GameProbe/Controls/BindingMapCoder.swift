// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

extension ControlsTarget {
    public var name: String? {
        switch self {
        case .key(let code): return code
        case .element(let name): return name
        case .action(let id): return id
        case .unbound: return nil
        }
    }

    public init?(name: String) {
        if name.hasPrefix("$") {
            // An unknown action still parses. Every load-modify-save
            // path writes the whole map again. If the parser drops the
            // entry, the save erases a binding from a newer Empo.
            self = .action(name)
        } else {
            switch BindingSource(name: name) {
            case .key(let code): self = .key(code)
            case .element(let element): self = .element(element)
            case nil: return nil
            }
        }
    }
}

public enum BindingMapCoder {
    public enum Issue: Equatable, Sendable {
        case unknownSource
        case targetNotText
        case unknownTarget(String)
        /// The decoder keeps this entry.
        case unknownAction(String)
        /// The decoder drops this entry, because a chain of elements
        /// can loop.
        case elementChain(String)
    }

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

    public static func encode(_ map: BindingMap) -> [String: Any] {
        var object: [String: Any] = [:]
        for (source, target) in map.entries {
            object[source.name] = target.name ?? NSNull()
        }
        return object
    }

    /// The manifest writer emits in this order, so that a load-save
    /// round trip is byte stable.
    public static let sourceOrder: [BindingSource] =
        ControllerElement.allElements.map { .element($0) }
        + KeyCodeTable.allCodes.map { .key($0) }
}

extension BindingMap: Codable {
    public init(from decoder: Decoder) throws {
        let object = try decoder.singleValueContainer().decode([String: String?].self)
        self = BindingMapCoder.decode(object.mapValues { $0.map { $0 as Any } ?? NSNull() })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(BindingMapCoder.encode(self).mapValues { $0 as? String })
    }
}
