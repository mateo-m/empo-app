// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public enum JoiPlayControlsTranslator {
    public static let fileName = ControlsManifestLoader.ManifestLocation.joiplay.rawValue

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

    private static let knownKeys: Set<String> = [
        "btnOpacity", "btnScale",
        "aKeyCode", "bKeyCode", "cKeyCode", "xKeyCode", "yKeyCode", "zKeyCode", "lKeyCode", "rKeyCode",
    ]

    public static func translate(data: Data, metrics: TouchZoneMetrics) -> Translation {
        if data.count > ControlLimits.maxFileSize {
            return Translation(
                manifest: nil,
                notes: ["file is larger than \(ControlLimits.maxFileSizeText), ignored"])
        }

        guard let text = String(data: data, encoding: .utf8),
            let root = JSON5LiteParser.parseObject(text)
        else {
            return Translation(manifest: nil, notes: ["invalid JoiPlay gamepad file, ignored"])
        }

        guard root.keys.contains(where: { knownKeys.contains($0) }) else {
            return Translation(manifest: nil, notes: ["no JoiPlay keys, ignored"])
        }

        var notes: [String] = []

        let scalePercent: Double
        if let scaleValue = root["btnScale"] {
            if let scale = JSONNumber.double(scaleValue) {
                scalePercent = scale
            } else {
                scalePercent = 100
                notes.append("btnScale is not a number, using default 100")
            }
        } else {
            scalePercent = 100
        }

        let opacityPercent: Double
        if let opacityValue = root["btnOpacity"] {
            if let opacity = JSONNumber.double(opacityValue) {
                opacityPercent = opacity
            } else {
                opacityPercent = 100
                notes.append("btnOpacity is not a number, using default 100")
            }
        } else {
            opacityPercent = 100
        }

        let buttonOpacity = ControlLimits.opacity.clamp(opacityPercent / 100)
        let sizes = slots.map { ControlLimits.buttonSize.clamp($0.baseSize * scalePercent / 100) }
        let keys = slots.map { slot -> String in
            guard let keyValue = root[slot.keyField] else { return slot.defaultKey }
            guard let keycode = JSONNumber.int(keyValue) else {
                notes.append("\(slot.keyField) is not an integer; using default")
                return slot.defaultKey
            }
            guard let w3c = AndroidKeycodeTable.w3cCode(for: keycode) else {
                notes.append(
                    "\(slot.keyField): Android keycode \(keycode) has no keyboard equivalent; using default")
                return slot.defaultKey
            }
            return w3c
        }

        let portraitButtons = buildButtons(
            metrics: metrics,
            isLandscape: false,
            sizes: sizes,
            keys: keys,
            buttonOpacity: buttonOpacity
        )
        let landscapeButtons = buildButtons(
            metrics: metrics,
            isLandscape: true,
            sizes: sizes,
            keys: keys,
            buttonOpacity: buttonOpacity
        )

        let touch = TouchSection(
            portrait: TouchLayout(dpad: nil, buttons: portraitButtons),
            landscape: TouchLayout(dpad: nil, buttons: landscapeButtons)
        )
        let manifest = ControlsManifest(version: 1, touch: touch)

        return Translation(manifest: manifest, notes: notes)
    }

    private static func buildButtons(
        metrics: TouchZoneMetrics,
        isLandscape: Bool,
        sizes: [Double],
        keys: [String],
        buttonOpacity: Double
    ) -> [ButtonSpec] {
        let width = metrics.width(isLandscape: isLandscape)
        let height = metrics.height(isLandscape: isLandscape)
        let topInset = metrics.topInset(isLandscape: isLandscape)
        let bottomInset = metrics.bottomInset(isLandscape: isLandscape)

        func row(_ slot: Slot) -> Int { isLandscape ? slot.landscapeRow : slot.portraitRow }
        func col(_ slot: Slot) -> Int { isLandscape ? slot.landscapeCol : slot.portraitCol }

        var clusterSizes = sizes
        let clusterIndexes = slots.indices.filter { slots[$0].cluster == .bottomRightArc }
        let cornerIndexes = slots.indices.filter { slots[$0].cluster != .bottomRightArc }
        guard let anchorIndex = clusterIndexes.first(where: { row(slots[$0]) == 0 && col(slots[$0]) == 0 })
        else { return [] }
        let maxClusterRow = clusterIndexes.map { row(slots[$0]) }.max() ?? 0
        let maxClusterCol = clusterIndexes.map { col(slots[$0]) }.max() ?? 0

        func clusterAnchorY(cSize: Double) -> Double {
            height - bottomInset - TranslatorLayout.edgeMargin - cSize * 0.5
        }

        var clusterPitch: Double = 0
        var clusterAnchorX: Double = 0
        var clusterAnchorYValue: Double = 0

        while true {
            let maxClusterSize = clusterIndexes.reduce(0) { max($0, clusterSizes[$1]) }
            clusterPitch = maxClusterSize + TranslatorLayout.cellGap
            let cSize = clusterSizes[anchorIndex]
            clusterAnchorX =
                width - metrics.trailingInset(isLandscape: isLandscape) - TranslatorLayout.edgeMargin - cSize
                * 0.5
            clusterAnchorYValue = clusterAnchorY(cSize: cSize)

            let spanY = Double(maxClusterRow) * clusterPitch + maxClusterSize
            let spanX = Double(maxClusterCol) * clusterPitch + maxClusterSize
            let topClusterEdge =
                clusterAnchorYValue - Double(maxClusterRow) * clusterPitch - maxClusterSize * 0.5
            let topCornerBottom =
                topInset + TranslatorLayout.edgeMargin + cornerIndexes.reduce(0) { max($0, clusterSizes[$1]) }
            let usableHeight = metrics.usableHeight(
                isLandscape: isLandscape, edgeMargin: TranslatorLayout.edgeMargin)

            let fits =
                spanY <= usableHeight
                && spanX <= width - 2 * TranslatorLayout.edgeMargin
                && topClusterEdge >= topCornerBottom + TranslatorLayout.cellGap

            if fits { break }

            var shrunk = false
            for index in clusterIndexes where clusterSizes[index] > ControlLimits.buttonSize.lowerBound {
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
            let key = keys[index]

            let point: (x: Double, y: Double)
            switch slot.cluster {
            case .bottomRightArc:
                point = (
                    clusterAnchorX - Double(col(slot)) * clusterPitch,
                    clusterAnchorYValue - Double(row(slot)) * clusterPitch
                )
            case .topLeft:
                point = (
                    metrics.leadingInset(isLandscape: isLandscape) + TranslatorLayout.edgeMargin + size * 0.5,
                    topInset + TranslatorLayout.edgeMargin + size * 0.5
                )
            case .topRight:
                point = (
                    width - metrics.trailingInset(isLandscape: isLandscape) - TranslatorLayout.edgeMargin
                        - size * 0.5,
                    topInset + TranslatorLayout.edgeMargin + size * 0.5
                )
            }

            buttons.append(
                ButtonSpec(
                    label: slot.label,
                    key: key,
                    x: ControlLimits.placedCoordinate.clamp(point.x / width),
                    y: ControlLimits.placedCoordinate.clamp(point.y / height),
                    size: size,
                    opacity: buttonOpacity
                )
            )
        }

        return buttons
    }
}
