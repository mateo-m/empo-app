import Foundation

/// The writer questions of SPEC 5.12 that wait for an answer, the
/// answers no run has used yet, and the split line of 7.11.
public struct WriterConflicts: Codable, Equatable, Sendable {

    public static let fileName = "writer-conflicts.json"
    public static let currentVersion = 1

    public struct Answer: Codable, Equatable, Sendable {
        public var resolution: WriterClaimResolution
        /// The namespace a split moves to. The screen makes it when
        /// the user answers, so the run and the Keychain agree on it.
        public var splitNamespaceId: String?

        public init(resolution: WriterClaimResolution, splitNamespaceId: String? = nil) {
            self.resolution = resolution
            self.splitNamespaceId = splitNamespaceId
        }
    }

    public var version: Int
    /// The claim another device holds, by target id.
    public var questions: [String: WriterClaim]
    public var answers: [String: Answer]
    /// True after a split, until the user closes the line.
    public var showsTheSplitLine: Bool

    public init(
        version: Int = WriterConflicts.currentVersion,
        questions: [String: WriterClaim] = [:],
        answers: [String: Answer] = [:],
        showsTheSplitLine: Bool = false
    ) {
        self.version = version
        self.questions = questions
        self.answers = answers
        self.showsTheSplitLine = showsTheSplitLine
    }

    public func answer(for targetId: String) -> Answer? {
        answers[targetId]
    }

    public mutating func answer(targetId: String, resolution: WriterClaimResolution) {
        questions.removeValue(forKey: targetId)
        answers[targetId] = Answer(
            resolution: resolution,
            splitNamespaceId: resolution == .split ? BackupKeys.makeNamespaceId() : nil)
    }

    /// A run that met a claim leaves a question. Any other run spends
    /// the answer, because the claim is settled either way.
    public mutating func runEnded(targetId: String, stop: BackupRunStop?, didSplit: Bool) {
        answers.removeValue(forKey: targetId)
        if case .writerConflict(let claim) = stop {
            questions[targetId] = claim
        } else {
            questions.removeValue(forKey: targetId)
        }
        if didSplit { showsTheSplitLine = true }
    }

    public mutating func forget(targetId: String) {
        questions.removeValue(forKey: targetId)
        answers.removeValue(forKey: targetId)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public static func read(applicationSupport: URL) -> WriterConflicts {
        let url = applicationSupport.appendingPathComponent(fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let data = try? Data(contentsOf: url),
            let state = try? decoder.decode(WriterConflicts.self, from: data)
        else { return WriterConflicts() }
        return state
    }

    public func write(applicationSupport: URL) throws {
        try FileManager.default.createDirectory(
            at: applicationSupport, withIntermediateDirectories: true)
        try jsonData().write(
            to: applicationSupport.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// The words of the writer question, per SPEC 5.12.
public enum WriterConflictQuestion {

    public static func line(deviceName: String, targetLabel: String) -> String {
        "\(deviceName) also backs up to \(targetLabel). Where should new backups from this device go?"
    }

    public static let note =
        "Keep separate starts with a full upload. Both devices keep their history."

    public static let defaultResolution: WriterClaimResolution = .split

    public static func label(of resolution: WriterClaimResolution) -> String {
        switch resolution {
        case .split: return "Keep separate"
        case .takeOver: return "Take over"
        }
    }

    /// The pill and the stale line while the question waits.
    public static func stopLine(targetLabel: String) -> String {
        "Another device is using \(targetLabel). Answer on the Backups screen."
    }
}
