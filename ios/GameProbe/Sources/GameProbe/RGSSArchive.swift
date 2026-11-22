// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// Reads one file out of an encrypted RPG Maker archive. `.rgssad` and
/// `.rgss2a` use the version 1 layout, and `.rgss3a` uses version 3.
enum RGSSArchive {

    /// The `.ini` file that the engine reads, and its `Scripts=` path. The
    /// engine reads `<execName>.ini` first, with `execName` from
    /// `mkxp.json` or "Game". Another `.ini` file also needs `Library=`.
    static func gameINI(in gameDirectory: URL, fm: FileManager) -> (name: String, scripts: String)? {
        let execName = execName(in: gameDirectory).lowercased()
        let urls = GameINI.iniFileURLs(at: gameDirectory, fm: fm)
        func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
        let ordered =
            urls.filter { name($0).lowercased() == execName }
            + urls.filter { name($0).lowercased() != execName }
        return ordered.lazy.compactMap { url -> (String, String)? in
            guard let scripts = GameINI.parseINIValue(in: url, section: "game", key: "scripts"),
                !scripts.isEmpty,
                name(url).lowercased() == execName
                    || GameINI.parseINIValue(in: url, section: "game", key: "library")?.isEmpty == false
            else { return nil }
            return (name(url), scripts)
        }.first
    }

    /// The engine opens one archive by its exact name: the `.ini` name with
    /// the extension of its RGSS version. `rgssVersion` in `mkxp.json` sets the version. Else
    /// the `Scripts=` extension sets it, and the engine compares it with case.
    static func mountable(in gameDirectory: URL, fm: FileManager) -> URL? {
        let ini = gameINI(in: gameDirectory, fm: fm)
        let name = ini?.name ?? execName(in: gameDirectory)
        let version: Int
        if let configured = ManagedMkxpConfig.loadBaseDict(from: gameDirectory)?["rgssVersion"] as? Int,
            configured > 0
        {
            version = min(configured, 3)
        } else if ini?.scripts.hasSuffix(".rvdata2") == true {
            version = 3
        } else if ini?.scripts.hasSuffix(".rvdata") == true {
            version = 2
        } else {
            version = 1
        }
        let archive = gameDirectory.appendingPathComponent(
            name + [".rgssad", ".rgss2a", ".rgss3a"][version - 1])
        return fm.fileExists(atPath: archive.path) ? archive : nil
    }

    private static func execName(in gameDirectory: URL) -> String {
        ManagedMkxpConfig.loadBaseDict(from: gameDirectory)?["execName"] as? String ?? "Game"
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
