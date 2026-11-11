// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

enum UserControlsFile {
    static let logFileName = "controls.json.log"
    static let logPrefix = "user controls.json:"

    static func exists(in container: GameContainer) -> Bool {
        FileManager.default.fileExists(atPath: container.userControlsURL.path)
    }

    static func load(in container: GameContainer) -> ControlsManifestLoader.Result? {
        let fileURL = container.userControlsURL
        guard FileManager.default.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL)
        else {
            return nil
        }
        return ControlsManifestLoader.parse(data: data)
    }

    static func loadAndLog(in container: GameContainer) -> ControlsManifestLoader.Result? {
        let result = load(in: container)
        for finding in result?.findings ?? [] {
            container.appendLogLine(finding.logLine(prefix: logPrefix), fileName: logFileName)
        }
        return result
    }

    enum SaveRefusal: Error {
        case fileHasErrors
        case fileNeedsNewerEmpo
    }

    static func acceptedManifest(in container: GameContainer) -> ControlsManifest? {
        load(in: container).flatMap(accepted)
    }

    private static func accepted(_ result: ControlsManifestLoader.Result) -> ControlsManifest? {
        guard !result.findings.contains(where: { $0.severity == .error }) else { return nil }
        return result.manifest
    }

    private static func write(_ data: Data?, in container: GameContainer) -> Bool {
        let fileURL = container.userControlsURL
        guard let data else {
            guard exists(in: container) else { return true }
            do {
                try FileManager.default.removeItem(at: fileURL)
                return true
            } catch {
                NSLog("controls.json: Failed to remove user controls: \(error.localizedDescription)")
                return false
            }
        }
        container.ensureEmpoStateDirectory()
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            NSLog("controls.json: Failed to write user controls: \(error.localizedDescription)")
            return false
        }
    }

    static func write(
        in container: GameContainer,
        touch: TouchSection?,
        bindings: BindingMap?
    ) -> Bool {
        guard let data = ControlsManifestSerializer.serialize(touch: touch, bindings: bindings)
        else {
            return write(nil, in: container)
        }
        return write(data, in: container)
    }

    /// A file that Empo cannot use stays as it is, because a write keeps
    /// only the parts that Empo can read.
    static func updateBindings(
        in container: GameContainer, bindings: BindingMap?
    ) throws(SaveRefusal) -> Bool {
        guard exists(in: container) else {
            return write(in: container, touch: nil, bindings: bindings)
        }
        guard let result = load(in: container) else { throw .fileHasErrors }
        if result.ignoredNewerVersion { throw .fileNeedsNewerEmpo }
        guard let manifest = accepted(result) else { throw .fileHasErrors }
        return write(in: container, touch: manifest.touch, bindings: bindings)
    }
}
