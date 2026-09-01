import Foundation
import GameProbe

/// The portable defaults this device holds now, per SPEC 10.1.
///
/// The allow-list decides what leaves. A game-scoped key of 10.2 is
/// not on the list, so it reaches neither `defaults.json`, the prefs
/// stream, nor the sync document.
@MainActor
enum DevicePreferences {

    /// The export file the prefs stream of 5.3 and the package of
    /// 12.2 both carry, written into staging.
    static func writeTheExportFile() -> URL? {
        let file = BackupRoot.layout.staging.appendingPathComponent("defaults.json")
        guard let data = try? PreferenceExport.document(of: currentDefaults(), at: Date())
        else { return nil }
        try? FileManager.default.createDirectory(
            at: BackupRoot.layout.staging, withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }

    static func currentDefaults() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
            guard PreferenceKeys.classOf(key) == .portable else { continue }
            guard let json = jsonValue(of: value) else { continue }
            out[key] = json
        }
        return out
    }

    /// Writes portable values back. A key outside the allow-list is
    /// dropped here too, so a document written by a newer build
    /// cannot set a key this build does not class.
    static func apply(_ values: [String: JSONValue]) {
        for (key, value) in values where PreferenceKeys.classOf(key) == .portable {
            guard let object = objectValue(of: value) else { continue }
            UserDefaults.standard.set(object, forKey: key)
        }
    }

    static func remove(_ keys: [String]) {
        for key in keys where PreferenceKeys.classOf(key) == .portable {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The UserDefaults value one JSON value stands for. It inverts
    /// `jsonValue(of:)`, including the base64 shape a `Data` value
    /// takes.
    private static func objectValue(of value: JSONValue) -> Any? {
        switch value {
        case .null: return nil
        case .bool(let flag): return flag
        case .int(let number): return number
        case .double(let number): return number
        case .string(let text): return text
        case .array(let list): return list.compactMap(objectValue(of:))
        case .object(let fields):
            if let base64 = fields["base64Data"]?.string, fields.count == 1 {
                return Data(base64Encoded: base64)
            }
            return fields.compactMapValues(objectValue(of:))
        }
    }

    private static func jsonValue(of value: Any) -> JSONValue? {
        switch value {
        case let number as NSNumber:
            // `Bool` and the integer types share one class here, so
            // the encoding tells them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if String(cString: number.objCType) == "d" { return .double(number.doubleValue) }
            return .int(number.intValue)
        case let text as String:
            return .string(text)
        case let data as Data:
            // A JSON document has no bytes type, so the value keeps
            // its own shape and says what it is.
            return .object(["base64Data": .string(data.base64EncodedString())])
        case let list as [Any]:
            return .array(list.compactMap(jsonValue(of:)))
        case let map as [String: Any]:
            return .object(map.compactMapValues(jsonValue(of:)))
        default:
            return nil
        }
    }
}
