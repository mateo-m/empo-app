import Foundation

/// Tells whether the PSDK core can run a folder.
///
/// The core changes directory into the folder and loads `Game.rb`
/// (`src/psdk_core.cpp` in psdk-apple-mobile). In a released PSDK game
/// that file is one line:
///
///     RubyVM::InstructionSequence.load_from_binary(File.binread('Game.yarb')).eval
///
/// So the pair is the identity: a `Game.rb` next to a `Game.yarb` that
/// starts with Ruby's own bytecode magic, `YARB`. A release compiled
/// with `--no-yarb` has no `Game.yarb`. Its `Game.rb` holds the boot
/// scripts as plain Ruby.
public enum PsdkGame {

    /// True when the PSDK core can run `url`.
    ///
    /// The check reads the directory listing and compares exact names.
    /// A device volume is case-sensitive, so a `game.rb` there does not
    /// load. The simulator uses the Mac's volume, which hides that.
    public static func isGameRoot(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: url.path),
            names.contains("Game.rb")
        else { return false }

        guard names.contains("Game.yarb") else { return shipsScriptSource(url) }
        return startsWithYARB(url.appendingPathComponent("Game.yarb"))
    }

    /// True when `url` is a release that PSDK compiled with `--no-yarb`.
    /// Its scripts are plain Ruby, so every PSDK core can run it.
    /// The compile tool writes the `PSDK_VERSION` line into `Game.rb`,
    /// and the boot scripts there read `Data/Scripts.dat`.
    private static func shipsScriptSource(_ url: URL) -> Bool {
        guard let script = try? String(contentsOf: url.appendingPathComponent("Game.rb"), encoding: .utf8)
        else { return false }
        return script.contains("PSDK_VERSION = ") && script.contains("Data/Scripts.dat")
    }

    /// True when `url` is a Pokémon Studio project, the form that the
    /// PSDK Technical Demo ships in. Its `Game.rb` loads the PSDK scripts
    /// from source, from a `pokemonsdk` folder that the project does not
    /// ship. It also holds an RPG Maker XP project, so the RPG Maker XP,
    /// VX and VX Ace core takes it if no core claims it first.
    public static func isStudioProject(_ url: URL) -> Bool {
        guard let script = try? String(contentsOf: url.appendingPathComponent("Game.rb"), encoding: .utf8)
        else { return false }
        return script.contains("/scripts/ScriptLoad.rb")
    }

    /// The Ruby version that compiled the game's `Game.yarb`, such as
    /// "3.0". Ruby loads only bytecode of its own version. Pokémon Studio
    /// compiles with Ruby 3.0 on Windows, 3.2 on a Mac and 3.3 on Linux.
    /// PSDK releases from December 2019 to about March 2021 used Ruby 2.5.
    public static func bytecodeVersion(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url.appendingPathComponent("Game.yarb")),
            let header = try? handle.read(upToCount: 12), header.count == 12,
            header.prefix(4) == Data("YARB".utf8)
        else { return nil }
        try? handle.close()
        // The magic, then the major and the minor version, each a
        // little-endian UInt32.
        return "\(header[4]).\(header[8])"
    }

    private static func startsWithYARB(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("YARB".utf8)
    }
}

extension PsdkGame {

    /// Renames each loose file whose name differs only in case from the
    /// path that the game's scripts use, and returns the new paths.
    ///
    /// A device volume is case-sensitive and Windows is not, so a
    /// released game can ship `Yuki_Transition_Circular.txt` and open
    /// `yuki_transition_circular.txt`. Edelweiss Chronicles does that
    /// for three shader files. `Data/Scripts.dat` is a zlib stream of
    /// the compiled scripts, and each path literal stays in it as plain
    /// text.
    ///
    /// A copy under the second spelling is not possible. On the Mac
    /// volume that the simulator uses, both names are the same file.
    /// `rename(2)` accepts a change of case on both volumes.
    @discardableResult
    public static func matchFileNameCase(in root: URL) -> [String] {
        guard let packed = try? Data(contentsOf: root.appendingPathComponent("Data/Scripts.dat")),
            let scripts = ZlibInflate.inflateSkippingZlibHeader(packed)
        else { return [] }

        var renamed: [String] = []
        for wanted in pathLiterals(in: scripts).sorted() {
            let parts = wanted.split(separator: "/").map(String.init)
            guard let onDisk = spellingOnDisk(of: parts, in: root), onDisk != parts,
                // A folder rename would break the files under it that
                // already open.
                onDisk.dropLast() == parts.dropLast()
            else { continue }
            let from = root.appendingPathComponent(onDisk.joined(separator: "/"))
            if rename(from.path, root.appendingPathComponent(wanted).path) == 0 {
                renamed.append(wanted)
            }
        }
        return renamed
    }

    // The pattern starts at a folder that a game reads loose files
    // from. Each string in the bytecode has a length byte in front, and
    // that byte is often a letter, so a pattern that starts at any name
    // turns graphics/x into Ugraphics/x.
    private static let pathPattern = try! NSRegularExpression(
        pattern: #"(?:graphics|audio|Fonts|plugins|pokemonsdk)(?:/[A-Za-z0-9_.-]+)+\.[a-z]{2,4}(?![A-Za-z0-9_])"#)

    // Latin-1 maps each byte to one character. The pattern matches only
    // printable ASCII, so a match never runs into the binary between two
    // strings.
    private static func pathLiterals(in scripts: Data) -> Set<String> {
        guard let text = String(data: scripts, encoding: .isoLatin1) as NSString? else { return [] }
        let matches = pathPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length))
        return Set(matches.map { text.substring(with: $0.range) })
    }

    /// The names on disk along `parts`, matched without case. Nil when a
    /// part has no match, or more than one.
    private static func spellingOnDisk(of parts: [String], in root: URL) -> [String]? {
        var current = root
        var found: [String] = []
        for want in parts {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: current.path)
            else { return nil }
            let hit: String
            if entries.contains(want) {
                hit = want
            } else {
                let matches = entries.filter { $0.lowercased() == want.lowercased() }
                guard matches.count == 1 else { return nil }
                hit = matches[0]
            }
            found.append(hit)
            current.appendPathComponent(hit)
        }
        return found
    }
}
