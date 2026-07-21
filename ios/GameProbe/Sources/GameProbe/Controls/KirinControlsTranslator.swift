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
    static let minDpadSize: Double = 100
    static let maxDpadSize: Double = 200
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
            buttonOpacity: buttonOpacity
        )

        let landscapeLayout = buildLayout(
            rightSlots: rightSlots,
            leftSlots: leftSlots,
            metrics: metrics,
            isLandscape: true,
            baseButtonSize: baseButtonSize,
            buttonOpacity: buttonOpacity
        )

        let portraitButtons = portraitLayout?.buttons ?? []
        let landscapeButtons = landscapeLayout?.buttons ?? []

        if portraitButtons.isEmpty && landscapeButtons.isEmpty {
            return Translation(manifest: nil, notes: notes + ["no usable buttons; ignored"])
        }

        var finalPortrait = portraitLayout
        var finalLandscape = landscapeLayout

        if portraitButtons.count > maxButtons {
            let dropped = portraitButtons.count - maxButtons
            notes.append("\(dropped) buttons beyond the 21-button limit dropped")
            finalPortrait = TouchLayout(
                dpad: portraitLayout?.dpad,
                buttons: Array(portraitButtons.prefix(maxButtons))
            )
        }
        if landscapeButtons.count > maxButtons {
            finalLandscape = TouchLayout(
                dpad: landscapeLayout?.dpad,
                buttons: Array(landscapeButtons.prefix(maxButtons))
            )
        }

        let touch = TouchSection(
            portrait: finalPortrait,
            landscape: finalLandscape
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
        buttonOpacity: Double
    ) -> TouchLayout? {
        let width = metrics.width(isLandscape: isLandscape)
        let height = metrics.height(isLandscape: isLandscape)
        let topInset = metrics.topInset(isLandscape: isLandscape)
        let bottomInset = metrics.bottomInset(isLandscape: isLandscape)
        let leadingInset = metrics.leadingInset(isLandscape: isLandscape)
        let trailingInset = metrics.trailingInset(isLandscape: isLandscape)

        var cells: [GridCell] = []
        appendCells(from: rightSlots, isRightGrid: true, into: &cells)
        appendCells(from: leftSlots, isRightGrid: false, into: &cells)

        guard !cells.isEmpty else { return nil }

        let rightRowCount = rowCount(for: rightSlots)
        let leftRowCount = rowCount(for: leftSlots)
        let maxRowCount = max(rightRowCount, leftRowCount)

        let fit = fitButtonSizeAndDpad(
            buttonSize: baseButtonSize,
            leftRowCount: leftRowCount,
            maxRowCount: maxRowCount,
            metrics: metrics,
            isLandscape: isLandscape
        )
        let buttonSize = fit.buttonSize
        let dpadSize = fit.dpadSize

        let available = metrics.usableHeight(isLandscape: isLandscape, edgeMargin: edgeMargin)
        let leftKeyAvailable = available - cellGap - dpadSize
        let rowPitch = effectivePitch(
            buttonSize: buttonSize, rowCount: maxRowCount, available: available)
        let leftPitch = effectivePitch(
            buttonSize: buttonSize, rowCount: leftRowCount, available: leftKeyAvailable)
        let pitch = min(rowPitch, leftPitch)

        let bandTop = topInset + edgeMargin
        let firstRowCenterY = bandTop + buttonSize * 0.5
        let rowCenters = (0..<maxRowCount).map { firstRowCenterY + Double($0) * pitch }

        var buttons: [ButtonSpec] = []

        for cell in cells {
            guard let w3c = AndroidKeycodeTable.w3cCode(for: cell.keycode) else { continue }

            let x = columnCenter(
                col: cell.col,
                isRightGrid: cell.isRightGrid,
                width: width,
                buttonSize: buttonSize,
                pitch: pitch,
                leadingInset: leadingInset,
                trailingInset: trailingInset
            )
            let y = rowCenters[cell.row]

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

        let dpad = buildDPad(
            leftRowCount: leftRowCount,
            buttonSize: buttonSize,
            dpadSize: dpadSize,
            pitch: pitch,
            width: width,
            height: height,
            topInset: topInset,
            bottomInset: bottomInset,
            leadingInset: leadingInset,
            trailingInset: trailingInset,
            buttonOpacity: buttonOpacity,
            firstRowCenterY: firstRowCenterY
        )

        return TouchLayout(dpad: dpad, buttons: buttons)
    }

    private static func buildDPad(
        leftRowCount: Int,
        buttonSize: Double,
        dpadSize: Double,
        pitch: Double,
        width: Double,
        height: Double,
        topInset: Double,
        bottomInset: Double,
        leadingInset: Double,
        trailingInset: Double,
        buttonOpacity: Double,
        firstRowCenterY: Double
    ) -> DPadSpec {
        let leftmost = leadingInset + edgeMargin + buttonSize * 0.5
        let centerX = leftmost + pitch

        let bandTop = topInset + edgeMargin
        let bandBottom = height - bottomInset - edgeMargin

        let centerY: Double
        if leftRowCount > 0 {
            let lastLeftKeyRowCenter = firstRowCenterY + Double(leftRowCount - 1) * pitch
            centerY = lastLeftKeyRowCenter + buttonSize * 0.5 + cellGap + dpadSize * 0.5
        } else {
            centerY = bandTop + dpadSize * 0.5
        }

        let half = dpadSize * 0.5
        let clampedX = clamp(
            centerX,
            min: leadingInset + edgeMargin + half,
            max: width - trailingInset - edgeMargin - half
        )
        let clampedY = clamp(
            centerY,
            min: bandTop + half,
            max: bandBottom - half
        )

        return DPadSpec(
            x: clampFraction(clampedX / width),
            y: clampFraction(clampedY / height),
            size: dpadSize,
            opacity: buttonOpacity
        )
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

    private static func columnCenter(
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

    private struct FitResult {
        var buttonSize: Double
        var dpadSize: Double
    }

    private static func nominalDpadSize(buttonSize: Double) -> Double {
        clamp(3 * buttonSize, min: minDpadSize, max: maxDpadSize)
    }

    private static func fitButtonSizeAndDpad(
        buttonSize: Double,
        leftRowCount: Int,
        maxRowCount: Int,
        metrics: TouchZoneMetrics,
        isLandscape: Bool
    ) -> FitResult {
        var size = buttonSize
        var dpad = nominalDpadSize(buttonSize: size)
        let available = metrics.usableHeight(isLandscape: isLandscape, edgeMargin: edgeMargin)

        while true {
            if layoutFits(
                buttonSize: size,
                dpadSize: dpad,
                leftRowCount: leftRowCount,
                maxRowCount: maxRowCount,
                available: available,
                metrics: metrics,
                isLandscape: isLandscape
            ) {
                return FitResult(buttonSize: size, dpadSize: dpad)
            }

            if size > minButtonSize {
                size -= 1
                dpad = nominalDpadSize(buttonSize: size)
            } else if dpad > minDpadSize {
                dpad -= 1
            } else {
                return FitResult(buttonSize: minButtonSize, dpadSize: minDpadSize)
            }
        }
    }

    private static func layoutFits(
        buttonSize: Double,
        dpadSize: Double,
        leftRowCount: Int,
        maxRowCount: Int,
        available: Double,
        metrics: TouchZoneMetrics,
        isLandscape: Bool
    ) -> Bool {
        let pitch = buttonSize + cellGap
        let leftKeysSpan = keyRowsSpan(rowCount: leftRowCount, buttonSize: buttonSize, pitch: pitch)
        let leftBandSpan = leftKeysSpan + cellGap + dpadSize
        let sharedRowsSpan = keyRowsSpan(
            rowCount: maxRowCount, buttonSize: buttonSize, pitch: pitch)
        guard max(sharedRowsSpan, leftBandSpan) <= available else { return false }

        return horizontalFit(
            buttonSize: buttonSize,
            dpadSize: dpadSize,
            pitch: pitch,
            metrics: metrics,
            isLandscape: isLandscape
        )
    }

    /// Two 3-column bands (left keys + d-pad, right keys) must clear
    /// each other horizontally when the zone is narrow.
    private static func horizontalFit(
        buttonSize: Double,
        dpadSize: Double,
        pitch: Double,
        metrics: TouchZoneMetrics,
        isLandscape: Bool
    ) -> Bool {
        let width = metrics.width(isLandscape: isLandscape)
        let leadingInset = metrics.leadingInset(isLandscape: isLandscape)
        let trailingInset = metrics.trailingInset(isLandscape: isLandscape)
        let leftmost = leadingInset + edgeMargin + buttonSize * 0.5
        let rightmost = width - trailingInset - edgeMargin - buttonSize * 0.5

        let columnGap = rightmost - 2 * pitch - (leftmost + 2 * pitch)
        guard columnGap >= buttonSize else { return false }

        let dpadCenterX = leftmost + pitch
        let dpadRight = dpadCenterX + dpadSize * 0.5
        let rightGridLeft = rightmost - 2 * pitch - buttonSize * 0.5
        return rightGridLeft >= dpadRight
    }

    private static func keyRowsSpan(rowCount: Int, buttonSize: Double, pitch: Double) -> Double {
        guard rowCount > 0 else { return 0 }
        return Double(rowCount - 1) * pitch + buttonSize
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
