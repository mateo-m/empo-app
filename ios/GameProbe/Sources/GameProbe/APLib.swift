import Foundation

/// aPLib decompression (Jørgen Ibsen's LZ format). Enigma Virtual Box
/// uses it for each chunk of a compressed entry.
enum APLib {

    enum Error: Swift.Error {
        case truncated
        case badBackReference
    }

    static func decompress(_ input: Data) throws -> Data {
        var packed = input
        if packed.count >= 24, packed.prefix(4) == Data("AP32".utf8) {
            let headerSize = Int(packed.le32(at: 4))
            let packedSize = Int(packed.le32(at: 8))
            guard headerSize + packedSize <= packed.count else { throw Error.truncated }
            packed = packed.subdata(in: headerSize..<(headerSize + packedSize))
        }
        var state = State(source: [UInt8](packed))
        return Data(try state.depack())
    }

    private struct State {
        let source: [UInt8]
        var position = 0
        var tag: UInt8 = 0
        var bitCount = 0
        var output: [UInt8] = []

        init(source: [UInt8]) {
            self.source = source
            output.reserveCapacity(source.count * 2)
        }

        mutating func byte() throws -> UInt8 {
            guard position < source.count else { throw Error.truncated }
            defer { position += 1 }
            return source[position]
        }

        mutating func bit() throws -> Int {
            if bitCount == 0 {
                tag = try byte()
                bitCount = 8
            }
            bitCount -= 1
            let value = Int(tag >> 7)
            tag <<= 1
            return value
        }

        mutating func gamma() throws -> Int {
            var result = 1
            repeat {
                result = (result << 1) + (try bit())
            } while try bit() == 1
            return result
        }

        mutating func copyBack(offset: Int, length: Int) throws {
            guard offset > 0, offset <= output.count else { throw Error.badBackReference }
            for _ in 0..<length {
                output.append(output[output.count - offset])
            }
        }

        mutating func depack() throws -> [UInt8] {
            output.append(try byte())
            var lastOffset = 0
            var lastWasMatch = false
            while true {
                if try bit() == 0 {
                    output.append(try byte())
                    lastWasMatch = false
                    continue
                }
                if try bit() == 0 {
                    var offset = try gamma()
                    if !lastWasMatch, offset == 2 {
                        let length = try gamma()
                        try copyBack(offset: lastOffset, length: length)
                    } else {
                        offset -= lastWasMatch ? 2 : 3
                        offset = (offset << 8) + Int(try byte())
                        var length = try gamma()
                        if offset >= 32000 { length += 1 }
                        if offset >= 1280 { length += 1 }
                        if offset < 128 { length += 2 }
                        try copyBack(offset: offset, length: length)
                        lastOffset = offset
                    }
                    lastWasMatch = true
                    continue
                }
                if try bit() == 0 {
                    let code = Int(try byte())
                    let length = 2 + (code & 1)
                    let offset = code >> 1
                    if offset == 0 { return output }
                    try copyBack(offset: offset, length: length)
                    lastOffset = offset
                    lastWasMatch = true
                    continue
                }
                var offset = 0
                for _ in 0..<4 {
                    offset = (offset << 1) + (try bit())
                }
                if offset == 0 {
                    output.append(0)
                } else {
                    try copyBack(offset: offset, length: 1)
                }
                lastWasMatch = false
            }
        }
    }
}

extension Data {
    fileprivate func le32(at index: Int) -> UInt32 {
        let base = startIndex + index
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }
}
