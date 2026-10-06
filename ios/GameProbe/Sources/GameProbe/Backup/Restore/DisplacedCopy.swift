import Foundation

/// The displaced copy of SPEC 11.1 and 11.12, as names.
///
/// The rule is one line: the snapshot wins the name, and nothing is
/// deleted. A restored file takes the real name, and the local file
/// moves aside under a marked name. Restore inverts the precedence of
/// the shared-data drain on purpose. The drain lets the newer mtime
/// win, and a three-month-old snapshot restored on purpose must not
/// lose to a newer local mtime.
///
/// Two shapes carry the marker of 3.2:
///
/// - A file becomes `<name>.empo-displaced.bak`.
/// - A replaced tree becomes `<name>.empo-displaced`.
///
/// Both number on a repeat, and both stay out of the backup set by
/// name, because `BackupSetRules.carriesDisplacedMarker` reads the
/// marker inside any component.
public enum DisplacedCopy {

    /// The extension a displaced file takes. A replaced tree takes
    /// none.
    public static let fileSuffix = ".bak"

    /// How many copies of one file Empo accepts before it warns, per
    /// 11.12.
    public static let copyWarningCount = 3

    // MARK: - Names

    /// The name a displaced file takes. `number` counts from 1.
    public static func fileName(for name: String, number: Int = 1) -> String {
        marked(name, number: number) + fileSuffix
    }

    /// The name a replaced tree takes. `number` counts from 1.
    public static func treeName(for name: String, number: Int = 1) -> String {
        marked(name, number: number)
    }

    /// The first free displaced name for a file, given the names the
    /// directory already holds.
    public static func nextFileName(for name: String, taken: Set<String>) -> String {
        next(name, taken: taken, build: fileName(for:number:))
    }

    /// The first free displaced name for a replaced tree.
    public static func nextTreeName(for name: String, taken: Set<String>) -> String {
        next(name, taken: taken, build: treeName(for:number:))
    }

    private static func next(
        _ name: String, taken: Set<String>, build: (String, Int) -> String
    ) -> String {
        var number = 1
        while taken.contains(build(name, number)) {
            number += 1
        }
        return build(name, number)
    }

    private static func marked(_ name: String, number: Int) -> String {
        let mark = "." + BackupSetRules.displacedMarker
        return number <= 1 ? name + mark : name + mark + "-\(number)"
    }

    // MARK: - Reading a name back

    /// Whether a name is a displaced copy of something.
    public static func isDisplaced(_ name: String) -> Bool {
        originalName(ofDisplaced: name) != nil
    }

    /// The name the copy was displaced from, or `nil` when the name
    /// is not a displaced copy.
    public static func originalName(ofDisplaced name: String) -> String? {
        var rest = Substring(name)
        if rest.hasSuffix(fileSuffix) {
            rest = rest.dropLast(fileSuffix.count)
        }
        let mark = "." + BackupSetRules.displacedMarker
        guard let range = rest.range(of: mark, options: .backwards) else { return nil }

        // What follows the marker is either nothing or the number of
        // a repeat. Anything else is a file that only looks like one
        // of ours.
        let tail = rest[range.upperBound...]
        if !tail.isEmpty {
            guard tail.hasPrefix("-"), Int(tail.dropFirst()) != nil else { return nil }
        }
        let original = rest[..<range.lowerBound]
        return original.isEmpty ? nil : String(original)
    }

    // MARK: - The warning of 11.12

    /// How many displaced copies of one file the names hold.
    public static func copyCount(of name: String, among names: [String]) -> Int {
        names.filter { originalName(ofDisplaced: $0) == name }.count
    }

    /// Whether Empo warns about the copies of one file, per 11.12.
    ///
    /// Dropping the oldest copy by itself would be a silent delete of
    /// user data, so the count only warns. Nothing here deletes.
    public static func warnsAboutCopies(_ count: Int) -> Bool {
        count > copyWarningCount
    }

    /// The line the warning carries.
    public static let copyWarningLine =
        "This file now has more than \(copyWarningCount) copies from earlier restores."
}
