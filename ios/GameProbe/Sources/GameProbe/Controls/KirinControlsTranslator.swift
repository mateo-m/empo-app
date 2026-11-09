// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public enum KirinControlsTranslator {
    public static let fileName = ControlsManifestLoader.ManifestLocation.kirin.rawValue

    public struct Translation: Sendable {
        public var manifest: ControlsManifest?
        public var notes: [String]
    }

    private static let columnsPerRow = 3

    public static func translate(data: Data, metrics: TouchZoneMetrics) -> Translation {
        if data.count > ControlLimits.maxFileSize {
            return Translation(
                manifest: nil,
                notes: ["file is larger than \(ControlLimits.maxFileSizeText), ignored"])
        }

        guard let text = String(data: data, encoding: .utf8),
            let root = JSON5LiteParser.parseObject(text)
        else {
            return Translation(manifest: nil, notes: ["invalid Kirin touch controls file, ignored"])
        }

        var notes: [String] = []

        if let versionValue = root["version"] {
            if let version = JSONNumber.int(versionValue) {
                if version != 1 {
                    return Translation(
                        manifest: nil,
                        notes: ["unsupported version \(version); ignored"]
                    )
                }
            } else {
                notes.append("version is not an integer; read as version 1")
            }
        }

        let scale = JSONNumber.double(root["scale"]) ?? 100
        let opacityPercent = JSONNumber.double(root["opacity"]) ?? 100
        let baseButtonSize = ControlLimits.buttonSize.clamp(
            ControlLimits.defaultButtonSize * scale / 100)
        let buttonOpacity = ControlLimits.opacity.clamp(opacityPercent / 100)

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

                guard let keycode = JSONNumber.int(slot) else {
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

        let dropped = dropSlotsOverLimit(rightSlots: &rightSlots, leftSlots: &leftSlots)
        if dropped > 0 {
            notes.append(
                "\(dropped) buttons beyond the \(ControlLimits.maxButtonsPerOrientation)-button limit dropped"
            )
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

        guard portraitLayout != nil || landscapeLayout != nil else {
            return Translation(manifest: nil, notes: notes + ["no usable buttons, ignored"])
        }

        let touch = TouchSection(portrait: portraitLayout, landscape: landscapeLayout)
        let manifest = ControlsManifest(version: 1, touch: touch)

        return Translation(manifest: manifest, notes: notes)
    }

    /// The slots stay, so the rows keep their places.
    private static func dropSlotsOverLimit(rightSlots: inout [Int?], leftSlots: inout [Int?]) -> Int {
        var kept = 0
        var dropped = 0
        func trim(_ slots: inout [Int?]) {
            for index in slots.indices where slots[index] != nil {
                if kept < ControlLimits.maxButtonsPerOrientation {
                    kept += 1
                } else {
                    slots[index] = nil
                    dropped += 1
                }
            }
        }
        trim(&rightSlots)
        trim(&leftSlots)
        return dropped
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

        let available = metrics.usableHeight(isLandscape: isLandscape, edgeMargin: TranslatorLayout.edgeMargin)
        let leftKeyAvailable = available - TranslatorLayout.cellGap - dpadSize
        let rowPitch = effectivePitch(
            buttonSize: buttonSize, rowCount: maxRowCount, available: available)
        let leftPitch = effectivePitch(
            buttonSize: buttonSize, rowCount: leftRowCount, available: leftKeyAvailable)
        let pitch = min(rowPitch, leftPitch)

        // A sideways screen keeps the grid at the bottom edge, near the
        // thumbs. The free space goes above the grid, under the toolbar.
        let leftBandSpan =
            leftRowCount > 0
            ? keyRowsSpan(rowCount: leftRowCount, buttonSize: buttonSize, pitch: pitch)
                + TranslatorLayout.cellGap + dpadSize
            : dpadSize
        let bandSpan = max(
            keyRowsSpan(rowCount: maxRowCount, buttonSize: buttonSize, pitch: pitch),
            leftBandSpan)
        let bandTop =
            isLandscape
            ? max(topInset + TranslatorLayout.edgeMargin, height - bottomInset - TranslatorLayout.edgeMargin - bandSpan)
            : topInset + TranslatorLayout.edgeMargin
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
                    x: ControlLimits.placedCoordinate.clamp(x / width),
                    y: ControlLimits.placedCoordinate.clamp(y / height),
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
            bandTop: bandTop,
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
        bandTop: Double,
        bottomInset: Double,
        leadingInset: Double,
        trailingInset: Double,
        buttonOpacity: Double,
        firstRowCenterY: Double
    ) -> DPadSpec {
        let leftmost = leadingInset + TranslatorLayout.edgeMargin + buttonSize * 0.5
        let centerX = leftmost + pitch

        let bandBottom = height - bottomInset - TranslatorLayout.edgeMargin

        let centerY: Double
        if leftRowCount > 0 {
            let lastLeftKeyRowCenter = firstRowCenterY + Double(leftRowCount - 1) * pitch
            centerY = lastLeftKeyRowCenter + buttonSize * 0.5 + TranslatorLayout.cellGap + dpadSize * 0.5
        } else {
            centerY = bandTop + dpadSize * 0.5
        }

        let half = dpadSize * 0.5
        let clampedX = TranslatorLayout.clamp(
            centerX,
            min: leadingInset + TranslatorLayout.edgeMargin + half,
            max: width - trailingInset - TranslatorLayout.edgeMargin - half
        )
        let clampedY = TranslatorLayout.clamp(
            centerY,
            min: bandTop + half,
            max: bandBottom - half
        )

        return DPadSpec(
            x: ControlLimits.placedCoordinate.clamp(clampedX / width),
            y: ControlLimits.placedCoordinate.clamp(clampedY / height),
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
            let rightmost = width - trailingInset - TranslatorLayout.edgeMargin - buttonSize * 0.5
            return rightmost - Double(columnsPerRow - 1 - col) * pitch
        }
        let leftmost = leadingInset + TranslatorLayout.edgeMargin + buttonSize * 0.5
        return leftmost + Double(col) * pitch
    }

    private struct FitResult {
        var buttonSize: Double
        var dpadSize: Double
    }

    private static func nominalDpadSize(buttonSize: Double) -> Double {
        ControlLimits.dpadSize.clamp(3 * buttonSize)
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
        let available = metrics.usableHeight(isLandscape: isLandscape, edgeMargin: TranslatorLayout.edgeMargin)

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

            if size > ControlLimits.buttonSize.lowerBound {
                size -= 1
                dpad = nominalDpadSize(buttonSize: size)
            } else if dpad > ControlLimits.dpadSize.lowerBound {
                dpad -= 1
            } else {
                return FitResult(buttonSize: ControlLimits.buttonSize.lowerBound, dpadSize: ControlLimits.dpadSize.lowerBound)
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
        let pitch = buttonSize + TranslatorLayout.cellGap
        let leftKeysSpan = keyRowsSpan(rowCount: leftRowCount, buttonSize: buttonSize, pitch: pitch)
        let leftBandSpan = leftKeysSpan + TranslatorLayout.cellGap + dpadSize
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
        let leftmost = leadingInset + TranslatorLayout.edgeMargin + buttonSize * 0.5
        let rightmost = width - trailingInset - TranslatorLayout.edgeMargin - buttonSize * 0.5

        let gridSpan = Double(columnsPerRow - 1) * pitch
        let columnGap = rightmost - gridSpan - (leftmost + gridSpan)
        guard columnGap >= buttonSize else { return false }

        let dpadCenterX = leftmost + pitch
        let dpadRight = dpadCenterX + dpadSize * 0.5
        let rightGridLeft = rightmost - gridSpan - buttonSize * 0.5
        return rightGridLeft >= dpadRight
    }

    private static func keyRowsSpan(rowCount: Int, buttonSize: Double, pitch: Double) -> Double {
        guard rowCount > 0 else { return 0 }
        return Double(rowCount - 1) * pitch + buttonSize
    }

    /// When the compressed pitch still does not fit, the separation
    /// step at display time removes the overlap.
    private static func effectivePitch(
        buttonSize: Double, rowCount: Int, available: Double
    ) -> Double {
        let standard = buttonSize + TranslatorLayout.cellGap
        guard rowCount > 1 else { return standard }
        let span = Double(rowCount - 1) * standard + buttonSize
        if span <= available { return standard }
        return max((available - buttonSize) / Double(rowCount - 1), buttonSize + 1)
    }
}
