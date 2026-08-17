import Foundation

/// Parsing for the `actionButtons` arrays. Split from the main
/// loader file for size. The shared placement fields keep the
/// x/y/size/opacity rules identical to plain buttons.
extension ControlsManifestLoader {
    /// The x/y/size/opacity fields every placeable control shares.
    /// One consumer for the d-pad, key buttons, and action buttons,
    /// so the validation and the error emission cannot drift per
    /// kind.
    struct PlacementFields {
        /// The d-pad's size range differs from the buttons'.
        enum SizeRule {
            case button
            case dpad
        }

        var sizeRule: SizeRule = .button
        var x: Double?
        var y: Double?
        var size: Double?
        var opacity: Double?

        /// Consumes one manifest field when it is a placement
        /// field. Returns false when the field belongs to the
        /// caller.
        mutating func consume(
            field: String, value: Any, path: String, findings: inout [Finding]
        ) -> Bool {
            switch field {
            case "x":
                if let number = ControlsManifestLoader.asDouble(value) {
                    x = number
                    ControlsManifestLoader.validateCoordinate(
                        number, path: "\(path)/x", findings: &findings)
                } else {
                    ControlsManifestLoader.appendCoordinateError(
                        findings: &findings, path: "\(path)/x")
                }
            case "y":
                if let number = ControlsManifestLoader.asDouble(value) {
                    y = number
                    ControlsManifestLoader.validateCoordinate(
                        number, path: "\(path)/y", findings: &findings)
                } else {
                    ControlsManifestLoader.appendCoordinateError(
                        findings: &findings, path: "\(path)/y")
                }
            case "size":
                if let number = ControlsManifestLoader.asDouble(value) {
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
                if let number = ControlsManifestLoader.asDouble(value) {
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

        /// The buttons' trailing rule: a missing coordinate is a
        /// V011 error, never a silent drop. A silently dropped
        /// button would vanish from disk on the next
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

        // An action this Empo version does not know skips only this
        // button. This is the documented exception to the
        // no-partial-application rule, scoped to actionButtons, so a
        // file written for a newer vocabulary still loads.
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
