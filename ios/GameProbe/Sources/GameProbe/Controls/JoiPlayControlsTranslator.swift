import Foundation

public enum JoiPlayControlsTranslator {
    public static let fileName = "gamepad.json"

    public struct Translation: Sendable {
        public var manifest: ControlsManifest?
        public var notes: [String]
    }

    private struct Slot {
        let keyField: String
        let defaultKey: String
        let label: String
        let baseSize: Double
        let portraitRow: Int
        let portraitCol: Int
        let landscapeRow: Int
        let landscapeCol: Int
        let cluster: Cluster
    }

    private enum Cluster {
        case bottomRightArc
        case topLeft
        case topRight
    }

    private static let slots: [Slot] = [
        Slot(
            keyField: "cKeyCode", defaultKey: "Enter", label: "C", baseSize: 60,
            portraitRow: 0, portraitCol: 0, landscapeRow: 0, landscapeCol: 0, cluster: .bottomRightArc),
        Slot(
            keyField: "bKeyCode", defaultKey: "Escape", label: "B", baseSize: 56,
            portraitRow: 1, portraitCol: 1, landscapeRow: 0, landscapeCol: 1, cluster: .bottomRightArc),
        Slot(
            keyField: "aKeyCode", defaultKey: "ShiftLeft", label: "A", baseSize: 50,
            portraitRow: 0, portraitCol: 2, landscapeRow: 0, landscapeCol: 2, cluster: .bottomRightArc),
        Slot(
            keyField: "xKeyCode", defaultKey: "KeyA", label: "X", baseSize: 44,
            portraitRow: 2, portraitCol: 2, landscapeRow: 1, landscapeCol: 2, cluster: .bottomRightArc),
        Slot(
            keyField: "yKeyCode", defaultKey: "KeyS", label: "Y", baseSize: 44,
            portraitRow: 2, portraitCol: 1, landscapeRow: 1, landscapeCol: 1, cluster: .bottomRightArc),
        Slot(
            keyField: "zKeyCode", defaultKey: "KeyD", label: "Z", baseSize: 44,
            portraitRow: 2, portraitCol: 0, landscapeRow: 1, landscapeCol: 0, cluster: .bottomRightArc),
        Slot(
            keyField: "lKeyCode", defaultKey: "KeyQ", label: "L", baseSize: 44,
            portraitRow: 0, portraitCol: 0, landscapeRow: 0, landscapeCol: 0, cluster: .topLeft),
        Slot(
            keyField: "rKeyCode", defaultKey: "KeyW", label: "R", baseSize: 44,
            portraitRow: 0, portraitCol: 0, landscapeRow: 0, landscapeCol: 0, cluster: .topRight),
    ]

    static let cellGap: Double = 14
    static let edgeMargin: Double = 16
    static let coordMin: Double = 0.02
    static let coordMax: Double = 0.98

    private static let knownKeys: Set<String> = [
        "btnOpacity", "btnScale",
        "aKeyCode", "bKeyCode", "cKeyCode", "xKeyCode", "yKeyCode", "zKeyCode", "lKeyCode", "rKeyCode",
    ]

    private static let maxFileSize = 128 * 1024

    public static func translate(data: Data) -> Translation {
        translate(data: data, metrics: .reference)
    }

    public static func translate(data: Data, metrics: TouchZoneMetrics) -> Translation {
        if data.count > maxFileSize {
            return Translation(manifest: nil, notes: ["file exceeds 128 KiB; ignored"])
        }

        guard let text = String(data: data, encoding: .utf8),
            let root = JSON5LiteParser.parseObject(text)
        else {
            return Translation(manifest: nil, notes: ["invalid JoiPlay gamepad file; ignored"])
        }

        guard root.keys.contains(where: { knownKeys.contains($0) }) else {
            return Translation(manifest: nil, notes: ["no JoiPlay keys; ignored"])
        }

        var notes: [String] = []

        let scalePercent: Double
        if let scaleValue = root["btnScale"] {
            if let scale = asDouble(scaleValue) {
                scalePercent = scale
            } else {
                scalePercent = 100
                notes.append("btnScale is not a number; using default 100")
            }
        } else {
            scalePercent = 100
        }

        let opacityPercent: Double
        if let opacityValue = root["btnOpacity"] {
            if let opacity = asDouble(opacityValue) {
                opacityPercent = opacity
            } else {
                opacityPercent = 100
                notes.append("btnOpacity is not a number; using default 100")
            }
        } else {
            opacityPercent = 100
        }

        let buttonOpacity = clamp(opacityPercent / 100, min: 0.2, max: 1.0)
        let sizes = slots.map { clamp($0.baseSize * scalePercent / 100, min: 40, max: 100) }

        let portraitButtons = buildButtons(
            root: root,
            metrics: metrics,
            isLandscape: false,
            sizes: sizes,
            buttonOpacity: buttonOpacity,
            notes: &notes
        )
        let landscapeButtons = buildButtons(
            root: root,
            metrics: metrics,
            isLandscape: true,
            sizes: sizes,
            buttonOpacity: buttonOpacity,
            notes: &notes
        )

        let touch = TouchSection(
            portrait: TouchLayout(dpad: nil, buttons: portraitButtons),
            landscape: TouchLayout(dpad: nil, buttons: landscapeButtons)
        )
        let manifest = ControlsManifest(version: 1, touch: touch)

        return Translation(manifest: manifest, notes: notes)
    }

    private static func buildButtons(
        root: [String: Any],
        metrics: TouchZoneMetrics,
        isLandscape: Bool,
        sizes: [Double],
        buttonOpacity: Double,
        notes: inout [String]
    ) -> [ButtonSpec] {
        let width = metrics.width(isLandscape: isLandscape)
        let height = metrics.height(isLandscape: isLandscape)
        let topInset = metrics.topInset(isLandscape: isLandscape)
        let bottomInset = metrics.bottomInset(isLandscape: isLandscape)

        var clusterSizes = sizes
        let clusterSlotCount = 6
        let maxClusterRow = slots.filter { $0.cluster == .bottomRightArc }
            .map { isLandscape ? $0.landscapeRow : $0.portraitRow }.max() ?? 0
        let maxClusterCol = slots.filter { $0.cluster == .bottomRightArc }
            .map { isLandscape ? $0.landscapeCol : $0.portraitCol }.max() ?? 0

        func clusterAnchorY(cSize: Double) -> Double {
            height - bottomInset - edgeMargin - cSize * 0.5
        }

        var clusterPitch: Double = 0
        var clusterAnchorX: Double = 0
        var clusterAnchorYValue: Double = 0

        while true {
            let maxClusterSize = clusterSizes.prefix(clusterSlotCount).max() ?? 56
            clusterPitch = maxClusterSize + cellGap
            let cSize = clusterSizes[0]
            clusterAnchorX =
                width - metrics.trailingInset(isLandscape: isLandscape) - edgeMargin - cSize * 0.5
            clusterAnchorYValue = clusterAnchorY(cSize: cSize)

            let spanY = Double(maxClusterRow) * clusterPitch + maxClusterSize
            let spanX = Double(maxClusterCol) * clusterPitch + maxClusterSize
            let topClusterEdge = clusterAnchorYValue - Double(maxClusterRow) * clusterPitch - maxClusterSize * 0.5
            let topCornerBottom = topInset + edgeMargin + max(clusterSizes[6], clusterSizes[7])
            let usableHeight = metrics.usableHeight(isLandscape: isLandscape, edgeMargin: edgeMargin)

            let fits =
                spanY <= usableHeight
                && spanX <= width - 2 * edgeMargin
                && topClusterEdge >= topCornerBottom + cellGap

            if fits { break }

            var shrunk = false
            for index in 0 ..< clusterSlotCount where clusterSizes[index] > minButtonSize {
                clusterSizes[index] -= 1
                shrunk = true
            }
            if !shrunk {
                clusterPitch = max(
                    (usableHeight - maxClusterSize) / Double(max(maxClusterRow, 1)),
                    maxClusterSize + 1
                )
                break
            }
        }

        var buttons: [ButtonSpec] = []

        for (index, slot) in slots.enumerated() {
            let size = slot.cluster == .bottomRightArc ? clusterSizes[index] : sizes[index]
            var key = slot.defaultKey

            if let keyValue = root[slot.keyField] {
                if let keycode = asInt(keyValue) {
                    if let w3c = AndroidKeycodeTable.w3cCode(for: keycode) {
                        key = w3c
                    } else {
                        notes.append(
                            "\(slot.keyField): Android keycode \(keycode) has no keyboard equivalent; using default"
                        )
                    }
                }
            }

            let point: (x: Double, y: Double)
            let row = isLandscape ? slot.landscapeRow : slot.portraitRow
            let col = isLandscape ? slot.landscapeCol : slot.portraitCol
            switch slot.cluster {
            case .bottomRightArc:
                point = (
                    clusterAnchorX - Double(col) * clusterPitch,
                    clusterAnchorYValue - Double(row) * clusterPitch
                )
            case .topLeft:
                point = (
                    metrics.leadingInset(isLandscape: isLandscape) + edgeMargin + size * 0.5,
                    topInset + edgeMargin + size * 0.5
                )
            case .topRight:
                point = (
                    width - metrics.trailingInset(isLandscape: isLandscape) - edgeMargin - size * 0.5,
                    topInset + edgeMargin + size * 0.5
                )
            }

            buttons.append(
                ButtonSpec(
                    label: slot.label,
                    key: key,
                    x: clampFraction(point.x / width),
                    y: clampFraction(point.y / height),
                    size: size,
                    opacity: buttonOpacity
                )
            )
        }

        return buttons
    }

    private static func clampFraction(_ value: Double) -> Double {
        clamp(value, min: coordMin, max: coordMax)
    }

    // MARK: - JSON helpers (Linux-safe; mirrors KirinControlsTranslator)

    private static func isJSONBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return value is Bool }
        return String(cString: number.objCType) == "c"
    }

    private static func asDouble(_ value: Any?) -> Double? {
        guard let value else { return nil }
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

    private static func clamp(_ value: Double, min minimum: Double, max maximum: Double) -> Double {
        Swift.max(minimum, Swift.min(maximum, value))
    }

    private static let minButtonSize: Double = 40
}
