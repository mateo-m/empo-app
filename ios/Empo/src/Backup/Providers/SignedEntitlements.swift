// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import MachO

/// The entitlements of the running app, read from its own executable
/// with public calls. `SecTaskCopyValueForEntitlement` gives the same
/// answer, but App Store validation rejects it.
enum SignedEntitlements {

    static func allowCloudKit(in container: String) -> Bool {
        let services = values["com.apple.developer.icloud-services"] as? [String] ?? []
        let containers = values["com.apple.developer.icloud-container-identifiers"] as? [String] ?? []
        return services.contains("CloudKit") && containers.contains(container)
    }

    private static let values: [String: Any] = {
        guard let xml = entitlementsPlist(),
            let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil)
        else { return [:] }
        return plist as? [String: Any] ?? [:]
    }()

    #if targetEnvironment(simulator)
    /// Xcode puts the entitlements of a Simulator build in this
    /// section, and its ad hoc signature has none.
    private static func entitlementsPlist() -> Data? {
        guard let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
            let image = (0..<_dyld_image_count()).first(where: {
                URL(fileURLWithPath: String(cString: _dyld_get_image_name($0)))
                    .resolvingSymlinksInPath().path == path
            }),
            let header = _dyld_get_image_header(image)
        else { return nil }
        var size: UInt = 0
        let start = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
            getsectiondata($0, "__TEXT", "__entitlements", &size)
        }
        return start.map { Data(bytes: $0, count: Int(size)) }
    }
    #else
    /// The entitlements blob of the code signature. The superblob
    /// and its blobs are big-endian, and the Mach-O header is not.
    private static func entitlementsPlist() -> Data? {
        guard let url = Bundle.main.executableURL,
            let file = try? Data(contentsOf: url, options: .alwaysMapped),
            file.count > 32, file.little32(at: 0) == MH_MAGIC_64
        else { return nil }
        var command = 32
        for _ in 0..<file.little32(at: 16) {
            guard command + 16 <= file.count else { return nil }
            if file.little32(at: command) == LC_CODE_SIGNATURE {
                return entitlements(in: file, superblob: Int(file.little32(at: command + 8)))
            }
            command += Int(file.little32(at: command + 4))
        }
        return nil
    }

    private static func entitlements(in file: Data, superblob: Int) -> Data? {
        guard superblob + 12 <= file.count, file.big32(at: superblob) == 0xfade_0cc0 else {
            return nil
        }
        for index in 0..<Int(file.big32(at: superblob + 8)) {
            let entry = superblob + 12 + index * 8
            guard entry + 8 <= file.count else { return nil }
            // Slot 5 holds the XML entitlements.
            guard file.big32(at: entry) == 5 else { continue }
            let blob = superblob + Int(file.big32(at: entry + 4))
            guard blob + 8 <= file.count, file.big32(at: blob) == 0xfade_7171 else { return nil }
            let end = blob + Int(file.big32(at: blob + 4))
            guard end <= file.count else { return nil }
            return file.subdata(in: (blob + 8)..<end)
        }
        return nil
    }
    #endif
}

extension Data {
    fileprivate func little32(at offset: Int) -> UInt32 {
        UInt32(
            littleEndian: subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            })
    }

    fileprivate func big32(at offset: Int) -> UInt32 {
        UInt32(
            bigEndian: subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            })
    }
}
