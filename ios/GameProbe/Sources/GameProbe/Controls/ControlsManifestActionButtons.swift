// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

extension ControlsManifestLoader {
    struct PlacementFields {
        enum SizeRule {
            case button
            case dpad
        }

        var sizeRule: SizeRule = .button
        var x: Double?
        var y: Double?
        var size: Double?
        var opacity: Double?

        mutating func consume(
            field: String, value: Any, path: String, findings: inout [Finding]
        ) -> Bool {
            switch field {
            case "x":
                if let number = JSONNumber.double(value) {
                    x = number
                    ControlsManifestLoader.validateCoordinate(
                        number, path: "\(path)/x", findings: &findings)
                } else {
                    ControlsManifestLoader.appendCoordinateError(
                        findings: &findings, path: "\(path)/x")
                }
            case "y":
                if let number = JSONNumber.double(value) {
                    y = number
                    ControlsManifestLoader.validateCoordinate(
                        number, path: "\(path)/y", findings: &findings)
                } else {
                    ControlsManifestLoader.appendCoordinateError(
                        findings: &findings, path: "\(path)/y")
                }
            case "size":
                if let number = JSONNumber.double(value) {
                    size = number
                    switch sizeRule {
                    case .button:
                        ControlsManifestLoader.validateButtonSize(
                            number, path: "\(path)/size", findings: &findings)
                    case .dpad:
                        ControlsManifestLoader.validateDPadSize(
                            number, path: "\(path)/size", findings: &findings)
                    }
                } else {
                    ControlsManifestLoader.appendRangeError(
                        findings: &findings, path: "\(path)/size")
                }
            case "opacity":
                if let number = JSONNumber.double(value) {
                    opacity = number
                    ControlsManifestLoader.validateOpacity(
                        number, path: "\(path)/opacity", findings: &findings)
                } else {
                    ControlsManifestLoader.appendRangeError(
                        findings: &findings, path: "\(path)/opacity")
                }
            default:
                return false
            }
            return true
        }

        /// A missing coordinate is an error, not a silent drop. A
        /// dropped button vanishes from disk on the next
        /// load-modify-save cycle.
        func requireCoordinates(
            path: String, findings: inout [Finding]
        ) -> (x: Double, y: Double)? {
            if x == nil {
                ControlsManifestLoader.appendCoordinateError(
                    findings: &findings, path: "\(path)/x")
            }
            if y == nil {
                ControlsManifestLoader.appendCoordinateError(
                    findings: &findings, path: "\(path)/y")
            }
            guard let x, let y else { return nil }
            return (x, y)
        }
    }

    static func parseActionButtons(
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
                        code: .v000,
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
        var placement = PlacementFields()

        for (field, value) in object {
            if placement.consume(
                field: field, value: value, path: path, findings: &findings)
            {
                continue
            }
            if field == "action" {
                if let text = value as? String {
                    action = text
                } else {
                    appendTypeError(findings: &findings, path: "\(path)/action", expected: "string")
                }
            }
        }

        // An unknown action skips only this button, so that a file for
        // a newer Empo still loads. This is an exception to the
        // no-partial-application rule.
        guard let action, EmpoActionCatalog.touchIDs.contains(action) else {
            findings.append(
                Finding(
                    severity: .warning,
                    code: .w004,
                    path: "\(path)/action",
                    message: "Unknown action, button skipped: \(action ?? "(missing)")"
                )
            )
            return nil
        }
        guard let coords = placement.requireCoordinates(path: path, findings: &findings)
        else { return nil }

        return ActionButtonSpec(
            action: action, x: coords.x, y: coords.y,
            size: placement.size, opacity: placement.opacity)
    }
}
