import Foundation
import Json5

public enum ControlsManifestLoader {
    public static let empoManifestRelativePath = "empo/controls.json"
    public static let rootManifestRelativePath = "controls.json"
    public static let kirinManifestRelativePath = KirinControlsTranslator.fileName
    public static let joiplayManifestRelativePath = JoiPlayControlsTranslator.fileName

    /// Legacy alias for the authoritative `empo/` location.
    public static let manifestRelativePath = empoManifestRelativePath

    private static let maxFileSize = 128 * 1024

    public enum ManifestLocation: String, Sendable, Equatable {
        case empo = "empo/controls.json"
        case root = "controls.json"
        case kirin = "kirin-touch-controls.json"
        case joiplay = "gamepad.json"
    }

    public struct LoadOutcome: Sendable {
        public var result: Result
        public var note: Note?

        public enum Note: Equatable, Sendable {
            case rootSkippedBecauseEmpoExists
            case kirinSkippedBecauseManifestExists
            case joiplaySkippedBecauseOtherSourceExists
            case rootUnclaimedNotObject
            case rootUnclaimedNoVersion
            case rootUnclaimedOversized
        }

        public init(result: Result, note: Note? = nil) {
            self.result = result
            self.note = note
        }
    }

    /// The file-format cap on key buttons + action buttons per
    /// orientation. Public: the app's add UI gates on the SAME
    /// value, so a saved layout can never fail V015 on its next
    /// load.
    public static let maxButtonsPerOrientation = 21

    /// Every finding code this loader can emit. Emission sites use
    /// the enum, so a new code cannot ship without appearing here.
    /// V021 is absent on purpose: W005 superseded it.
    public enum FindingCode: String, CaseIterable, Sendable {
        case v000 = "V000"
        case v001 = "V001"
        case v002 = "V002"
        case v010 = "V010"
        case v011 = "V011"
        case v012 = "V012"
        case v013 = "V013"
        case v014 = "V014"
        case v015 = "V015"
        case v020 = "V020"
        case w001 = "W001"
        case w002 = "W002"
        case w003 = "W003"
        case w004 = "W004"
        case w005 = "W005"
        case w006 = "W006"
        case k001 = "K001"
        case j001 = "J001"
    }

    /// Derived from the enum: the docs table and the uniqueness
    /// test read this, and it cannot drift from the emission sites.
    public static var emittedFindingCodes: [String] {
        FindingCode.allCases.map(\.rawValue)
    }

    public struct Result: Sendable {
        public var manifest: ControlsManifest?
        public var findings: [Finding]
        public var ignoredNewerVersion: Bool
        public var location: ManifestLocation?

        public init(
            manifest: ControlsManifest?,
            findings: [Finding],
            ignoredNewerVersion: Bool = false,
            location: ManifestLocation? = nil
        ) {
            self.manifest = manifest
            self.findings = findings
            self.ignoredNewerVersion = ignoredNewerVersion
            self.location = location
        }
    }

    public struct Finding: Equatable, Sendable {
        public enum Severity: Sendable {
            case error
            case warning
        }

        public var severity: Severity
        public var code: String
        public var path: String
        public var message: String

        public init(severity: Severity, code: String, path: String, message: String) {
            self.severity = severity
            self.code = code
            self.path = path
            self.message = message
        }

        /// Loader emission sites go through the typed code, so the
        /// emitted set and `emittedFindingCodes` cannot drift.
        init(severity: Severity, code: FindingCode, path: String, message: String) {
            self.init(
                severity: severity, code: code.rawValue, path: path, message: message)
        }
    }

    /// nil when no manifest location exists. Never throws for content
    /// problems. Those land in `findings`.
    public static func load(gameRoot: URL) -> LoadOutcome? {
        load(gameRoot: gameRoot, metrics: .reference)
    }

    public static func load(gameRoot: URL, metrics: TouchZoneMetrics) -> LoadOutcome? {
        let fileManager = FileManager.default
        let empoURL = gameRoot.appendingPathComponent(empoManifestRelativePath)
        let rootURL = gameRoot.appendingPathComponent(rootManifestRelativePath)
        let kirinURL = gameRoot.appendingPathComponent(kirinManifestRelativePath)
        let joiplayURL = gameRoot.appendingPathComponent(joiplayManifestRelativePath)
        let empoExists = fileManager.fileExists(atPath: empoURL.path)
        let rootExists = fileManager.fileExists(atPath: rootURL.path)
        let kirinExists = fileManager.fileExists(atPath: kirinURL.path)
        let joiplayExists = fileManager.fileExists(atPath: joiplayURL.path)

        guard empoExists || rootExists || kirinExists || joiplayExists else { return nil }

        if empoExists {
            let result = loadEmpo(at: empoURL)
            let note: LoadOutcome.Note? =
                if rootExists {
                    .rootSkippedBecauseEmpoExists
                } else if kirinExists {
                    .kirinSkippedBecauseManifestExists
                } else if joiplayExists {
                    .joiplaySkippedBecauseOtherSourceExists
                } else {
                    nil
                }
            return LoadOutcome(result: result, note: note)
        }

        if rootExists {
            return loadRoot(
                at: rootURL,
                metrics: metrics,
                kirinExists: kirinExists,
                kirinURL: kirinURL,
                joiplayExists: joiplayExists,
                joiplayURL: joiplayURL
            )
        }

        if kirinExists {
            return loadKirin(at: kirinURL, metrics: metrics, joiplayExists: joiplayExists)
        }

        return loadJoiplay(at: joiplayURL, metrics: metrics)
    }

    private static func loadEmpo(at url: URL) -> Result {
        guard let data = try? Data(contentsOf: url) else {
            return Result(
                manifest: nil,
                findings: [
                    Finding(
                        severity: .error,
                        code: .v000,
                        path: "",
                        message: "Failed to read controls manifest"
                    ),
                ],
                location: .empo
            )
        }
        var result = parse(data: data)
        result.location = .empo
        return result
    }

    private static func loadRoot(
        at url: URL,
        metrics: TouchZoneMetrics,
        kirinExists: Bool,
        kirinURL: URL,
        joiplayExists: Bool,
        joiplayURL: URL
    ) -> LoadOutcome {
        let unclaimed = { (note: LoadOutcome.Note) in
            if kirinExists {
                return loadKirin(at: kirinURL, metrics: metrics, joiplayExists: joiplayExists)
            }
            if joiplayExists {
                return loadJoiplay(at: joiplayURL, metrics: metrics)
            }
            return LoadOutcome(
                result: Result(manifest: nil, findings: []),
                note: note
            )
        }

        guard let data = try? Data(contentsOf: url) else {
            return unclaimed(.rootUnclaimedNotObject)
        }

        if data.count > maxFileSize {
            return unclaimed(.rootUnclaimedOversized)
        }

        guard let text = String(data: data, encoding: .utf8),
            let root = JSON5LiteParser.parseObject(text)
        else {
            return unclaimed(.rootUnclaimedNotObject)
        }

        guard root["version"] != nil else {
            return unclaimed(.rootUnclaimedNoVersion)
        }

        var result = parse(data: data)
        result.location = .root
        let note: LoadOutcome.Note? =
            if kirinExists {
                .kirinSkippedBecauseManifestExists
            } else if joiplayExists {
                .joiplaySkippedBecauseOtherSourceExists
            } else {
                nil
            }
        return LoadOutcome(result: result, note: note)
    }

    private static func loadKirin(
        at url: URL,
        metrics: TouchZoneMetrics,
        joiplayExists: Bool = false
    ) -> LoadOutcome {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let translation = KirinControlsTranslator.translate(data: data, metrics: metrics)
        let findings = translation.notes.map { note in
            Finding(severity: .warning, code: .k001, path: "", message: note)
        }
        let result = Result(
            manifest: translation.manifest,
            findings: findings,
            location: .kirin
        )
        let note: LoadOutcome.Note? =
            joiplayExists ? .joiplaySkippedBecauseOtherSourceExists : nil
        return LoadOutcome(result: result, note: note)
    }

    private static func loadJoiplay(at url: URL, metrics: TouchZoneMetrics) -> LoadOutcome {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let translation = JoiPlayControlsTranslator.translate(data: data, metrics: metrics)
        let findings = translation.notes.map { note in
            Finding(severity: .warning, code: .j001, path: "", message: note)
        }
        let result = Result(
            manifest: translation.manifest,
            findings: findings,
            location: .joiplay
        )
        return LoadOutcome(result: result)
    }

    public static func parse(data: Data) -> Result {
        if data.count > maxFileSize {
            return Result(
                manifest: nil,
                findings: [
                    Finding(
                        severity: .error,
                        code: .v001,
                        path: "",
                        message: "Controls manifest exceeds 128 KiB"
                    ),
                ]
            )
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return Result(
                manifest: nil,
                findings: [
                    Finding(
                        severity: .error,
                        code: .v000,
                        path: "",
                        message: "Controls manifest is not valid UTF-8"
                    ),
                ]
            )
        }

        // Parse with the engine's json5pp grammar. A syntax error
        // carries a position, which goes into the finding so the
        // controls.json.log diagnostics name the broken line.
        let root: [String: Any]
        do {
            let strict = try Json5.normalizeToStrictJSON(text)
            guard let strictData = strict.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: strictData)
                    as? [String: Any]
            else {
                return Result(
                    manifest: nil,
                    findings: [
                        Finding(
                            severity: .error,
                            code: .v000,
                            path: "",
                            message: "Invalid JSON in controls manifest"
                        ),
                    ]
                )
            }
            root = object
        } catch let error as Json5SyntaxError {
            return Result(
                manifest: nil,
                findings: [
                    Finding(
                        severity: .error,
                        code: .v000,
                        path: "",
                        message: "Invalid JSON in controls manifest: "
                            + "\(error.message) "
                            + "(line \(error.line), column \(error.column))"
                    ),
                ]
            )
        } catch {
            return Result(
                manifest: nil,
                findings: [
                    Finding(
                        severity: .error,
                        code: .v000,
                        path: "",
                        message: "Invalid JSON in controls manifest"
                    ),
                ]
            )
        }

        if let versionValue = root["version"], let version = asInt(versionValue), version > 1 {
            return Result(manifest: nil, findings: [], ignoredNewerVersion: true)
        }

        var findings: [Finding] = []
        var manifest = ControlsManifest(version: 0)

        if let versionValue = root["version"], let version = asInt(versionValue) {
            manifest.version = version
            if version != 1 {
                findings.append(
                    Finding(
                        severity: .error,
                        code: .v002,
                        path: "/version",
                        message: "version must be exactly 1"
                    )
                )
            }
        } else {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v002,
                    path: "/version",
                    message: "version is required and must be an integer"
                )
            )
        }

        if let touch = root["touch"] as? [String: Any] {
            manifest.touch = parseTouchSection(touch, path: "/touch", findings: &findings)
        } else if root["touch"] != nil {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v000,
                    path: "/touch",
                    message: "touch must be an object"
                )
            )
        }

        if let controller = root["controller"] as? [String: Any] {
            manifest.controller = parseControllerMap(controller, path: "/controller", findings: &findings)
        } else if root["controller"] != nil {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v000,
                    path: "/controller",
                    message: "controller must be an object"
                )
            )
        }

        if manifest.touch == nil && manifest.controller == nil {
            findings.append(
                Finding(
                    severity: .warning,
                    code: .w001,
                    path: "",
                    message: "Manifest has neither touch nor controller section"
                )
            )
        }

        let hasError = findings.contains { $0.severity == .error }
        if hasError {
            return Result(manifest: nil, findings: findings)
        }

        return Result(manifest: manifest, findings: findings)
    }

    // MARK: - Touch

    private static func parseTouchSection(
        _ object: [String: Any],
        path: String,
        findings: inout [Finding]
    ) -> TouchSection {
        var section = TouchSection()

        for (key, value) in object {
            switch key {
            case "portrait":
                if let layout = value as? [String: Any] {
                    section.portrait = parseTouchLayout(layout, path: "\(path)/portrait", findings: &findings)
                } else {
                    appendTypeError(findings: &findings, path: "\(path)/portrait", expected: "object")
                }
            case "landscape":
                if let layout = value as? [String: Any] {
                    section.landscape = parseTouchLayout(layout, path: "\(path)/landscape", findings: &findings)
                } else {
                    appendTypeError(findings: &findings, path: "\(path)/landscape", expected: "object")
                }
            default:
                continue
            }
        }

        return section
    }

    private static func parseTouchLayout(
        _ object: [String: Any],
        path: String,
        findings: inout [Finding]
    ) -> TouchLayout {
        var layout = TouchLayout()

        for (key, value) in object {
            switch key {
            case "dpad":
                if let dpadObject = value as? [String: Any] {
                    layout.dpad = parseDPad(dpadObject, path: "\(path)/dpad", findings: &findings)
                } else {
                    appendTypeError(findings: &findings, path: "\(path)/dpad", expected: "object")
                }
            case "buttons":
                if let buttonsArray = value as? [Any] {
                    layout.buttons = parseButtons(buttonsArray, path: "\(path)/buttons", findings: &findings)
                } else {
                    appendTypeError(findings: &findings, path: "\(path)/buttons", expected: "array")
                }
            case "actionButtons":
                if let actionsArray = value as? [Any] {
                    layout.actionButtons = parseActionButtons(
                        actionsArray, path: "\(path)/actionButtons", findings: &findings)
                } else {
                    appendTypeError(
                        findings: &findings, path: "\(path)/actionButtons", expected: "array")
                }
            default:
                continue
            }
        }

        let combinedCount = (layout.buttons?.count ?? 0) + (layout.actionButtons?.count ?? 0)
        if combinedCount > maxButtonsPerOrientation {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v015,
                    path: path,
                    message: "More than 21 buttons and action buttons combined in one orientation"
                )
            )
        }

        return layout
    }

    private static func parseDPad(
        _ object: [String: Any],
        path: String,
        findings: inout [Finding]
    ) -> DPadSpec? {
        var style: MovementStyle = .dpad
        var placement = PlacementFields(sizeRule: .dpad)

        for (key, value) in object {
            if placement.consume(
                field: key, value: value, path: path, findings: &findings)
            {
                continue
            }
            if key == "style" {
                // Any junk value (unknown string, wrong type) falls
                // back to the d-pad with a warning, never an error: a
                // later style must not poison this version.
                if let text = value as? String, let parsed = MovementStyle(rawValue: text) {
                    style = parsed
                } else {
                    findings.append(
                        Finding(
                            severity: .warning,
                            code: .w006,
                            path: "\(path)/style",
                            message: "Unknown movement style, using the d-pad: \(value)"
                        )
                    )
                }
            }
        }

        guard let coords = placement.requireCoordinates(path: path, findings: &findings)
        else { return nil }
        return DPadSpec(
            x: coords.x, y: coords.y, size: placement.size, opacity: placement.opacity,
            style: style)
    }

    private static func parseButtons(
        _ array: [Any],
        path: String,
        findings: inout [Finding]
    ) -> [ButtonSpec] {
        if array.count > maxButtonsPerOrientation {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v013,
                    path: path,
                    message: "More than \(maxButtonsPerOrientation) buttons in one orientation"
                )
            )
        }

        var buttons: [ButtonSpec] = []
        var keyCounts: [String: Int] = [:]

        for (index, element) in array.enumerated() {
            let buttonPath = "\(path)/\(index)"
            guard let object = element as? [String: Any] else {
                findings.append(
                    Finding(
                        severity: .error,
                        code: .v000,
                        path: buttonPath,
                        message: "Button must be an object"
                    )
                )
                continue
            }

            if let button = parseButton(object, path: buttonPath, findings: &findings) {
                buttons.append(button)
                keyCounts[button.key, default: 0] += 1
            }
        }

        for (key, count) in keyCounts where count > 1 {
            findings.append(
                Finding(
                    severity: .warning,
                    code: .w003,
                    path: path,
                    message: "Duplicate button key \(key)"
                )
            )
        }

        return buttons
    }

    private static func parseButton(
        _ object: [String: Any],
        path: String,
        findings: inout [Finding]
    ) -> ButtonSpec? {
        var label: String?
        var key: String?
        var placement = PlacementFields()

        for (field, value) in object {
            if placement.consume(
                field: field, value: value, path: path, findings: &findings)
            {
                continue
            }
            switch field {
            case "label":
                if let text = value as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count > 8 {
                        findings.append(
                            Finding(
                                severity: .warning,
                                code: .w002,
                                path: "\(path)/label",
                                message: "Label truncated to 8 characters"
                            )
                        )
                        label = String(trimmed.prefix(8))
                    } else {
                        label = trimmed
                    }
                } else {
                    appendTypeError(findings: &findings, path: "\(path)/label", expected: "string")
                }
            case "key":
                if let text = value as? String {
                    key = text
                    validateTouchKey(text, path: "\(path)/key", findings: &findings)
                } else {
                    findings.append(
                        Finding(
                            severity: .error,
                            code: .v010,
                            path: "\(path)/key",
                            message: "Unknown key code: \(value)"
                        )
                    )
                }
            default:
                continue
            }
        }

        guard let key else {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v010,
                    path: "\(path)/key",
                    message: "Unknown key code: "
                )
            )
            return nil
        }
        guard let coords = placement.requireCoordinates(path: path, findings: &findings)
        else { return nil }

        return ButtonSpec(
            label: label, key: key, x: coords.x, y: coords.y,
            size: placement.size, opacity: placement.opacity)
    }

    // MARK: - Controller

    private static func parseControllerMap(
        _ object: [String: Any],
        path: String,
        findings: inout [Finding]
    ) -> ControllerMap {
        var entries: [String: ControllerMap.Target] = [:]

        for (element, value) in object {
            let elementPath = "\(path)/\(element)"
            guard ControllerElement.allNames.contains(element) else {
                findings.append(
                    Finding(
                        severity: .error,
                        code: .v020,
                        path: elementPath,
                        message: "Unknown controller element \(element)"
                    )
                )
                continue
            }

            if value is NSNull {
                entries[element] = .unbound
                continue
            }

            guard let text = value as? String else {
                findings.append(
                    Finding(
                        severity: .error,
                        code: .v000,
                        path: elementPath,
                        message: "Controller target must be a string or null"
                    )
                )
                continue
            }

            if text.hasPrefix("$") {
                // Unknown actions warn and KEEP the entry. Every
                // load-modify-save path rewrites this file, so a
                // skipped entry would be stripped from disk. A kept
                // entry stays inert at dispatch and survives saves.
                if !EmpoActionCatalog.allIDs.contains(text) {
                    findings.append(
                        Finding(
                            severity: .warning,
                            code: .w005,
                            path: elementPath,
                            message: "Unknown action, binding does nothing: \(text)"
                        )
                    )
                }
                entries[element] = .action(text)
            } else if KeyCodeTable.scancode(for: text) != nil {
                entries[element] = .key(text)
            } else {
                findings.append(
                    Finding(
                        severity: .error,
                        code: .v010,
                        path: elementPath,
                        message: "Unknown key code: \(text)"
                    )
                )
            }
        }

        return ControllerMap(entries: entries)
    }

    // MARK: - Validation helpers

    private static func validateTouchKey(_ key: String, path: String, findings: inout [Finding]) {
        if key.hasPrefix("$") {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v014,
                    path: path,
                    message: "Actions do not go in buttons. Use actionButtons for: \(key)"
                )
            )
            return
        }
        if KeyCodeTable.scancode(for: key) == nil {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v010,
                    path: path,
                    message: "Unknown key code: \(key)"
                )
            )
        }
    }

    static func validateCoordinate(_ value: Double, path: String, findings: inout [Finding]) {
        if !(0.0 ... 1.0).contains(value) {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v011,
                    path: path,
                    message: "Coordinate must be between 0.0 and 1.0"
                )
            )
        }
    }

    static func validateButtonSize(_ value: Double, path: String, findings: inout [Finding]) {
        if !(40.0 ... 100.0).contains(value) {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v012,
                    path: path,
                    message: "Button size must be between 40 and 100"
                )
            )
        }
    }

    static func validateDPadSize(_ value: Double, path: String, findings: inout [Finding]) {
        if !(100.0 ... 200.0).contains(value) {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v012,
                    path: path,
                    message: "D-pad size must be between 100 and 200"
                )
            )
        }
    }

    static func validateOpacity(_ value: Double, path: String, findings: inout [Finding]) {
        if !(0.2 ... 1.0).contains(value) {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v012,
                    path: path,
                    message: "Opacity must be between 0.2 and 1.0"
                )
            )
        }
    }

    // JSON booleans must not pass as numbers. Type casts cannot tell
    // them apart (`NSNumber(1) is Bool` and `true as? Int` both succeed
    // on Darwin and corelibs), but `objCType` can: JSONSerialization
    // encodes booleans as "c" and integers/doubles as "q"/"d" on both
    // platforms. CF APIs are not an option. Linux Foundation lacks them.
    private static func isJSONBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return value is Bool }
        return String(cString: number.objCType) == "c"
    }

    static func asDouble(_ value: Any) -> Double? {
        guard !isJSONBool(value) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    private static func asInt(_ value: Any) -> Int? {
        guard !isJSONBool(value) else { return nil }
        if let number = value as? NSNumber { return Int(exactly: number) }
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(exactly: double) }
        return nil
    }

    static func appendCoordinateError(findings: inout [Finding], path: String) {
        findings.append(
            Finding(
                severity: .error,
                code: .v011,
                path: path,
                message: "Coordinate must be a number between 0.0 and 1.0"
            )
        )
    }

    static func appendRangeError(findings: inout [Finding], path: String) {
        findings.append(
            Finding(
                severity: .error,
                code: .v012,
                path: path,
                message: "Value is out of the allowed range"
            )
        )
    }

    static func appendTypeError(findings: inout [Finding], path: String, expected: String) {
        findings.append(
            Finding(
                severity: .error,
                code: .v000,
                path: path,
                message: "Expected \(expected)"
            )
        )
    }
}
