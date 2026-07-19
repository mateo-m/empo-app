import Foundation

public enum ControlsManifestLoader {
    public static let manifestRelativePath = "empo/controls.json"

    private static let maxFileSize = 128 * 1024

    private static let knownActions: Set<String> = [
        "$pauseMenu",
        "$toggleOverlay",
    ]

    public struct Result: Sendable {
        public var manifest: ControlsManifest?
        public var findings: [Finding]
        public var ignoredNewerVersion: Bool

        public init(
            manifest: ControlsManifest?,
            findings: [Finding],
            ignoredNewerVersion: Bool = false
        ) {
            self.manifest = manifest
            self.findings = findings
            self.ignoredNewerVersion = ignoredNewerVersion
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

    /// nil if the file does not exist. Never throws for content problems — those land in `findings`.
    public static func load(gameRoot: URL) -> Result? {
        let url = gameRoot.appendingPathComponent(manifestRelativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
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
                ]
            )
        }
        return parse(data: data)
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

        guard let root = JSON5LiteParser.parseObject(text) else {
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

        if let versionValue = root["version"] {
            if let version = versionValue as? Int {
                if version > 1 {
                    return Result(manifest: nil, findings: [], ignoredNewerVersion: true)
                }
            }
        }

        var findings: [Finding] = []
        var manifest = ControlsManifest(version: 0)

        if let version = root["version"] as? Int {
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

        if let name = root["name"] {
            if let nameString = name as? String {
                manifest.name = nameString
            }
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
            default:
                continue
            }
        }

        return layout
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
        if array.count > 16 {
            findings.append(
                Finding(
                    severity: .error,
                    code: "V013",
                    path: path,
                    message: "More than 16 buttons in one orientation"
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
                if knownActions.contains(text) {
                    entries[element] = .action(text)
                } else {
                    findings.append(
                        Finding(
                            severity: .error,
                            code: "V021",
                            path: elementPath,
                            message: "Unknown action: \(text)"
                        )
                    )
                }
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
                    message: "Action strings are not allowed in touch buttons: \(key)"
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

    private static func asDouble(_ value: Any) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if value is Bool { return nil }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
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
