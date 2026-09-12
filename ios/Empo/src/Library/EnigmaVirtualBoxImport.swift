import Foundation
import GameProbe

/// Unpacks games whose files ship inside an Enigma Virtual Box exe.
/// At runtime the packer serves a packed file before a loose file at
/// the same path, so a packed entry overwrites a loose one here too.
enum EnigmaVirtualBoxImport {

    /// True when any exe under `directory` holds a packed file tree.
    static func containsPackedExecutable(under directory: URL) -> Bool {
        packedExecutables(under: directory).isEmpty == false
    }

    /// Unpacks only the files the import probe reads, next to each
    /// packed exe: INI files, mkxp.json, the scripts file, RGSS
    /// archive markers, and title artwork.
    static func unpackProbeFiles(under directory: URL) throws {
        for package in packedExecutables(under: directory) {
            let root = package.executableURL.deletingLastPathComponent()
            for entry in package.entries where isProbeFile(entry.path) {
                try package.unpack(entry, to: root.appendingPathComponent(entry.path))
            }
        }
    }

    /// Unpacks every entry next to each packed exe, then removes the
    /// packed exe. The container ships the real game exe, so the
    /// packed one has no use after this.
    static func unpackAll(under directory: URL, shouldCancel: () -> Bool) throws {
        let fm = FileManager.default
        for package in packedExecutables(under: directory) {
            let root = package.executableURL.deletingLastPathComponent()
            let packedName = package.executableURL.lastPathComponent
            for entry in package.entries {
                if shouldCancel() { throw GameLibrary.ImportCancelled() }
                try package.unpack(entry, to: root.appendingPathComponent(entry.path))
            }
            if !package.entries.contains(where: { $0.path == packedName }) {
                try fm.removeItem(at: package.executableURL)
            }
        }
    }

    private static func packedExecutables(under directory: URL) -> [EnigmaVirtualBox] {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        var found: [EnigmaVirtualBox] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "exe" else { continue }
            if let package = EnigmaVirtualBox.open(url) {
                found.append(package)
            }
        }
        return found
    }

    private static func isProbeFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        let components = lower.split(separator: "/")
        guard let name = components.last else { return false }
        if components.count == 1 {
            return name.hasSuffix(".ini") || name == "mkxp.json"
                || name.hasSuffix(".rgssad") || name.hasSuffix(".rgss2a") || name.hasSuffix(".rgss3a")
        }
        if components.count == 2, components[0] == "data" {
            return name == "scripts.rxdata" || name == "scripts.rvdata" || name == "scripts.rvdata2"
        }
        if components.count == 3, components[0] == "graphics", components[1] == "titles" {
            let ext = (name as NSString).pathExtension
            return ["png", "jpg", "jpeg", "bmp"].contains(String(ext))
        }
        return false
    }
}
