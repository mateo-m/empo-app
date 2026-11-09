// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import Json5

public enum ControlsManifestLoader {
    /// The case order is the source order. The first file that exists
    /// and claims the game wins.
    public enum ManifestLocation: String, Sendable, Equatable, CaseIterable {
        case empo = "empo/controls.json"
        case root = "controls.json"
        case kirin = "kirin-touch-controls.json"
        case joiplay = "gamepad.json"
    }

    public struct LoadOutcome: Sendable {
        public var result: Result
        public var notes: [Note]

        public enum Note: Equatable, Sendable {
            case rootSkippedBecauseEmpoExists
            case kirinSkippedBecauseManifestExists
            case joiplaySkippedBecauseOtherSourceExists
            case rootUnclaimedNotObject
            case rootUnclaimedNoVersion
            case rootUnclaimedOversized
        }

        public init(result: Result, notes: [Note] = []) {
            self.result = result
            self.notes = notes
        }
    }

    /// V021 is absent on purpose. W005 replaced it.
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
        case v023 = "V023"
        case w001 = "W001"
        case w002 = "W002"
        case w003 = "W003"
        case w004 = "W004"
        case w005 = "W005"
        case w006 = "W006"
        case w007 = "W007"
        case k001 = "K001"
        case j001 = "J001"
    }

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

        init(severity: Severity, code: FindingCode, path: String, message: String) {
            self.init(
                severity: severity, code: code.rawValue, path: path, message: message)
        }
    }

    public static func load(gameRoot: URL) -> LoadOutcome? {
        load(gameRoot: gameRoot, metrics: .reference)
    }

    public static func load(gameRoot: URL, metrics: TouchZoneMetrics) -> LoadOutcome? {
        let present = ManifestLocation.allCases.filter {
            FileManager.default.fileExists(atPath: gameRoot.appendingPathComponent($0.rawValue).path)
        }
        guard !present.isEmpty else { return nil }

        var unclaimedNotes: [LoadOutcome.Note] = []
        for (index, location) in present.enumerated() {
            let data = try? Data(contentsOf: gameRoot.appendingPathComponent(location.rawValue))
            var result: Result
            switch location {
            case .empo:
                result = data.map(parse(data:)) ?? readFailure
            case .root:
                switch claimRoot(data) {
                case .claimed(let root): result = manifestResult(from: root)
                case .unclaimed(let note):
                    unclaimedNotes.append(note)
                    continue
                }
            case .kirin:
                let translation = KirinControlsTranslator.translate(
                    data: data ?? Data(), metrics: metrics)
                result = Result(
                    manifest: translation.manifest,
                    findings: translation.notes.map {
                        Finding(severity: .warning, code: .k001, path: "", message: $0)
                    })
            case .joiplay:
                let translation = JoiPlayControlsTranslator.translate(
                    data: data ?? Data(), metrics: metrics)
                result = Result(
                    manifest: translation.manifest,
                    findings: translation.notes.map {
                        Finding(severity: .warning, code: .j001, path: "", message: $0)
                    })
            }
            result.location = location
            let skipped = present.dropFirst(index + 1).first.map(skipNote(for:))
            return LoadOutcome(result: result, notes: unclaimedNotes + (skipped.map { [$0] } ?? []))
        }
        return LoadOutcome(result: Result(manifest: nil, findings: []), notes: unclaimedNotes)
    }

    private static let readFailure = Result(
        manifest: nil,
        findings: [
            Finding(
                severity: .error, code: .v000, path: "",
                message: "Failed to read controls manifest")
        ])

    private static func skipNote(for location: ManifestLocation) -> LoadOutcome.Note {
        switch location {
        case .empo, .root: .rootSkippedBecauseEmpoExists
        case .kirin: .kirinSkippedBecauseManifestExists
        case .joiplay: .joiplaySkippedBecauseOtherSourceExists
        }
    }

    private enum RootClaim {
        case claimed([String: Any])
        case unclaimed(LoadOutcome.Note)
    }

    /// A `controls.json` at the game root can belong to another tool.
    private static func claimRoot(_ data: Data?) -> RootClaim {
        guard let data else { return .unclaimed(.rootUnclaimedNotObject) }
        if data.count > ControlLimits.maxFileSize { return .unclaimed(.rootUnclaimedOversized) }
        guard case .object(let root) = decodeObject(data) else {
            return .unclaimed(.rootUnclaimedNotObject)
        }
        guard root["version"] != nil else { return .unclaimed(.rootUnclaimedNoVersion) }
        return .claimed(root)
    }

    public static func parse(data: Data) -> Result {
        if data.count > ControlLimits.maxFileSize {
            return Result(
                manifest: nil,
                findings: [
                    Finding(
                        severity: .error,
                        code: .v001,
                        path: "",
                        message: "Controls manifest exceeds \(ControlLimits.maxFileSizeText)"
                    )
                ]
            )
        }
        switch decodeObject(data) {
        case .object(let root): return manifestResult(from: root)
        case .failure(let message):
            return Result(
                manifest: nil,
                findings: [Finding(severity: .error, code: .v000, path: "", message: message)])
        }
    }

    private enum Decoded {
        case object([String: Any])
        case failure(String)
    }

    private static func decodeObject(_ data: Data) -> Decoded {
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure("Controls manifest is not valid UTF-8")
        }
        do {
            guard let root = try JSON5LiteParser.parseObjectReportingSyntaxError(text) else {
                return .failure("Invalid JSON in controls manifest")
            }
            return .object(root)
        } catch let error as Json5SyntaxError {
            return .failure(
                "Invalid JSON in controls manifest: \(error.message) "
                    + "(line \(error.line), column \(error.column))")
        } catch {
            return .failure("Invalid JSON in controls manifest")
        }
    }

    private static func manifestResult(from root: [String: Any]) -> Result {
        if let versionValue = root["version"], let version = JSONNumber.int(versionValue), version > 1 {
            return Result(manifest: nil, findings: [], ignoredNewerVersion: true)
        }

        var findings: [Finding] = []
        var manifest = ControlsManifest(version: 0)

        if let versionValue = root["version"], let version = JSONNumber.int(versionValue) {
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

        // `controller` is the old name of the section. Manifests in the
        // wild use it, so it stays valid.
        let bindingsKey = root["bindings"] != nil ? "bindings" : "controller"
        if root["bindings"] != nil && root["controller"] != nil {
            findings.append(
                Finding(
                    severity: .warning,
                    code: .w007,
                    path: "/controller",
                    message: "bindings and controller are the same section, so controller is ignored"
                )
            )
        }

        if let bindings = root[bindingsKey] as? [String: Any] {
            manifest.bindings = parseBindingMap(
                bindings, path: "/\(bindingsKey)", findings: &findings)
        } else if root[bindingsKey] != nil {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v000,
                    path: "/\(bindingsKey)",
                    message: "\(bindingsKey) must be an object"
                )
            )
        }

        if manifest.touch == nil && manifest.bindings == nil {
            findings.append(
                Finding(
                    severity: .warning,
                    code: .w001,
                    path: "",
                    message: "Manifest has neither touch nor bindings section"
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
                    section.landscape = parseTouchLayout(
                        layout, path: "\(path)/landscape", findings: &findings)
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
        if combinedCount > ControlLimits.maxButtonsPerOrientation {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v015,
                    path: path,
                    message:
                        "More than \(ControlLimits.maxButtonsPerOrientation) buttons and action buttons combined in one orientation"
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
                // An unknown value gives a warning, not an error, so
                // that a file with a newer style still loads.
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
        if array.count > ControlLimits.maxButtonsPerOrientation {
            findings.append(
                Finding(
                    severity: .error,
                    code: .v013,
                    path: path,
                    message: "More than \(ControlLimits.maxButtonsPerOrientation) buttons in one orientation"
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
                    if trimmed.count > ControlLimits.maxLabelLength {
                        findings.append(
                            Finding(
                                severity: .warning,
                                code: .w002,
                                path: "\(path)/label",
                                message: "Label truncated to \(ControlLimits.maxLabelLength) characters"
                            )
                        )
                        label = String(trimmed.prefix(ControlLimits.maxLabelLength))
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

    // MARK: - Bindings

    private static func parseBindingMap(
        _ object: [String: Any],
        path: String,
        findings: inout [Finding]
    ) -> BindingMap {
        var reported: [Finding] = []
        let map = BindingMapCoder.decode(object) { source, issue in
            let sourcePath = "\(path)/\(source)"
            switch issue {
            case .unknownSource:
                reported.append(
                    Finding(
                        severity: .error, code: .v020, path: sourcePath,
                        message: "Unknown controller element or key: \(source)"))
            case .targetNotText:
                reported.append(
                    Finding(
                        severity: .error, code: .v000, path: sourcePath,
                        message: "Binding target must be a string or null"))
            case .unknownTarget(let text):
                reported.append(
                    Finding(
                        severity: .error, code: .v010, path: sourcePath,
                        message: "Unknown key code: \(text)"))
            case .unknownAction(let id):
                reported.append(
                    Finding(
                        severity: .warning, code: .w005, path: sourcePath,
                        message: "Unknown action, binding does nothing: \(id)"))
            case .elementChain(let element):
                reported.append(
                    Finding(
                        severity: .error, code: .v023, path: sourcePath,
                        message: "A controller element cannot bind to another element: \(element)"))
            }
        }
        findings.append(contentsOf: reported)
        return map
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
        validate(value, in: ControlLimits.coordinate, code: .v011, name: "Coordinate", path: path, findings: &findings)
    }

    static func validateButtonSize(_ value: Double, path: String, findings: inout [Finding]) {
        validate(value, in: ControlLimits.buttonSize, code: .v012, name: "Button size", path: path, findings: &findings)
    }

    static func validateDPadSize(_ value: Double, path: String, findings: inout [Finding]) {
        validate(value, in: ControlLimits.dpadSize, code: .v012, name: "D-pad size", path: path, findings: &findings)
    }

    static func validateOpacity(_ value: Double, path: String, findings: inout [Finding]) {
        validate(value, in: ControlLimits.opacity, code: .v012, name: "Opacity", path: path, findings: &findings)
    }

    private static func validate(
        _ value: Double, in range: ClosedRange<Double>, code: FindingCode, name: String,
        path: String, findings: inout [Finding]
    ) {
        guard !range.contains(value) else { return }
        findings.append(
            Finding(
                severity: .error, code: code, path: path,
                message: "\(name) must be between \(rangeText(range.lowerBound)) and \(rangeText(range.upperBound))"
            ))
    }

    private static func rangeText(_ bound: Double) -> String {
        bound == bound.rounded() && bound > 1 ? String(Int(bound)) : String(bound)
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
