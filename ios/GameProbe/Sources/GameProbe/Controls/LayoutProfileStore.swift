// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public struct LayoutProfileStore {
    public let profilesRoot: URL
    public let gamesRoot: URL

    public init(profilesRoot: URL, gamesRoot: URL) {
        self.profilesRoot = profilesRoot
        self.gamesRoot = gamesRoot
    }

    // MARK: - Names

    public static let maxNameLength = 64

    public static func validatedName(_ raw: String) -> String? {
        let name = raw.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maxNameLength else { return nil }
        guard !name.hasPrefix(LayoutPinFile.sentinelPrefix), !name.hasPrefix(".") else {
            return nil
        }
        guard !name.contains("/"), !name.contains("\\") else { return nil }
        return name
    }

    /// The Mac disk ignores case and the iPhone disk does not, so
    /// names that differ only by case name one profile on both.
    public static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    public func uniqueName(base: String) -> String {
        let taken = Set(listProfiles().map(Self.nameKey))
        let name = Self.validatedName(base) ?? "Layout"
        guard taken.contains(Self.nameKey(name)) else { return name }
        let suffixRoom = " 999".count
        let stem = String(name.prefix(Self.maxNameLength - suffixRoom))
            .trimmingCharacters(in: .whitespaces)
        return GameFolderName.uniqueName(preferring: stem) { taken.contains(Self.nameKey($0)) }
    }

    /// The name of the folder on disk for `name`, in the case of the folder.
    public func storedName(_ name: String) -> String? {
        Self.folder(named: name, in: listProfiles())
    }

    /// An older version let an iPhone keep two folders whose names
    /// differ only by case, so the exact name comes first.
    private static func folder(named name: String, in folders: [String]) -> String? {
        let name = name.precomposedStringWithCanonicalMapping
        if folders.contains(name) { return name }
        let key = nameKey(name)
        return folders.first { nameKey($0) == key }
    }

    // MARK: - Paths

    /// A disk that ignores case finds the folder at the direct path. A
    /// disk that does not ignore case needs the scan.
    public func profileURL(_ name: String) -> URL {
        let direct = profilesRoot.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        return profilesRoot.appendingPathComponent(storedName(name) ?? name, isDirectory: true)
    }

    public func controlsURL(_ name: String) -> URL {
        profileURL(name).appendingPathComponent(ControlsManifestLoader.ManifestLocation.root.rawValue)
    }

    public func screenURL(_ name: String) -> URL {
        profileURL(name).appendingPathComponent(ScreenRegionFile.fileName)
    }

    private func logURL(
        _ name: String, file: String = ControlsManifestLoader.ManifestLocation.root.rawValue
    ) -> URL {
        profileURL(name).appendingPathComponent(file + ".log")
    }

    // MARK: - Listing and reading

    public func listProfiles() -> [String] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: profilesRoot, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return
            entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent.precomposedStringWithCanonicalMapping }
            .filter { Self.validatedName($0) != nil }
            .sorted()
    }

    public func profileExists(_ name: String) -> Bool {
        Self.validatedName(name) != nil
            && FileManager.default.fileExists(atPath: controlsURL(name).path)
    }

    public struct ProfileRead {
        public var touch: TouchSection?
        public var bindings: BindingMap?
        public var errors: [ControlsManifestLoader.Finding]
        public var ignoredNewerVersion: Bool
    }

    public func validTouch(_ name: String) -> TouchSection? {
        readProfile(name)?.touch
    }

    public func readProfile(_ name: String) -> ProfileRead? {
        guard let data = try? Data(contentsOf: controlsURL(name)) else { return nil }
        let result = ControlsManifestLoader.parse(data: data)
        let errors = result.findings.filter { $0.severity == .error }
        let usable = errors.isEmpty && !result.ignoredNewerVersion
        return ProfileRead(
            touch: usable ? result.manifest?.touch : nil,
            bindings: usable ? result.manifest?.bindings : nil,
            errors: errors,
            ignoredNewerVersion: result.ignoredNewerVersion)
    }

    public func logProblems(_ name: String, read: ProfileRead) {
        let file = ControlsManifestLoader.ManifestLocation.root.rawValue
        if read.ignoredNewerVersion {
            appendLog(name, line: "\(file): rejected (newer version)")
        } else if !read.errors.isEmpty {
            appendLog(name, line: "\(file): rejected (\(read.errors.count) errors)")
            for finding in read.errors {
                appendLog(name, line: "  [\(finding.code)] \(finding.path): \(finding.message)")
            }
        } else if read.bindings != nil {
            appendLog(name, line: "\(file): bindings section ignored (profiles hold touch only)")
        }
    }

    // MARK: - Writing

    public enum StoreError: Error, Equatable {
        case invalidName(String)
        case nameTaken(String)
        case missing(String)
    }

    /// A `bindings` section that a user added to the file by hand
    /// stays in the file.
    public func writeProfile(_ name: String, touch: TouchSection) throws {
        // A synced name such as ".." would resolve outside the root.
        guard Self.validatedName(name) != nil else { throw StoreError.invalidName(name) }
        let data = ControlsManifestSerializer.serialize(
            touch, bindings: readProfile(name)?.bindings)
        try FileManager.default.createDirectory(
            at: profileURL(name), withIntermediateDirectories: true)
        try data.write(to: controlsURL(name), options: .atomic)
    }

    public func createProfile(_ name: String, touch: TouchSection) throws {
        guard Self.validatedName(name) == name else { throw StoreError.invalidName(name) }
        guard !profileExists(name) else { throw StoreError.nameTaken(name) }
        let folderExisted = FileManager.default.fileExists(atPath: profileURL(name).path)
        do {
            try writeProfile(name, touch: touch)
        } catch {
            if !folderExisted { try? FileManager.default.removeItem(at: profileURL(name)) }
            throw error
        }
    }

    /// Copy, then move the pins and the record, then delete: a crash
    /// at any step leaves each pin on a profile that exists. A failed
    /// copy, pin, or record step undoes the steps before it. A failed
    /// undo of a pin keeps the new folder, because that pin still
    /// points to it. A failed delete keeps both folders, because a
    /// partial delete can leave the new folder as the only full copy.
    public func renameProfile(from oldName: String, to newName: String) throws {
        guard Self.validatedName(newName) == newName else { throw StoreError.invalidName(newName) }
        guard profileExists(oldName), let stored = storedName(oldName) else {
            throw StoreError.missing(oldName)
        }
        if storedName(newName) == stored {
            if stored != newName { try renameCase(of: stored, to: newName) }
            return
        }
        guard !profileExists(newName) else { throw StoreError.nameTaken(newName) }
        let fm = FileManager.default
        let pinned = gamesPinned(to: oldName)
        try fm.copyItem(at: profileURL(oldName), to: profileURL(newName))
        if let failure = repoint(pinned, from: oldName, to: newName) {
            if failure.restored { try? fm.removeItem(at: profileURL(newName)) }
            throw failure.error
        }
        do {
            try fm.removeItem(at: profileURL(oldName))
        } catch {
            appendLog(newName, line: "rename: could not delete \(oldName): \(error)")
        }
    }

    /// One move of the folder, because a disk that ignores case
    /// cannot hold the copy next to the original.
    private func renameCase(of oldName: String, to newName: String) throws {
        let fm = FileManager.default
        let oldURL = profilesRoot.appendingPathComponent(oldName, isDirectory: true)
        let newURL = profilesRoot.appendingPathComponent(newName, isDirectory: true)
        let pinned = gamesPinned(to: oldName)
        try fm.moveItem(at: oldURL, to: newURL)
        if let failure = repoint(pinned, from: oldName, to: newName) {
            // A pin that keeps the new case still finds the folder by
            // its name key.
            try? fm.moveItem(at: newURL, to: oldURL)
            throw failure.error
        }
    }

    /// Moves each pin and the record to `newName`. A failure puts the
    /// moved pins back. `restored` is false when a pin cannot go back.
    private func repoint(
        _ pinned: [URL], from oldName: String, to newName: String
    ) -> (error: Error, restored: Bool)? {
        var moved: [URL] = []
        do {
            for folder in pinned {
                try writePin(.profile(newName), forGameFolder: folder)
                moved.append(folder)
            }
            try renameInMigrationRecord(from: oldName, to: newName)
            return nil
        } catch {
            var restored = true
            for folder in moved {
                do {
                    try writePin(.profile(oldName), forGameFolder: folder)
                } catch {
                    restored = false
                }
            }
            return (error, restored)
        }
    }

    /// An unreadable record stays as it is, so that the next launch
    /// does not read it as empty and migrate every game again.
    private func renameInMigrationRecord(from oldName: String, to newName: String) throws {
        let url = profilesRoot.appendingPathComponent(MigrationRecord.fileName)
        guard let old = MigrationRecord.load(at: url) else { return }
        var record = old
        record.renameProfile(from: oldName, to: newName)
        if record != old { try record.save(to: url) }
    }

    /// Clears every pin to the profile first, so no game dangles.
    public func deleteProfile(_ name: String) throws {
        guard Self.validatedName(name) != nil else { throw StoreError.invalidName(name) }
        try updatePins(matching: name, to: .followChain)
        try FileManager.default.removeItem(at: profileURL(name))
    }

    /// Folder copy, so `screen.json` travels with the profile. The
    /// copy drops the log files (they describe the original) and
    /// re-serializes `controls.json` for canonical bytes.
    public func duplicateProfile(_ name: String) throws -> String {
        guard let touch = readProfile(name)?.touch else { throw StoreError.missing(name) }
        let copyName = uniqueName(base: name)
        guard Self.validatedName(copyName) == copyName else { throw StoreError.invalidName(copyName) }
        guard !profileExists(copyName) else { throw StoreError.nameTaken(copyName) }
        let fm = FileManager.default
        try fm.copyItem(at: profileURL(name), to: profileURL(copyName))
        do {
            for log in [logURL(copyName), logURL(copyName, file: ScreenRegionFile.fileName)]
            where fm.fileExists(atPath: log.path) {
                try fm.removeItem(at: log)
            }
            try writeProfile(copyName, touch: touch)
        } catch {
            try? fm.removeItem(at: profileURL(copyName))
            throw error
        }
        return copyName
    }

    // MARK: - Screen region

    public func readScreen(_ name: String) -> ScreenRegionFile.ReadResult? {
        guard let data = try? Data(contentsOf: screenURL(name)) else { return nil }
        return ScreenRegionFile.parse(data)
    }

    /// Both orientations nil deletes the file: an empty
    /// `screen.json` must not exist.
    public func writeScreen(
        _ name: String, portrait: ScreenPlacement?, landscape: ScreenPlacement?
    ) throws {
        guard profileExists(name) else { throw StoreError.missing(name) }
        let url = screenURL(name)
        if let data = ScreenRegionFile.serialize(portrait: portrait, landscape: landscape) {
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Pins

    public func pinURL(forGameFolder folder: URL) -> URL {
        folder.appendingPathComponent("EmpoState").appendingPathComponent(LayoutPinFile.fileName)
    }

    public func loadPin(forGameFolder folder: URL) -> (pin: LayoutPin, note: String?) {
        LayoutPinFile.load(from: pinURL(forGameFolder: folder))
    }

    public func writePin(_ pin: LayoutPin, forGameFolder folder: URL) throws {
        let url = pinURL(forGameFolder: folder)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LayoutPinFile.serialize(pin).write(to: url, options: .atomic)
    }

    public func gameFolders() -> [URL] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: gamesRoot, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    public func gamesPinned(to name: String) -> [URL] {
        let folders = listProfiles()
        let target = Self.folder(named: name, in: folders) ?? Self.nameKey(name)
        return gameFolders().filter { folder in
            guard case .profile(let pinned) = loadPin(forGameFolder: folder).pin else { return false }
            return (Self.folder(named: pinned, in: folders) ?? Self.nameKey(pinned)) == target
        }
    }

    private func updatePins(matching name: String, to newPin: LayoutPin) throws {
        for folder in gamesPinned(to: name) {
            try writePin(newPin, forGameFolder: folder)
        }
    }

    // MARK: - Log

    /// A log line that cannot be written is lost. The log is the place
    /// where a failure would go.
    public func appendLog(
        _ name: String, file: String = ControlsManifestLoader.ManifestLocation.root.rawValue,
        line: String
    ) {
        guard Self.validatedName(name) != nil else { return }
        let url = logURL(name, file: file)
        let fm = FileManager.default
        try? fm.createDirectory(at: profileURL(name), withIntermediateDirectories: true)
        let entry = Data((line.hasSuffix("\n") ? line : line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: entry)
        } else {
            try? entry.write(to: url)
        }
    }
}
