// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// Little-endian reads with bounds checks. Every read past the end
/// throws `damaged`, because a cut-off download ends early.
struct InnoByteReader {
    let data: Data
    var position: Int

    init(_ data: Data, at position: Int = 0) {
        self.data = data
        self.position = position
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, position >= 0, position <= data.count, count <= data.count - position else {
            throw InnoSetupArchive.Failure.damaged
        }
        let start = data.startIndex + position
        position += count
        return data[start..<start + count]
    }

    mutating func skip(_ count: Int) throws {
        _ = try bytes(count)
    }

    mutating func u8() throws -> UInt8 {
        let byte = try bytes(1)
        return byte[byte.startIndex]
    }

    mutating func u16() throws -> UInt16 {
        try integer(UInt16.self)
    }

    mutating func u32() throws -> UInt32 {
        try integer(UInt32.self)
    }

    mutating func u64() throws -> UInt64 {
        try integer(UInt64.self)
    }

    /// A u32 length, then that many bytes.
    mutating func string() throws -> Data {
        try bytes(Int(try u32()))
    }

    mutating func skipStrings(_ count: Int) throws {
        for _ in 0..<count { _ = try string() }
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let raw = try bytes(MemoryLayout<T>.size)
        return T(littleEndian: raw.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
    }
}
