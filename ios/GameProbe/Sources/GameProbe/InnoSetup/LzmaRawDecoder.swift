// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import CLzma
import Foundation

/// Decodes an LZMA1 stream that starts with the 5 property bytes and
/// has no size field. Inno Setup writes its streams without an end
/// mark, so the stream ends where its input ends.
final class LzmaRawDecoder {
    private static var allocator: ISzAlloc {
        ISzAlloc(Alloc: { _, size in malloc(size) }, Free: { _, address in free(address) })
    }

    private let state: UnsafeMutablePointer<CLzmaDec>
    private var input: Data
    private var inputPosition: Int

    /// Inno Setup uses at most 64 MiB. A larger value comes from a
    /// damaged or hostile file and would only waste memory.
    static let maximumDictionarySize: UInt32 = 1 << 26

    init(stream: Data) throws {
        var header = InnoByteReader(stream)
        _ = try header.u8()
        guard try header.u32() <= Self.maximumDictionarySize else { throw InnoSetupArchive.Failure.damaged }
        let state = UnsafeMutablePointer<CLzmaDec>.allocate(capacity: 1)
        state.initialize(to: CLzmaDec())
        let properties = [UInt8](stream.prefix(5))
        let result = withUnsafePointer(to: Self.allocator) { allocator in
            LzmaDec_Allocate(state, properties, 5, allocator)
        }
        guard result == SZ_OK else {
            state.deallocate()
            throw InnoSetupArchive.Failure.damaged
        }
        LzmaDec_Init(state)
        self.state = state
        input = stream
        inputPosition = 5
    }

    deinit {
        withUnsafePointer(to: Self.allocator) { LzmaDec_Free(state, $0) }
        state.deallocate()
    }

    /// Fills `output` and returns the count of bytes written. 0 means
    /// that the stream has ended.
    func read(into output: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let outputBase = output.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        var written = 0
        while written < output.count {
            var outLength = output.count - written
            var inLength = input.count - inputPosition
            var status = LZMA_STATUS_NOT_SPECIFIED
            let result = input.withUnsafeBytes { raw -> SRes in
                guard let base = raw.baseAddress else { return SRes(SZ_ERROR_INPUT_EOF) }
                let inputBase = base.assumingMemoryBound(to: UInt8.self) + inputPosition
                return LzmaDec_DecodeToBuf(
                    state, outputBase + written, &outLength, inputBase, &inLength, LZMA_FINISH_ANY, &status)
            }
            guard result == SZ_OK else { throw InnoSetupArchive.Failure.damaged }
            inputPosition += inLength
            written += outLength
            if outLength == 0 && inLength == 0 { break }
            if status == LZMA_STATUS_FINISHED_WITH_MARK { break }
        }
        return written
    }

    /// The whole stream, for the small header blocks. A few bytes can
    /// unpack to gigabytes, so a stream longer than `limit` is damaged.
    func readAll(limit: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try read(into: $0) }
            if count == 0 { return result }
            guard result.count + count <= limit else { throw InnoSetupArchive.Failure.damaged }
            result.append(contentsOf: buffer[0..<count])
        }
    }
}
