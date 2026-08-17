import Foundation
import GameProbe

/// Read/write `<container>/EmpoState/controls.json` (SPEC section 3 user layer, ticket 009).
enum UserControlsFile {
    static let logFileName = "controls.json.log"
    static let logPrefix = "user controls.json:"

    static func url(in container: GameContainer) -> URL {
        container.userControlsURL
    }

    static func exists(in container: GameContainer) -> Bool {
        FileManager.default.fileExists(atPath: url(in: container).path)
    }

    /// Parse the user manifest. Returns `nil` when the file is absent.
    static func load(in container: GameContainer) -> ControlsManifestLoader.Result? {
        let fileURL = url(in: container)
        guard FileManager.default.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL)
        else {
            return nil
        }
        return ControlsManifestLoader.parse(data: data)
    }

    static func logFindings(_ findings: [ControlsManifestLoader.Finding], container: GameContainer) {
        guard !findings.isEmpty else { return }
        for finding in findings {
            let severity = finding.severity == .error ? "error" : "warning"
            let line =
                "\(logPrefix) [\(finding.code)] (\(severity)) \(finding.path): \(finding.message)"
            container.appendLogLine(line, fileName: logFileName)
        }
    }

    /// Write or delete the user manifest. `nil` data removes the file.
    static func write(_ data: Data?, in container: GameContainer) -> Bool {
        let fileURL = url(in: container)
        guard let data else {
            try? FileManager.default.removeItem(at: fileURL)
            return true
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

    /// Replace the on-disk manifest. Keep the sections that this call does not update.
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

    /// Read-modify-write: update only the `touch` section.
    static func updateTouch(in container: GameContainer, touch: TouchSection?) -> Bool {
        let existing = acceptedManifest(in: container)
        return write(
            in: container,
            touch: touch,
            bindings: existing?.bindings
        )
    }

    /// Read-modify-write: update only the `bindings` section.
    static func updateBindings(in container: GameContainer, bindings: BindingMap?) -> Bool {
        let existing = acceptedManifest(in: container)
        return write(
            in: container,
            touch: existing?.touch,
            bindings: bindings
        )
    }

    static func removeTouchSection(in container: GameContainer) -> Bool {
        let existing = acceptedManifest(in: container)
        return write(in: container, touch: nil, bindings: existing?.bindings)
    }

    static func removeBindingsSection(in container: GameContainer) -> Bool {
        let existing = acceptedManifest(in: container)
        return write(in: container, touch: existing?.touch, bindings: nil)
    }

    private static func acceptedManifest(in container: GameContainer) -> ControlsManifest? {
        guard let result = load(in: container) else { return nil }
        let hasError = result.findings.contains { $0.severity == .error }
        guard !hasError else { return nil }
        return result.manifest
    }
}
