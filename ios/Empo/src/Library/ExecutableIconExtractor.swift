import Foundation
import UIKit

/// Extracts the embedded icon from a Windows PE executable
/// (`Game.exe` and friends) and returns it as a `UIImage`. Used as
/// the primary artwork source for imported RPG Maker games: the
/// developer-authored `.exe` icon is closer to "official artwork"
/// than the first image under `Graphics/Titles/`, which is usually
/// a title-screen still.
///
/// The parser is intentionally narrow: it only touches the parts
/// of the PE format needed to reach the resource section and the
/// import table. Icons come from `RT_GROUP_ICON` + `RT_ICON`
/// resources, reassembled into a standalone `.ico` blob for
/// `UIImage(data:)`. The import table is consulted so that in
/// games which ship multiple executables (e.g. Pokemon Uranium's
/// `Uranium.exe` + `Patcher.exe`) the one that imports
/// `RGSS*.dll` gets picked and updater / installer binaries are skipped.
///
/// Anything unexpected (bad signatures, truncated data, overflows)
/// returns nil rather than throwing so the caller can fall back to
/// its existing artwork-resolution rules.
enum ExecutableIconExtractor {

    /// Sidecar filename written into a game's `Metadata/` directory
    /// so the library scan picks up the already-decoded PE icon
    /// without re-parsing the `.exe` on every reload. The actual
    /// path is `<container>/Metadata/<sidecarFilename>`; lives
    /// outside `Game/` so the imported game tree stays untouched.
    static let sidecarFilename = GameContainer.exeIconSidecarFilename

    /// Substrings commonly found in bundled helper binaries
    /// (patchers, updaters, installers, launchers, RTP installers).
    /// An `.exe` whose filename contains any of these is treated
    /// as an auxiliary tool and skipped, even when it has an
    /// icon. Match is case-insensitive.
    ///
    /// Not exhaustive but good enough for the RPG Maker ecosystem:
    /// most "main binary vs. side tool" ambiguities come from a
    /// handful of well-known naming patterns (Pokemon Uranium's
    /// `Patcher.exe`, many fan games' `Launcher.exe`, RTP
    /// `Setup.exe`, etc.).
    private static let utilityKeywords: [String] = [
        "patcher", "patch",
        "updater", "update",
        "installer", "install",
        "unins",  // InnoSetup uninstallers (unins000.exe)
        "config", "configure",
        "setup",
        "editor",
        "rtp",
        "dxwebsetup", "vcredist",
    ]

    /// True when `filename` matches a known auxiliary-tool naming
    /// pattern. Used by both the import-time extractor and the
    /// post-reload sidecar writer so their picks stay consistent.
    static func isUtilityExecutable(filename: String) -> Bool {
        let lower = filename.lowercased()
        for keyword in utilityKeywords {
            if lower.contains(keyword) { return true }
        }
        return false
    }

    /// Reads `url` and returns the largest icon found inside, as a
    /// `UIImage`. Returns nil when the file isn't a recognisable
    /// PE executable, has no icon resources, or fails any of the
    /// internal bounds / signature checks. Never throws; never
    /// crashes on malformed input.
    static func extractIcon(fromExecutableAt url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        return PEImage(data: data)?.extractIcon()
    }

    /// Scans `<container>/Game/` for a suitable `.exe`, extracts
    /// its icon, and writes it as a PNG sidecar at
    /// `<container>/Metadata/exe-icon.png`.
    ///
    /// Selection rule:
    ///   1. `Game.exe` (case-insensitive) wins when present.
    ///      That's the RPG Maker default and is unambiguously
    ///      the game binary.
    ///   2. Otherwise, the alphabetically-first `.exe` whose
    ///      filename doesn't match a utility-keyword blocklist
    ///      (`Patcher.exe`, `Launcher.exe`, `unins000.exe`, etc.).
    ///
    /// Import-table inspection isn't used as the gate because
    /// some games (Pokemon Uranium, JoiPlay-patched builds) load
    /// the RGSS runtime dynamically via `LoadLibrary`, which
    /// leaves the PE import table looking indistinguishable from
    /// a generic Win32 app.
    ///
    /// Returns the sidecar path on success, nil when no
    /// qualifying executable has an embedded icon so the caller
    /// falls back to its next artwork source (typically
    /// `Graphics/Titles/`). Swallows errors to fit into the
    /// caller's fall-back chain.
    @discardableResult
    static func writeSidecarIfPossible(in container: GameContainer) -> String? {
        let fm = FileManager.default
        let sidecar = container.exeIconSidecarURL
        if fm.fileExists(atPath: sidecar.path) {
            return sidecar.path
        }

        let gameDir = container.gameURL
        let exeItems =
            gameDir
            .directoryEntries(matchingExtensions: ["exe"], fm: fm)
            .map { $0.lastPathComponent }
        let ordered: [String]
        if let canonical = exeItems.first(where: { $0.lowercased() == "game.exe" }) {
            ordered = [canonical] + exeItems.sorted().filter { $0 != canonical }
        } else {
            ordered = exeItems.sorted()
        }

        for item in ordered {
            // Skip utility binaries unless they ARE Game.exe
            // (defensive - some oddball game names might hit a
            // keyword; Game.exe always qualifies).
            if item.lowercased() != "game.exe", isUtilityExecutable(filename: item) {
                continue
            }

            let exeURL = gameDir.appendingPathComponent(item)
            guard let data = try? Data(contentsOf: exeURL, options: .mappedIfSafe),
                let pe = PEImage(data: data),
                let image = pe.extractIcon(),
                let png = image.pngData()
            else {
                continue
            }

            do {
                container.ensureMetadataDirectory()
                try png.write(to: sidecar)
                return sidecar.path
            } catch {
                NSLog("[ExecutableIconExtractor] Sidecar write failed: %@", "\(error)")
                return nil
            }
        }
        return nil
    }
}

// MARK: - PEImage

/// Minimal PE reader covering just the pieces used here:
///   - section table (so RVAs can be translated to file offsets)
///   - data directories (used for the import table)
///   - resource tree walking (used for icon extraction)
///
/// Every read is bounds-checked; constructor returns nil on any
/// malformed header so the rest of the pipeline can treat the file
/// as "not an icon source" and move on.
struct PEImage {
    private let reader: ByteReader
    private let sections: [Section]
    /// Start offset of the 16-entry data directory inside the
    /// optional header, kept for lazy fetching of individual
    /// directories (import, resource, etc.) without re-parsing
    /// the optional header.
    private let dataDirectoryBase: Int
    private let dataDirectoryCount: Int

    struct Section {
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawOffset: Int
        let rawSize: Int
    }

    /// Offsets + record sizes inside the PE layout used below.
    /// See <https://learn.microsoft.com/en-us/windows/win32/debug/pe-format>.
    private enum Layout {
        static let dosPEPointer: Int = 0x3C
        /// 'PE\0\0' + COFF header (20 bytes).
        static let peSignatureAndCoffHeader: Int = 24
        /// Offsets inside the COFF header.
        /// Layout: Machine(u16), NumberOfSections(u16),
        /// TimeDateStamp(u32), PointerToSymbolTable(u32),
        /// NumberOfSymbols(u32), SizeOfOptionalHeader(u16),
        /// Characteristics(u16).
        static let coffNumberOfSectionsOffset: Int = 2
        static let coffSizeOfOptionalHeaderOffset: Int = 16
        /// Optional-header magic distinguishes PE32 (0x10B, 32-bit
        /// image) from PE32+ (0x20B, 64-bit image). Layout up to
        /// the data directories is identical other than the
        /// 32/64-bit BaseOfCode / ImageBase fields shifting every
        /// following offset by 16 bytes.
        static let optionalHeaderMagic32: UInt16 = 0x10B
        static let optionalHeaderMagic64: UInt16 = 0x20B
        /// Offset inside the optional header where
        /// `NumberOfRvaAndSizes` lives. Comes right before the
        /// data directory array. PE32: 92. PE32+: 108.
        static let optionalNumberOfRvaAndSizesOffset32: Int = 92
        static let optionalNumberOfRvaAndSizesOffset64: Int = 108
        /// IMAGE_DIRECTORY_ENTRY_IMPORT index.
        static let importDirectoryIndex: Int = 1
        /// IMAGE_SECTION_HEADER record size.
        static let sectionHeaderSize: Int = 40
        /// IMAGE_IMPORT_DESCRIPTOR record size.
        static let importDescriptorSize: Int = 20
        /// IMAGE_IMPORT_DESCRIPTOR.Name lives at offset 12.
        static let importDescriptorNameOffset: Int = 12
    }

    init?(data: Data) {
        let reader = ByteReader(data: data)

        // DOS header "MZ" at offset 0.
        guard reader.readUInt16(at: 0) == 0x5A4D else { return nil }
        guard let peOffset = reader.readUInt32(at: Layout.dosPEPointer) else { return nil }
        let peBase = Int(peOffset)

        // PE signature: 'P','E',0,0.
        guard reader.readUInt32(at: peBase) == 0x0000_4550 else { return nil }

        let coffBase = peBase + 4
        guard let numberOfSections = reader.readUInt16(at: coffBase + Layout.coffNumberOfSectionsOffset),
            let sizeOfOptionalHeader = reader.readUInt16(at: coffBase + Layout.coffSizeOfOptionalHeaderOffset)
        else {
            return nil
        }

        let optionalBase = coffBase + 20
        guard let optionalMagic = reader.readUInt16(at: optionalBase) else { return nil }
        let numRvaOffset: Int
        switch optionalMagic {
        case Layout.optionalHeaderMagic32:
            numRvaOffset = Layout.optionalNumberOfRvaAndSizesOffset32
        case Layout.optionalHeaderMagic64:
            numRvaOffset = Layout.optionalNumberOfRvaAndSizesOffset64
        default:
            return nil
        }

        guard let numRva = reader.readUInt32(at: optionalBase + numRvaOffset) else { return nil }
        let dataDirectoryBase = optionalBase + numRvaOffset + 4
        self.dataDirectoryBase = dataDirectoryBase
        self.dataDirectoryCount = Int(numRva)

        let sectionTableBase = peBase + Layout.peSignatureAndCoffHeader + Int(sizeOfOptionalHeader)
        var parsedSections: [Section] = []
        parsedSections.reserveCapacity(Int(numberOfSections))
        for i in 0..<Int(numberOfSections) {
            let base = sectionTableBase + i * Layout.sectionHeaderSize
            guard let virtualSize = reader.readUInt32(at: base + 8),
                let virtualAddress = reader.readUInt32(at: base + 12),
                let sizeOfRawData = reader.readUInt32(at: base + 16),
                let pointerToRawData = reader.readUInt32(at: base + 20)
            else {
                return nil
            }
            parsedSections.append(
                Section(
                    virtualAddress: virtualAddress,
                    virtualSize: virtualSize,
                    rawOffset: Int(pointerToRawData),
                    rawSize: Int(sizeOfRawData)
                ))
        }
        self.sections = parsedSections
        self.reader = reader
    }

    /// Walks each section looking for one whose virtual range
    /// contains `rva`, returning the file offset of that RVA.
    /// Returns nil when no section covers it (defensive - valid
    /// RVAs always lie in exactly one section).
    fileprivate func rvaToFileOffset(_ rva: UInt32) -> Int? {
        for section in sections {
            let start = section.virtualAddress
            // `virtualSize` can be smaller than `rawSize` when a
            // section is padded out to file alignment; the raw
            // bounds are the authoritative cap for "can I read
            // bytes at this RVA" checks.
            let size = UInt32(max(Int(section.virtualSize), section.rawSize))
            if rva >= start && rva < start &+ size {
                let delta = Int(rva - start)
                return section.rawOffset + delta
            }
        }
        return nil
    }

    // MARK: - Imports

    /// Returns true when any of the executable's imported DLL
    /// names starts with "rgss" (case-insensitive) and ends in
    /// ".dll". That matches the real-world RPG Maker runtime
    /// filenames (`RGSS102E.dll`, `RGSS202J.dll`, `RGSS300.dll`,
    /// and any JoiPlay / patched variants that keep the prefix).
    func importsRGSSRuntime() -> Bool {
        for name in importedDLLNames() {
            let lower = name.lowercased()
            if lower.hasPrefix("rgss"), lower.hasSuffix(".dll") {
                return true
            }
        }
        return false
    }

    /// Iterates the import directory and yields each imported DLL
    /// name as a Swift string. Returns an empty array when the
    /// executable has no imports (rare for a real game) or the
    /// import directory is malformed.
    func importedDLLNames() -> [String] {
        guard dataDirectoryCount > Layout.importDirectoryIndex else { return [] }

        let dirBase = dataDirectoryBase + Layout.importDirectoryIndex * 8
        guard let importRVA = reader.readUInt32(at: dirBase),
            let importSize = reader.readUInt32(at: dirBase + 4),
            importRVA != 0, importSize != 0
        else {
            return []
        }
        guard let tableOffset = rvaToFileOffset(importRVA) else { return [] }

        var names: [String] = []
        var cursor = tableOffset
        let end = tableOffset + Int(importSize)

        // IMAGE_IMPORT_DESCRIPTOR array terminated by a zeroed
        // entry. Read the Name RVA, resolve it to a file
        // offset, then read a null-terminated ASCII string.
        while cursor + Layout.importDescriptorSize <= end {
            guard let nameRVA = reader.readUInt32(at: cursor + Layout.importDescriptorNameOffset) else {
                break
            }
            if nameRVA == 0 { break }  // terminator
            if let fileOffset = rvaToFileOffset(nameRVA),
                let name = reader.readNullTerminatedASCII(at: fileOffset)
            {
                names.append(name)
            }
            cursor += Layout.importDescriptorSize
        }
        return names
    }

    // MARK: - Icons

    /// Windows resource type constants consumed here.
    /// <https://learn.microsoft.com/en-us/windows/win32/menurc/resource-types>
    private enum ResourceType: UInt32 {
        case icon = 3
        case groupIcon = 14
    }

    /// Internal layout offsets inside IMAGE_RESOURCE_DIRECTORY
    /// and IMAGE_RESOURCE_DIRECTORY_ENTRY.
    private enum ResourceLayout {
        static let directoryHeaderSize: Int = 16
        static let namedEntryCountOffset: Int = 12
        static let idEntryCountOffset: Int = 14
        static let directoryEntrySize: Int = 8
    }

    func extractIcon() -> UIImage? {
        guard let resourceSection = resourceSectionEntry() else { return nil }
        let sectionStart = resourceSection.rawOffset
        let sectionVA = resourceSection.virtualAddress

        var icons: [UInt32: (data: Data, size: Int)] = [:]
        var groups: [ParsedGroup] = []
        walkResourceDirectory(
            sectionStart: sectionStart,
            sectionVirtualAddress: sectionVA,
            directoryOffset: sectionStart,
            level: 0,
            currentType: nil,
            currentName: nil,
            icons: &icons,
            groups: &groups
        )

        // Pick the largest icon variant we can emit. A
        // variant is only usable when its matching RT_ICON
        // payload is present in the icons dict - some PEs
        // reference variants in GROUP_ICON that the ID subtree
        // never delivers.
        var bestEntry: GroupIconEntry?
        for group in groups {
            for entry in group.entries {
                if icons[entry.iconID] == nil { continue }
                if let current = bestEntry {
                    if entry.effectiveArea > current.effectiveArea {
                        bestEntry = entry
                    }
                } else {
                    bestEntry = entry
                }
            }
        }
        guard let best = bestEntry, icons[best.iconID] != nil else { return nil }

        // Payload can be a raw DIB (BITMAPINFOHEADER + pixel data
        // + optional mask) or a PNG starting with the PNG
        // signature (Vista+ uses this for 256x256 entries). The
        // .ico container works for both.
        let icoBlob = buildICO(entries: [best], icons: icons)
        return UIImage(data: icoBlob)
    }

    /// Finds the named `.rsrc` section by parsing section names
    /// (rather than reading the resource entry in the data
    /// directory) since some PEs list `.rsrc` under a different
    /// directory order. Returns the section metadata so the
    /// resource walker can translate RVAs to file offsets.
    private func resourceSectionEntry() -> Section? {
        let reader = self.reader
        guard let peOffset = reader.readUInt32(at: Layout.dosPEPointer) else { return nil }
        let peBase = Int(peOffset)
        let coffBase = peBase + 4
        guard let numberOfSections = reader.readUInt16(at: coffBase + Layout.coffNumberOfSectionsOffset),
            let sizeOfOptionalHeader = reader.readUInt16(at: coffBase + Layout.coffSizeOfOptionalHeaderOffset)
        else {
            return nil
        }
        let sectionTableBase = peBase + Layout.peSignatureAndCoffHeader + Int(sizeOfOptionalHeader)
        for i in 0..<Int(numberOfSections) {
            let base = sectionTableBase + i * Layout.sectionHeaderSize
            guard let nameBytes = reader.readBytes(at: base, length: 8) else { continue }
            let name =
                String(bytes: nameBytes, encoding: .ascii)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            if name == ".rsrc" {
                return sections[i]
            }
        }
        return nil
    }

    private func walkResourceDirectory(
        sectionStart: Int,
        sectionVirtualAddress: UInt32,
        directoryOffset: Int,
        level: Int,
        currentType: UInt32?,
        currentName: UInt32?,
        icons: inout [UInt32: (data: Data, size: Int)],
        groups: inout [ParsedGroup]
    ) {
        guard let namedCount = reader.readUInt16(at: directoryOffset + ResourceLayout.namedEntryCountOffset),
            let idCount = reader.readUInt16(at: directoryOffset + ResourceLayout.idEntryCountOffset)
        else {
            return
        }
        let totalEntries = Int(namedCount) + Int(idCount)
        let entriesBase = directoryOffset + ResourceLayout.directoryHeaderSize

        for i in 0..<totalEntries {
            let entryOffset = entriesBase + i * ResourceLayout.directoryEntrySize
            guard let nameOrId = reader.readUInt32(at: entryOffset),
                let offsetToData = reader.readUInt32(at: entryOffset + 4)
            else {
                continue
            }

            // Level-0 entries are resource types. Skip everything
            // that isn't an icon type so the walk doesn't recurse into
            // version info / strings / manifests.
            if level == 0 {
                if nameOrId & 0x8000_0000 != 0 { continue }
                guard nameOrId == ResourceType.icon.rawValue || nameOrId == ResourceType.groupIcon.rawValue
                else {
                    continue
                }
            }

            let isDirectory = (offsetToData & 0x8000_0000) != 0
            let subOffset = Int(offsetToData & 0x7FFF_FFFF)

            if isDirectory {
                let nextType = (level == 0) ? nameOrId : currentType
                let nextName = (level == 1) ? nameOrId : currentName
                walkResourceDirectory(
                    sectionStart: sectionStart,
                    sectionVirtualAddress: sectionVirtualAddress,
                    directoryOffset: sectionStart + subOffset,
                    level: level + 1,
                    currentType: nextType,
                    currentName: nextName,
                    icons: &icons,
                    groups: &groups
                )
            } else {
                guard let type = currentType,
                    let resourceName = currentName
                else {
                    continue
                }
                processDataEntry(
                    dataEntryOffset: sectionStart + subOffset,
                    sectionStart: sectionStart,
                    sectionVirtualAddress: sectionVirtualAddress,
                    type: type,
                    resourceName: resourceName,
                    icons: &icons,
                    groups: &groups
                )
            }
        }
    }

    private func processDataEntry(
        dataEntryOffset: Int,
        sectionStart: Int,
        sectionVirtualAddress: UInt32,
        type: UInt32,
        resourceName: UInt32,
        icons: inout [UInt32: (data: Data, size: Int)],
        groups: inout [ParsedGroup]
    ) {
        guard let payloadRVA = reader.readUInt32(at: dataEntryOffset),
            let payloadSize = reader.readUInt32(at: dataEntryOffset + 4)
        else {
            return
        }
        let payloadOffset = sectionStart + Int(payloadRVA) - Int(sectionVirtualAddress)
        guard let payload = reader.readBytes(at: payloadOffset, length: Int(payloadSize)) else {
            return
        }
        switch type {
        case ResourceType.icon.rawValue:
            icons[resourceName] = (Data(payload), Int(payloadSize))
        case ResourceType.groupIcon.rawValue:
            if let parsed = parseGroupIcon(Data(payload)) {
                groups.append(parsed)
            }
        default:
            break
        }
    }

    // MARK: - GROUP_ICON parsing + ICO reassembly

    private struct ParsedGroup {
        let entries: [GroupIconEntry]
    }

    private struct GroupIconEntry {
        let rawWidth: UInt8
        let rawHeight: UInt8
        let colorCount: UInt8
        let planes: UInt16
        let bitCount: UInt16
        let bytesInRes: UInt32
        let iconID: UInt32

        /// Effective pixel area with the 0==256 promotion applied
        /// so true-colour 256x256 icons (width/height stored as 0)
        /// beat smaller variants in the "bigger is better"
        /// comparison.
        var effectiveArea: Int {
            let w = rawWidth == 0 ? 256 : Int(rawWidth)
            let h = rawHeight == 0 ? 256 : Int(rawHeight)
            return w * h
        }
    }

    private func parseGroupIcon(_ data: Data) -> ParsedGroup? {
        guard data.count >= 6 else { return nil }
        let reader = ByteReader(data: data)
        guard reader.readUInt16(at: 2) == 1 else { return nil }
        guard let count = reader.readUInt16(at: 4) else { return nil }

        var entries: [GroupIconEntry] = []
        entries.reserveCapacity(Int(count))

        for i in 0..<Int(count) {
            let base = 6 + i * 14
            guard let rawWidth = reader.readUInt8(at: base),
                let rawHeight = reader.readUInt8(at: base + 1),
                let colorCount = reader.readUInt8(at: base + 2),
                let planes = reader.readUInt16(at: base + 4),
                let bitCount = reader.readUInt16(at: base + 6),
                let bytesInRes = reader.readUInt32(at: base + 8),
                let iconID = reader.readUInt16(at: base + 12)
            else {
                return nil
            }
            entries.append(
                GroupIconEntry(
                    rawWidth: rawWidth,
                    rawHeight: rawHeight,
                    colorCount: colorCount,
                    planes: planes,
                    bitCount: bitCount,
                    bytesInRes: bytesInRes,
                    iconID: UInt32(iconID)
                ))
        }
        return ParsedGroup(entries: entries)
    }

    private func buildICO(
        entries: [GroupIconEntry],
        icons: [UInt32: (data: Data, size: Int)]
    ) -> Data {
        var output = Data()
        // ICONDIR: reserved (u16=0), type (u16=1 icon), count.
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(1))
        output.appendLE(UInt16(entries.count))

        var runningOffset = 6 + 16 * entries.count
        for entry in entries {
            guard let icon = icons[entry.iconID] else { continue }
            output.append(entry.rawWidth)
            output.append(entry.rawHeight)
            output.append(entry.colorCount)
            output.append(0)
            output.appendLE(entry.planes)
            output.appendLE(entry.bitCount)
            output.appendLE(UInt32(icon.size))
            output.appendLE(UInt32(runningOffset))
            runningOffset += icon.size
        }

        for entry in entries {
            if let icon = icons[entry.iconID] {
                output.append(icon.data)
            }
        }
        return output
    }
}

// MARK: - ByteReader

/// Bounds-checked reader over an arbitrary `Data` buffer. Every
/// read returns an optional so one malformed PE doesn't surface
/// as a crash; callers translate failures into the same nil result
/// as "no icon found".
private struct ByteReader {
    let data: Data

    func readUInt8(at offset: Int) -> UInt8? {
        guard offset >= 0, offset + 1 <= data.count else { return nil }
        return data[data.startIndex + offset]
    }

    func readUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let lo = UInt16(data[data.startIndex + offset])
        let hi = UInt16(data[data.startIndex + offset + 1])
        return lo | (hi << 8)
    }

    func readUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        var result: UInt32 = 0
        for i in 0..<4 {
            result |= UInt32(data[data.startIndex + offset + i]) << (8 * i)
        }
        return result
    }

    func readBytes(at offset: Int, length: Int) -> Data.SubSequence? {
        guard offset >= 0, length >= 0 else { return nil }
        let end = offset + length
        guard end <= data.count else { return nil }
        return data[(data.startIndex + offset)..<(data.startIndex + end)]
    }

    /// Reads a null-terminated ASCII string starting at `offset`,
    /// capped at a reasonable length so a malformed PE without a
    /// terminator doesn't scan to EOF. DLL names in PE imports
    /// comfortably fit in 256 chars (MS_MAX_PATH territory).
    func readNullTerminatedASCII(at offset: Int, maxLength: Int = 256) -> String? {
        guard offset >= 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(maxLength, 64))
        for i in 0..<maxLength {
            let pos = offset + i
            guard pos < data.count else { break }
            let byte = data[data.startIndex + pos]
            if byte == 0 { break }
            bytes.append(byte)
        }
        return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .ascii)
    }
}

extension Data {
    /// Little-endian append for the two primitive integer widths
    /// used in the ICO format. PE is always little-endian on
    /// x86/x64, and .ico matches.
    fileprivate mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    fileprivate mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
