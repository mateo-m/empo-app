import Foundation

public enum KirinControlsTranslator {
    public static let fileName = "kirin-touch-controls.json"

    public struct Translation: Sendable {
        /// nil when the file contributed nothing usable.
        public var manifest: ControlsManifest?
        /// Human-readable notes for the game's log. Never errors.
        public var notes: [String]
    }

    // Geometry constants (IMPL choices; gap ≥ 12pt per ticket).
    static let cellGap: Double = 14
    static let edgeMargin: Double = 16
    static let minButtonSize: Double = 40
    static let defaultButtonSize: Double = 56
    static let coordMin: Double = 0.02
    static let coordMax: Double = 0.98

    private static let columnsPerRow = 3
    /// Kirin's own structural capacity (15 right-grid + 6 left-grid
    /// slots). The translation layer respects Kirin's limit rather
    /// than imposing one of its own, so a fully populated file
    /// translates whole; the guard below can only fire if the format
    /// ever grows.
    private static let maxButtons = 21
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
            return Translation(manifest: nil, notes: ["invalid Kirin touch controls file; ignored"])
        }

        var notes: [String] = []

        if let versionValue = root["version"] {
            if let version = asInt(versionValue) {
                if version != 1 {
                    return Translation(
                        manifest: nil,
                        notes: ["unsupported version \(version); ignored"]
                    )
                }
            }
        }

        let scale = asDouble(root["scale"]) ?? 100
        let opacityPercent = asDouble(root["opacity"]) ?? 100
        let baseButtonSize = clamp(defaultButtonSize * scale / 100, min: minButtonSize, max: 100)
        let buttonOpacity = clamp(opacityPercent / 100, min: 0.2, max: 1.0)

        var rightSlots: [Int?] = []
        var leftSlots: [Int?] = []

        for gridName in ["rightGrid", "leftGrid"] {
            guard let grid = root[gridName] as? [String: Any] else { continue }
            let slots = grid["slots"] as? [Any] ?? []
            var hadInvalidSlot = false
            var parsed: [Int?] = []

            for (index, slot) in slots.enumerated() {
                guard slot is NSNull == false else {
                    parsed.append(nil)
                    continue
                }

                guard let keycode = asInt(slot) else {
                    if !hadInvalidSlot {
                        notes.append("non-integer slot value in \(gridName); treated as empty")
                        hadInvalidSlot = true
                    }
                    parsed.append(nil)
                    continue
                }

                guard AndroidKeycodeTable.w3cCode(for: keycode) != nil else {
                    notes.append(
                        "slot \(index) in \(gridName): Android keycode \(keycode) has no keyboard equivalent; button dropped"
                    )
                    parsed.append(nil)
                    continue
                }

                parsed.append(keycode)
            }

            if gridName == "rightGrid" {
                rightSlots = parsed
            } else {
                leftSlots = parsed
            }
        }

        let portraitLayout = buildLayout(
            rightSlots: rightSlots,
            leftSlots: leftSlots,
            metrics: metrics,
            isLandscape: false,
            baseButtonSize: baseButtonSize,
            buttonOpacity: buttonOpacity,
            notes: &notes
        )

        let landscapeLayout = buildLayout(
            rightSlots: rightSlots,
            leftSlots: leftSlots,
            metrics: metrics,
            isLandscape: true,
            baseButtonSize: baseButtonSize,
            buttonOpacity: buttonOpacity,
            notes: &notes
        )

        let portraitButtons = portraitLayout?.buttons ?? []
        let landscapeButtons = landscapeLayout?.buttons ?? []

        if portraitButtons.isEmpty && landscapeButtons.isEmpty {
            return Translation(manifest: nil, notes: notes + ["no usable buttons; ignored"])
        }

        var finalPortrait = portraitButtons
        var finalLandscape = landscapeButtons

        if finalPortrait.count > maxButtons {
            let dropped = finalPortrait.count - maxButtons
            notes.append("\(dropped) buttons beyond the 21-button limit dropped")
            finalPortrait = Array(finalPortrait.prefix(maxButtons))
        }
        if finalLandscape.count > maxButtons {
            finalLandscape = Array(finalLandscape.prefix(maxButtons))
        }

        let touch = TouchSection(
            portrait: TouchLayout(dpad: nil, buttons: finalPortrait),
            landscape: TouchLayout(dpad: nil, buttons: finalLandscape)
        )
        let manifest = ControlsManifest(version: 1, touch: touch)

        return Translation(manifest: manifest, notes: notes)
    }

    // MARK: - Grid geometry

    private struct GridCell {
        let keycode: Int
        let row: Int
        let col: Int
        let isRightGrid: Bool
    }

    private static func buildLayout(
        rightSlots: [Int?],
        leftSlots: [Int?],
        metrics: TouchZoneMetrics,
        isLandscape: Bool,
        baseButtonSize: Double,
        buttonOpacity: Double,
        notes: inout [String]
    ) -> TouchLayout? {
        let width = metrics.width(isLandscape: isLandscape)
        let height = metrics.height(isLandscape: isLandscape)
        let topInset = metrics.topInset(isLandscape: isLandscape)
        let bottomInset = metrics.bottomInset(isLandscape: isLandscape)

        var cells: [GridCell] = []
        appendCells(from: rightSlots, isRightGrid: true, into: &cells)
        appendCells(from: leftSlots, isRightGrid: false, into: &cells)

        guard !cells.isEmpty else { return nil }

        let rightRowCount = rowCount(for: rightSlots)
        let leftRowCount = rowCount(for: leftSlots)
        let maxRowCount = max(rightRowCount, leftRowCount)

        let buttonSize = fitButtonSize(
            buttonSize: baseButtonSize,
            rightRowCount: rightRowCount,
            leftRowCount: leftRowCount,
            maxRowCount: maxRowCount,
            metrics: metrics,
            isLandscape: isLandscape
        )

        let available = metrics.usableHeight(isLandscape: isLandscape, edgeMargin: edgeMargin)
        let rowCountForPitch = isLandscape ? maxRowCount : rightRowCount
        let pitch = effectivePitch(
            buttonSize: buttonSize, rowCount: rowCountForPitch, available: available)
        let firstRowCenterY = topInset + edgeMargin + buttonSize * 0.5
        let lastRowCenterY = height - bottomInset - edgeMargin - buttonSize * 0.5

        let rowCenters: [Double]
        if isLandscape {
            rowCenters = (0 ..< maxRowCount).map { firstRowCenterY + Double($0) * pitch }
        } else {
            rowCenters = []
        }

        var buttons: [ButtonSpec] = []

        for cell in cells {
            guard let w3c = AndroidKeycodeTable.w3cCode(for: cell.keycode) else { continue }

            let x: Double
            let y: Double

            if isLandscape {
                x = landscapeColumnCenter(
                    col: cell.col,
                    isRightGrid: cell.isRightGrid,
                    width: width,
                    buttonSize: buttonSize,
                    pitch: pitch,
                    leadingInset: metrics.leadingInset(isLandscape: true),
                    trailingInset: metrics.trailingInset(isLandscape: true)
                )
                y = rowCenters[cell.row]
            } else if cell.isRightGrid {
                let rowCount = rightRowCount
                x = portraitRightColumnCenter(
                    col: cell.col,
                    width: width,
                    buttonSize: buttonSize,
                    pitch: pitch,
                    trailingInset: metrics.trailingInset(isLandscape: false)
                )
                y = lastRowCenterY - Double(rowCount - 1 - cell.row) * pitch
            } else {
                x = portraitLeftColumnCenter(
                    col: cell.col,
                    width: width,
                    buttonSize: buttonSize,
                    pitch: pitch,
                    leadingInset: metrics.leadingInset(isLandscape: false)
                )
                y = firstRowCenterY + Double(cell.row) * pitch
            }

            buttons.append(
                ButtonSpec(
                    label: nil,
                    key: w3c,
                    x: clampFraction(x / width),
                    y: clampFraction(y / height),
                    size: buttonSize,
                    opacity: buttonOpacity
                )
            )
        }

        return TouchLayout(dpad: nil, buttons: buttons)
    }

    private static func appendCells(
        from slots: [Int?],
        isRightGrid: Bool,
        into cells: inout [GridCell]
    ) {
        for (index, keycode) in slots.enumerated() {
            guard let keycode else { continue }
            cells.append(
                GridCell(
                    keycode: keycode,
                    row: index / columnsPerRow,
                    col: index % columnsPerRow,
                    isRightGrid: isRightGrid
                )
            )
        }
    }

    private static func rowCount(for slots: [Int?]) -> Int {
        guard !slots.isEmpty else { return 0 }
        return (slots.count + columnsPerRow - 1) / columnsPerRow
    }

    private static func landscapeColumnCenter(
        col: Int,
        isRightGrid: Bool,
        width: Double,
        buttonSize: Double,
        pitch: Double,
        leadingInset: Double,
        trailingInset: Double
    ) -> Double {
        if isRightGrid {
            let rightmost = width - trailingInset - edgeMargin - buttonSize * 0.5
            return rightmost - Double(2 - col) * pitch
        }
        let leftmost = leadingInset + edgeMargin + buttonSize * 0.5
        return leftmost + Double(col) * pitch
    }

    private static func portraitRightColumnCenter(
        col: Int,
        width: Double,
        buttonSize: Double,
        pitch: Double,
        trailingInset: Double
    ) -> Double {
        let rightmost = width - trailingInset - edgeMargin - buttonSize * 0.5
        return rightmost - Double(2 - col) * pitch
    }

    private static func portraitLeftColumnCenter(
        col: Int,
        width: Double,
        buttonSize: Double,
        pitch: Double,
        leadingInset: Double
    ) -> Double {
        let leftmost = leadingInset + edgeMargin + buttonSize * 0.5
        return leftmost + Double(col) * pitch
    }

    private static func fitButtonSize(
        buttonSize: Double,
        rightRowCount: Int,
        leftRowCount: Int,
        maxRowCount: Int,
        metrics: TouchZoneMetrics,
        isLandscape: Bool
    ) -> Double {
        var size = buttonSize
        let available = metrics.usableHeight(isLandscape: isLandscape, edgeMargin: edgeMargin)
        let height = metrics.height(isLandscape: isLandscape)
        let topInset = metrics.topInset(isLandscape: isLandscape)
        let bottomInset = metrics.bottomInset(isLandscape: isLandscape)

        while size > minButtonSize {
            let pitch = size + cellGap
            let rowCount = isLandscape ? maxRowCount : rightRowCount
            let span = rowCount > 0 ? Double(rowCount - 1) * pitch + size : size
            var fits = span <= available

            if fits && !isLandscape && leftRowCount > 0 && rightRowCount > 0 {
                let firstLeftCenter = topInset + edgeMargin + size * 0.5
                let leftBottomEdge = firstLeftCenter + Double(leftRowCount - 1) * pitch + size * 0.5
                let lastRightCenter = height - bottomInset - edgeMargin - size * 0.5
                let rightTopEdge = lastRightCenter - Double(rightRowCount - 1) * pitch - size * 0.5
                fits = leftBottomEdge + cellGap <= rightTopEdge
            }

            if fits { return size }
            size -= 1
        }
        return minButtonSize
    }

    /// When the standard pitch overflows the usable band, compress row
    /// spacing evenly so the grid still fits (separation handles residue
    /// if even compression is insufficient).
    private static func effectivePitch(
        buttonSize: Double, rowCount: Int, available: Double
    ) -> Double {
        let standard = buttonSize + cellGap
        guard rowCount > 1 else { return standard }
        let span = Double(rowCount - 1) * standard + buttonSize
        if span <= available { return standard }
        return max((available - buttonSize) / Double(rowCount - 1), buttonSize + 1)
    }

    private static func clampFraction(_ value: Double) -> Double {
        clamp(value, min: coordMin, max: coordMax)
    }

    // MARK: - JSON helpers (Linux-safe; mirrors ControlsManifestLoader)

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
}
