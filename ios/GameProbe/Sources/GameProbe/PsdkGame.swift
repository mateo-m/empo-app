import Foundation

/// Tells whether the PSDK core can run a folder.
///
/// The core changes directory into the folder and loads `Game.rb`
/// (`ios/Dependencies/psdk/psdk_core.cpp`). In a released PSDK game
/// that file is one line:
///
///     RubyVM::InstructionSequence.load_from_binary(File.binread('Game.yarb')).eval
///
/// So the pair is the identity: a `Game.rb` next to a `Game.yarb` that
/// starts with Ruby's own bytecode magic, `YARB`.
public enum PsdkGame {

    /// True when the PSDK core can run `url`.
    ///
    /// The check reads the directory listing and compares exact names.
    /// A device volume is case-sensitive, so a `game.rb` there does not
    /// load. The simulator uses the Mac's volume, which hides that.
    public static func isGameRoot(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: url.path),
            names.contains("Game.rb"), names.contains("Game.yarb")
        else { return false }

        return startsWithYARB(url.appendingPathComponent("Game.yarb"))
    }

    // ponytail: a PSDK game that ships plain Ruby instead of Game.yarb
    // reads as "not PSDK". Its scripts still sit in Data/Scripts.dat as
    // a zlib stream over a Marshal array of YARB blobs, so the upgrade
    // is ZlibInflate on the first chunk of that file. No released game
    // seen so far ships one.
    private static func startsWithYARB(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("YARB".utf8)
    }
}
