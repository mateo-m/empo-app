import Foundation

/// The writer questions of SPEC 5.12 that wait for an answer, the
/// answers no run has used yet, and the split line of 7.11.
public struct WriterConflicts: Codable, Equatable, Sendable {

    public static let fileName = "writer-conflicts.json"
    public static let currentVersion = 1

    public enum Answer: Codable, Equatable, Sendable {
        case split(namespaceId: String)
        case takeOver

        private enum CodingKeys: String, CodingKey {
            case resolution, splitNamespaceId
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(WriterClaimResolution.self, forKey: .resolution) {
            case .split:
                let namespaceId = try container.decodeIfPresent(
                    String.self, forKey: .splitNamespaceId)
                self = .split(namespaceId: namespaceId ?? BackupKeys.makeNamespaceId())
            case .takeOver:
                self = .takeOver
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .split(let namespaceId):
                try container.encode(WriterClaimResolution.split, forKey: .resolution)
                try container.encode(namespaceId, forKey: .splitNamespaceId)
            case .takeOver:
                try container.encode(WriterClaimResolution.takeOver, forKey: .resolution)
            }
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
        switch resolution {
        case .split: answers[targetId] = .split(namespaceId: BackupKeys.makeNamespaceId())
        case .takeOver: answers[targetId] = .takeOver
        }
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

    public static func read(applicationSupport: URL) throws -> WriterConflicts {
        guard let data = try SettingsFile.data(at: applicationSupport.appendingPathComponent(fileName))
        else { return WriterConflicts() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(WriterConflicts.self, from: data)
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
        screenText(
            "%@ also backs up to %@. Where should new backups from this device go?", deviceName, targetLabel)
    }

    public static let note =
        screenText("Keep separate starts with a full upload. Both devices keep their history.")

    public static let defaultResolution: WriterClaimResolution = .split

    public static func label(of resolution: WriterClaimResolution) -> String {
        switch resolution {
        case .split: return screenText("Keep separate")
        case .takeOver: return screenText("Take over")
        }
    }

    /// The pill and the stale line while the question waits.
    public static func stopLine(targetLabel: String) -> String {
        screenText("Another device is using %@. Answer on the Backups screen.", targetLabel)
    }
}
