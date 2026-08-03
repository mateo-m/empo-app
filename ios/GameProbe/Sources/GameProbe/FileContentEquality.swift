import Foundation

/// Byte equality for two files, with a cheap size check first.
///
/// The drain-style merges (`LegacyDataDrain`, the update merge's
/// save protection) use this to DROP a colliding file that is
/// byte-identical to the one already at the canonical name,
/// instead of archiving a pointless duplicate. Without it, every
/// delete-then-reimport cycle stacks another
/// `.empo-displaced.bak` layer onto files that never changed.
///
/// Any read error answers false: the merge then falls back to
/// displacement, which never loses data.
enum FileContentEquality {

    static func identical(_ first: URL, _ second: URL, fm: FileManager = .default) -> Bool {
        guard let firstSize = fileSize(first, fm: fm),
            let secondSize = fileSize(second, fm: fm),
            firstSize == secondSize
        else { return false }

        guard let firstHandle = try? FileHandle(forReadingFrom: first) else { return false }
        defer { try? firstHandle.close() }
        guard let secondHandle = try? FileHandle(forReadingFrom: second) else { return false }
        defer { try? secondHandle.close() }

        // Reads stop exactly at the known size - `read(upToCount:)`
        // may answer nil at EOF, which must not read as an error.
        let chunkSize = 128 * 1024
        var remaining = firstSize
        while remaining > 0 {
            guard
                let firstChunk = try? firstHandle.read(
                    upToCount: Int(min(remaining, UInt64(chunkSize)))),
                !firstChunk.isEmpty,
                let secondChunk = try? secondHandle.read(upToCount: firstChunk.count),
                firstChunk == secondChunk
            else { return false }
            remaining -= UInt64(firstChunk.count)
        }
        return true
    }

    private static func fileSize(_ url: URL, fm: FileManager) -> UInt64? {
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        guard (attributes?[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return attributes?[.size] as? UInt64
    }
}
