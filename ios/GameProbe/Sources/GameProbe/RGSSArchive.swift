// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// Reads one file out of an encrypted RPG Maker archive. `.rgssad` and
/// `.rgss2a` use the version 1 layout, and `.rgss3a` uses version 3.
enum RGSSArchive {

    /// The `.ini` file that the engine reads, and its `Scripts=` path.
    /// `Game.ini` needs only `Scripts=`. Another `.ini` file also needs
    /// `Library=`.
    static func gameINI(in gameDirectory: URL, fm: FileManager) -> (name: String, scripts: String)? {
        GameINI.iniFileURLs(at: gameDirectory, fm: fm).lazy.compactMap { url -> (String, String)? in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            guard let scripts = GameINI.parseINIValue(in: url, section: "game", key: "scripts"),
                !scripts.isEmpty,
                name == "game"
                    || GameINI.parseINIValue(in: url, section: "game", key: "library")?.isEmpty == false
            else { return nil }
            return (name, scripts)
        }.first
    }

    /// The engine mounts only the archive with the name of its `.ini` file.
    static func mountable(in gameDirectory: URL, fm: FileManager) -> [URL] {
        let name = gameINI(in: gameDirectory, fm: fm)?.name ?? "game"
        return gameDirectory.directoryEntries(matchingExtensions: ["rgssad", "rgss2a", "rgss3a"], fm: fm)
            .filter { $0.deletingPathExtension().lastPathComponent.lowercased() == name }
    }

    /// The decrypted bytes of the first entry whose path is in `paths`.
    /// The comparison ignores case, and `\` and `/` are the same.
    static func file(at paths: Set<String>, in archive: URL) -> Data? {
        guard let data = try? Data(contentsOf: archive, options: .alwaysMapped),
            data.count >= 8, data.prefix(7) == Data("RGSSAD\0".utf8)
        else { return nil }
        var reader = Reader(data: data, offset: 8)
        switch data[data.startIndex + 7] {
        case 1: return reader.version1File(at: paths)
        case 3: return reader.version3File(at: paths)
        default: return nil
        }
    }

    private static func nextKey(_ key: UInt32) -> UInt32 { key &* 7 &+ 3 }

    private static func normalized(_ name: [UInt8]) -> String {
        (String(bytes: name, encoding: .utf8) ?? "").replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    /// Each 4 bytes of data use the next key. The result starts at index 0,
    /// as the Marshal reader expects.
    private static func decrypt(_ data: Data, key: UInt32) -> Data {
        var key = key
        var out = Data(data)
        out.withUnsafeMutableBytes { bytes in
            for start in stride(from: 0, to: bytes.count, by: 4) {
                for i in start..<min(start + 4, bytes.count) {
                    bytes[i] ^= UInt8(truncatingIfNeeded: key >> (8 * UInt32(i - start)))
                }
                key = nextKey(key)
            }
        }
        return out
    }

    private struct Reader {
        let data: Data
        var offset: Int

        private static let maxNameLength = 512

        mutating func u32() -> UInt32? {
            guard data.count - offset >= 4 else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: value)
        }

        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, data.count - offset >= count else { return nil }
            let start = data.startIndex + offset
            offset += count
            return data[start..<start + count]
        }

        /// Each entry is a name length, a name, a size, and the data. The key
        /// moves on after each length, each name byte, and the size.
        mutating func version1File(at paths: Set<String>) -> Data? {
            var key: UInt32 = 0xDEAD_CAFE
            func take() -> UInt32 {
                defer { key = RGSSArchive.nextKey(key) }
                return key
            }
            while offset < data.count {
                guard let nameLength = u32().map({ Int($0 ^ take()) }),
                    nameLength <= Self.maxNameLength,
                    let name = bytes(nameLength)
                else { return nil }
                let path = RGSSArchive.normalized(name.map { $0 ^ UInt8(truncatingIfNeeded: take()) })
                guard let size = u32().map({ Int($0 ^ take()) }), let body = bytes(size) else { return nil }
                if paths.contains(path) { return RGSSArchive.decrypt(body, key: key) }
            }
            return nil
        }

        /// A table of entries with an offset, a size, a data key, and a name,
        /// all under one key from the header. A zero offset ends the table.
        mutating func version3File(at paths: Set<String>) -> Data? {
            guard let base = u32() else { return nil }
            let key = base &* 9 &+ 3
            while let entryOffset = u32().map({ Int($0 ^ key) }), entryOffset != 0 {
                guard let size = u32().map({ Int($0 ^ key) }),
                    let dataKey = u32().map({ $0 ^ key }),
                    let nameLength = u32().map({ Int($0 ^ key) }),
                    nameLength <= Self.maxNameLength,
                    let name = bytes(nameLength)
                else { return nil }
                let path = RGSSArchive.normalized(
                    name.enumerated().map { $1 ^ UInt8(truncatingIfNeeded: key >> (8 * UInt32($0 % 4))) })
                guard paths.contains(path) else { continue }
                var body = Reader(data: data, offset: entryOffset)
                return body.bytes(size).map { RGSSArchive.decrypt($0, key: dataKey) }
            }
            return nil
        }
    }
}
