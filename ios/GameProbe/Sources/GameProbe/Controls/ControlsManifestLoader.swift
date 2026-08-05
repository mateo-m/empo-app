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

    private static let maxButtonsPerOrientation = 21

    /// Every finding code this loader can emit, for the docs table
    /// and the uniqueness test. V021 is absent on purpose: W005
    /// superseded it.
    public static let emittedFindingCodes: [String] = [
        "V000", "V001", "V002",
        "V010", "V011", "V012", "V013", "V014", "V015",
        "V020",
        "W001", "W002", "W003", "W004", "W005",
        "K001", "J001",
    ]

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
                        code: "V000",
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
            Finding(severity: .warning, code: "K001", path: "", message: note)
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
            Finding(severity: .warning, code: "J001", path: "", message: note)
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
                        code: "V001",
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
                        code: "V000",
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
                            code: "V000",
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
                        code: "V000",
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
                        code: "V000",
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
                        code: "V002",
                        path: "/version",
                        message: "version must be exactly 1"
                    )
                )
            }
        } else {
            findings.append(
                Finding(
                    severity: .error,
                    code: "V002",
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
                    code: "V000",
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
                    code: "V000",
                    path: "/controller",
                    message: "controller must be an object"
                )
            )
        }

        if manifest.touch == nil && manifest.controller == nil {
            findings.append(
                Finding(
                    severity: .warning,
                    code: "W001",
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
                    code: "V015",
                    path: path,
                    message: "More than 21 buttons and action buttons combined in one orientation"
                )
            )
        }

        return layout
    }

    private static func parseActionButtons(
        _ array: [Any],
        path: String,
        findings: inout [Finding]
    ) -> [ActionButtonSpec] {
        var buttons: [ActionButtonSpec] = []

        for (index, element) in array.enumerated() {
            let buttonPath = "\(path)/\(index)"
            guard let object = element as? [String: Any] else {
                findings.append(
                    Finding(
                        severity: .error,
                        code: "V000",
                        path: buttonPath,
                        message: "Action button must be an object"
                    )
                )
                continue
            }

            if let button = parseActionButton(object, path: buttonPath, findings: &findings) {
                buttons.append(button)
            }
        }

        return buttons
    }

    private static func parseActionButton(
        _ object: [String: Any],
        path: String,
        findings: inout [Finding]
    ) -> ActionButtonSpec? {
        var action: String?
        var x: Double?
        var y: Double?
        var size: Double?
        var opacity: Double?

        for (field, value) in object {
            switch field {
            case "action":
                if let text = value as? String {
                    action = text
                } else {
                    appendTypeError(findings: &findings, path: "\(path)/action", expected: "string")
                }
            case "x":
                if let number = asDouble(value) {
                    x = number
                    validateCoordinate(number, path: "\(path)/x", findings: &findings)
                } else {
                    appendCoordinateError(findings: &findings, path: "\(path)/x")
                }
            case "y":
                if let number = asDouble(value) {
                    y = number
                    validateCoordinate(number, path: "\(path)/y", findings: &findings)
                } else {
                    appendCoordinateError(findings: &findings, path: "\(path)/y")
                }
            case "size":
                if let number = asDouble(value) {
                    size = number
                    validateButtonSize(number, path: "\(path)/size", findings: &findings)
                } else {
                    appendRangeError(findings: &findings, path: "\(path)/size")
                }
            case "opacity":
                if let number = asDouble(value) {
                    opacity = number
                    validateOpacity(number, path: "\(path)/opacity", findings: &findings)
                } else {
                    appendRangeError(findings: &findings, path: "\(path)/opacity")
                }
            default:
                continue
            }
        }

        // An action this Empo version does not know skips only this
        // button. This is the documented exception to the
        // no-partial-application rule, scoped to actionButtons, so a
        // file written for a newer vocabulary still loads.
        guard let action, EmpoActionCatalog.touchIDs.contains(action) else {
            findings.append(
                Finding(
                    severity: .warning,
                    code: "W004",
                    path: "\(path)/action",
                    message: "Unknown action, button skipped: \(action ?? "(missing)")"
                )
            )
            return nil
        }
        // Same rule as plain buttons: a missing coordinate is a V011
        // error, never a silent drop.
        if x == nil { appendCoordinateError(findings: &findings, path: "\(path)/x") }
        if y == nil { appendCoordinateError(findings: &findings, path: "\(path)/y") }
        guard let x, let y else { return nil }

        return ActionButtonSpec(action: action, x: x, y: y, size: size, opacity: opacity)
    }

    private static func parseDPad(
        _ object: [String: Any],
        path: String,
        findings: inout [Finding]
    ) -> DPadSpec? {
        var x: Double?
        var y: Double?
        var size: Double?
        var opacity: Double?

        for (key, value) in object {
            switch key {
            case "x":
                if let number = asDouble(value) {
                    x = number
                    validateCoordinate(number, path: "\(path)/x", findings: &findings)
                } else {
                    appendCoordinateError(findings: &findings, path: "\(path)/x")
                }
            case "y":
                if let number = asDouble(value) {
                    y = number
                    validateCoordinate(number, path: "\(path)/y", findings: &findings)
                } else {
                    appendCoordinateError(findings: &findings, path: "\(path)/y")
                }
            case "size":
                if let number = asDouble(value) {
                    size = number
                    validateDPadSize(number, path: "\(path)/size", findings: &findings)
                } else {
                    appendRangeError(findings: &findings, path: "\(path)/size")
                }
            case "opacity":
                if let number = asDouble(value) {
                    opacity = number
                    validateOpacity(number, path: "\(path)/opacity", findings: &findings)
                } else {
                    appendRangeError(findings: &findings, path: "\(path)/opacity")
                }
            default:
                continue
            }
        }

        if x == nil {
            appendCoordinateError(findings: &findings, path: "\(path)/x")
        }
        if y == nil {
            appendCoordinateError(findings: &findings, path: "\(path)/y")
        }

        guard let x, let y else { return nil }
        return DPadSpec(x: x, y: y, size: size, opacity: opacity)
    }

    private static func parseButtons(
        _ array: [Any],
        path: String,
        findings: inout [Finding]
    ) -> [ButtonSpec] {
        if array.count > 21 {
            findings.append(
                Finding(
                    severity: .error,
                    code: "V013",
                    path: path,
                    message: "More than 21 buttons in one orientation"
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
                        code: "V000",
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
                    code: "W003",
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
        var x: Double?
        var y: Double?
        var size: Double?
        var opacity: Double?

        for (field, value) in object {
            switch field {
            case "label":
                if let text = value as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count > 8 {
                        findings.append(
                            Finding(
                                severity: .warning,
                                code: "W002",
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
                            code: "V010",
                            path: "\(path)/key",
                            message: "Unknown key code: \(value)"
                        )
                    )
                }
            case "x":
                if let number = asDouble(value) {
                    x = number
                    validateCoordinate(number, path: "\(path)/x", findings: &findings)
                } else {
                    appendCoordinateError(findings: &findings, path: "\(path)/x")
                }
            case "y":
                if let number = asDouble(value) {
                    y = number
                    validateCoordinate(number, path: "\(path)/y", findings: &findings)
                } else {
                    appendCoordinateError(findings: &findings, path: "\(path)/y")
                }
            case "size":
                if let number = asDouble(value) {
                    size = number
                    validateButtonSize(number, path: "\(path)/size", findings: &findings)
                } else {
                    appendRangeError(findings: &findings, path: "\(path)/size")
                }
            case "opacity":
                if let number = asDouble(value) {
                    opacity = number
                    validateOpacity(number, path: "\(path)/opacity", findings: &findings)
                } else {
                    appendRangeError(findings: &findings, path: "\(path)/opacity")
                }
            default:
                continue
            }
        }

        guard let key else {
            findings.append(
                Finding(
                    severity: .error,
                    code: "V010",
                    path: "\(path)/key",
                    message: "Unknown key code: "
                )
            )
            return nil
        }
        // A missing coordinate is an error (documented V011 meaning),
        // never a silent drop: a silently dropped button would vanish
        // from disk on the next load-modify-save cycle.
        if x == nil { appendCoordinateError(findings: &findings, path: "\(path)/x") }
        if y == nil { appendCoordinateError(findings: &findings, path: "\(path)/y") }
        guard let x, let y else { return nil }

        return ButtonSpec(label: label, key: key, x: x, y: y, size: size, opacity: opacity)
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
                        code: "V020",
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
                        code: "V000",
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
                            code: "W005",
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
                        code: "V010",
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
                    code: "V014",
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
                    code: "V010",
                    path: path,
                    message: "Unknown key code: \(key)"
                )
            )
        }
    }

    private static func validateCoordinate(_ value: Double, path: String, findings: inout [Finding]) {
        if !(0.0 ... 1.0).contains(value) {
            findings.append(
                Finding(
                    severity: .error,
                    code: "V011",
                    path: path,
                    message: "Coordinate must be between 0.0 and 1.0"
                )
            )
        }
    }

    private static func validateButtonSize(_ value: Double, path: String, findings: inout [Finding]) {
        if !(40.0 ... 100.0).contains(value) {
            findings.append(
                Finding(
                    severity: .error,
                    code: "V012",
                    path: path,
                    message: "Button size must be between 40 and 100"
                )
            )
        }
    }

    private static func validateDPadSize(_ value: Double, path: String, findings: inout [Finding]) {
        if !(100.0 ... 200.0).contains(value) {
            findings.append(
                Finding(
                    severity: .error,
                    code: "V012",
                    path: path,
                    message: "D-pad size must be between 100 and 200"
                )
            )
        }
    }

    private static func validateOpacity(_ value: Double, path: String, findings: inout [Finding]) {
        if !(0.2 ... 1.0).contains(value) {
            findings.append(
                Finding(
                    severity: .error,
                    code: "V012",
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

    private static func asDouble(_ value: Any) -> Double? {
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

    private static func appendCoordinateError(findings: inout [Finding], path: String) {
        findings.append(
            Finding(
                severity: .error,
                code: "V011",
                path: path,
                message: "Coordinate must be a number between 0.0 and 1.0"
            )
        )
    }

    private static func appendRangeError(findings: inout [Finding], path: String) {
        findings.append(
            Finding(
                severity: .error,
                code: "V012",
                path: path,
                message: "Value is out of the allowed range"
            )
        )
    }

    private static func appendTypeError(findings: inout [Finding], path: String, expected: String) {
        findings.append(
            Finding(
                severity: .error,
                code: "V000",
                path: path,
                message: "Expected \(expected)"
            )
        )
    }
}
