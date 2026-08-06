import Foundation

/// File-backed store for layout profiles: one folder per profile
/// under the profiles root, holding a plain v1 `controls.json`. The
/// games root is injected too, because rename and delete must walk
/// every game's pin file.
public struct LayoutProfileStore {
    public let profilesRoot: URL
    public let gamesRoot: URL

    public init(profilesRoot: URL, gamesRoot: URL) {
        self.profilesRoot = profilesRoot
        self.gamesRoot = gamesRoot
    }

    // MARK: - Names

    /// Extends the game-folder rule with a leading-`$` rejection so a
    /// profile can never collide with the pin sentinels. Returns nil
    /// for an unusable name; never silently strips.
    public static func validatedName(_ raw: String) -> String? {
        let name = raw.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else { return nil }
        guard !name.hasPrefix("$"), !name.hasPrefix(".") else { return nil }
        guard !name.contains("/"), !name.contains("\\"), name != ".." else { return nil }
        return name
    }

    /// "Firered", "Firered 2", "Firered 3", …
    public func uniqueName(base: String) -> String {
        let existing = Set(listProfiles())
        let cleanBase = Self.validatedName(base) ?? "Layout"
        if !existing.contains(cleanBase) { return cleanBase }
        var index = 2
        while existing.contains("\(cleanBase) \(index)") {
            index += 1
        }
        return "\(cleanBase) \(index)"
    }

    // MARK: - Paths

    public func profileURL(_ name: String) -> URL {
        profilesRoot.appendingPathComponent(name, isDirectory: true)
    }

    public func controlsURL(_ name: String) -> URL {
        profileURL(name).appendingPathComponent("controls.json")
    }

    public func screenURL(_ name: String) -> URL {
        profileURL(name).appendingPathComponent(ScreenRegionFile.fileName)
    }

    private func logURL(_ name: String, file: String = "controls.json") -> URL {
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
        FileManager.default.fileExists(atPath: controlsURL(name).path)
    }

    public struct ProfileRead {
        public var touch: TouchSection?
        public var controller: ControllerMap?
        /// True when the file exists but did not yield a usable touch
        /// section (parse errors, or no touch key). The chain treats
        /// this as missing.
        public var invalid: Bool
        /// Error findings behind `invalid`, for the edit-mode footnote.
        public var errorCount: Int = 0
    }

    /// Reads a profile's touch section. Error findings go to the
    /// profile's own log file; a `controller` section is carried (for
    /// preservation on save) but ignored at resolution.
    public func readProfile(_ name: String) -> ProfileRead? {
        let url = controlsURL(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let result = ControlsManifestLoader.parse(data: data)
        let errors = result.findings.filter { $0.severity == .error }
        if !errors.isEmpty || result.ignoredNewerVersion {
            appendLog(name, line: "controls.json: rejected (\(errors.count) errors)")
            for finding in errors {
                appendLog(name, line: "  [\(finding.code)] \(finding.path): \(finding.message)")
            }
            return ProfileRead(
                touch: nil, controller: nil, invalid: true, errorCount: max(errors.count, 1))
        }
        if result.manifest?.controller != nil {
            appendLog(name, line: "controls.json: controller section ignored (profiles hold touch only)")
        }
        guard let touch = result.manifest?.touch else {
            return ProfileRead(
                touch: nil, controller: result.manifest?.controller, invalid: true, errorCount: 1)
        }
        return ProfileRead(touch: touch, controller: result.manifest?.controller, invalid: false)
    }

    // MARK: - Writing

    /// Writes a profile's touch section. A `controller` section a
    /// user hand-added to the file is preserved verbatim-parsed, and
    /// stays ignored at resolution.
    @discardableResult
    public func writeProfile(_ name: String, touch: TouchSection) -> Bool {
        let preservedController = readProfile(name)?.controller
        guard
            let data = ControlsManifestSerializer.serialize(
                touch: touch, controller: preservedController)
        else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: profileURL(name), withIntermediateDirectories: true)
            try data.write(to: controlsURL(name), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func createProfile(_ name: String, touch: TouchSection) -> Bool {
        guard Self.validatedName(name) == name, !profileExists(name) else { return false }
        return writeProfile(name, touch: touch)
    }

    /// Copy → walk pins → delete: every midpoint leaves a working
    /// state (old pins still resolve until the old folder goes).
    @discardableResult
    public func renameProfile(from oldName: String, to newName: String) -> Bool {
        guard Self.validatedName(newName) == newName, profileExists(oldName),
            !profileExists(newName)
        else { return false }
        let fm = FileManager.default
        do {
            try fm.copyItem(at: profileURL(oldName), to: profileURL(newName))
        } catch {
            return false
        }
        updatePins(matching: oldName, to: .profile(newName))
        try? fm.removeItem(at: profileURL(oldName))
        return true
    }

    /// Clears every pin to the profile first, so no game dangles.
    @discardableResult
    public func deleteProfile(_ name: String) -> Bool {
        updatePins(matching: name, to: .followChain)
        do {
            try FileManager.default.removeItem(at: profileURL(name))
            return true
        } catch {
            return false
        }
    }

    /// Folder copy, so `screen.json` travels with the profile. The
    /// copy drops the log files (they describe the original) and
    /// re-serializes `controls.json` for canonical bytes.
    @discardableResult
    public func duplicateProfile(_ name: String) -> String? {
        guard let read = readProfile(name), let touch = read.touch else { return nil }
        let copyName = uniqueName(base: name)
        guard Self.validatedName(copyName) == copyName, !profileExists(copyName) else {
            return nil
        }
        let fm = FileManager.default
        do {
            try fm.copyItem(at: profileURL(name), to: profileURL(copyName))
        } catch {
            return nil
        }
        try? fm.removeItem(at: logURL(copyName))
        try? fm.removeItem(at: logURL(copyName, file: ScreenRegionFile.fileName))
        guard writeProfile(copyName, touch: touch) else {
            try? fm.removeItem(at: profileURL(copyName))
            return nil
        }
        return copyName
    }

    // MARK: - Screen region

    /// nil when the file is absent. Invalid content parses to a
    /// result with findings and nil regions; the caller logs.
    public func readScreen(_ name: String) -> ScreenRegionFile.ReadResult? {
        guard let data = try? Data(contentsOf: screenURL(name)) else { return nil }
        return ScreenRegionFile.parse(data)
    }

    /// Both orientations nil deletes the file: an empty
    /// `screen.json` must not exist.
    @discardableResult
    public func writeScreen(
        _ name: String, portrait: ScreenRegion?, landscape: ScreenRegion?
    ) -> Bool {
        guard profileExists(name) else { return false }
        let fm = FileManager.default
        guard let data = ScreenRegionFile.serialize(portrait: portrait, landscape: landscape)
        else {
            try? fm.removeItem(at: screenURL(name))
            return true
        }
        do {
            try data.write(to: screenURL(name), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Pins

    public func pinURL(forGameFolder folder: URL) -> URL {
        folder.appendingPathComponent("EmpoState").appendingPathComponent(LayoutPinFile.fileName)
    }

    public func loadPin(forGameFolder folder: URL) -> (pin: LayoutPin, note: String?) {
        LayoutPinFile.load(from: pinURL(forGameFolder: folder))
    }

    @discardableResult
    public func writePin(_ pin: LayoutPin, forGameFolder folder: URL) -> Bool {
        let url = pinURL(forGameFolder: folder)
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LayoutPinFile.serialize(pin).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
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

    /// Folders whose pin names the profile.
    public func gamesPinned(to name: String) -> [URL] {
        gameFolders().filter { folder in
            if case .profile(let pinned) = loadPin(forGameFolder: folder).pin {
                return pinned == name
            }
            return false
        }
    }

    private func updatePins(matching name: String, to newPin: LayoutPin) {
        for folder in gamesPinned(to: name) {
            writePin(newPin, forGameFolder: folder)
        }
    }

    // MARK: - Log

    public func appendLog(_ name: String, file: String = "controls.json", line: String) {
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
