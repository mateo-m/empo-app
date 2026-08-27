import Foundation

/// One step of the permission check of SPEC 8.7. The add sheet of
/// 13.7 shows a tick per step, in this order.
public enum PermissionCheckStep: String, CaseIterable, Equatable, Sendable {
    case write
    case list
    case delete
    case freeSpace

    /// The word the add sheet shows, per 13.7.
    public var label: String {
        switch self {
        case .write: return "write"
        case .list: return "list"
        case .delete: return "delete"
        case .freeSpace: return "free space"
        }
    }
}

/// How one step ended.
public enum PermissionCheckOutcome: Equatable, Sendable {
    case passed
    /// The target does not answer a space query, per 9.7. Only the
    /// free-space step ends this way.
    case skipped
    case failed(BackupProviderError)
    /// A step before it failed, so this one never ran.
    case notRun
}

public struct PermissionCheckStepResult: Equatable, Sendable {
    public let step: PermissionCheckStep
    public let outcome: PermissionCheckOutcome

    public init(step: PermissionCheckStep, outcome: PermissionCheckOutcome) {
        self.step = step
        self.outcome = outcome
    }

    public var label: String { step.label }
}

/// What the check found, as a value the add sheet of 13.7 renders.
public struct PermissionCheckResult: Equatable, Sendable {

    /// The four steps, in the order 13.7 shows them.
    public let steps: [PermissionCheckStepResult]
    /// What the space query answered, where it answered.
    public let quota: QuotaReading?

    public init(steps: [PermissionCheckStepResult], quota: QuotaReading?) {
        self.steps = steps
        self.quota = quota
    }

    /// The first step that failed, which 13.7 names to the user.
    public var failedStep: PermissionCheckStep? {
        steps.first { if case .failed = $0.outcome { return true } else { return false } }?.step
    }

    /// The error the failing step reported. A `rejected` message
    /// reaches the user word for word, per 13.7.
    public var failure: BackupProviderError? {
        for result in steps {
            if case .failed(let error) = result.outcome { return error }
        }
        return nil
    }

    /// Whether the target answers a space query, which sets
    /// `canQueryQuota` for this target, per 8.3 and 9.7.
    public var canQueryQuota: Bool { quota != nil }

    /// Whether Empo can add this target.
    ///
    /// The write, the list, and the delete must pass. A free-space
    /// step that fails or skips does not block the add, because a
    /// target that answers no space query is a supported target: it
    /// discovers its limit from the first upload error, per 9.7.
    public var allowsAdd: Bool {
        for result in steps where result.step != .freeSpace {
            guard result.outcome == .passed else { return false }
        }
        return true
    }
}

/// The permission check of SPEC 8.7.
///
/// It writes a probe file under the fixed root, lists it, deletes
/// it, and reads quota where the target answers. It runs at add time
/// and after a re-sign-in, and never per run. A routine run runs no
/// check, and its first failure is the check itself, reported as one
/// of the error kinds of 8.4.
public enum PermissionCheck {

    /// What the probe file holds. The check deletes it again, and a
    /// leftover from a failed delete says what it is.
    public static let probeContents = Data("empo permission check".utf8)

    /// A probe path under the fixed root.
    ///
    /// The suffix is random so that two devices which check at the
    /// same moment do not delete each other's probe.
    public static func makeProbePath() -> String {
        "Empo/permission-check-\(BackupKeys.randomHex(characters: 8))"
    }

    public static func run(
        on provider: some BackupProvider,
        probePath: String = PermissionCheck.makeProbePath(),
        scratchDirectory: URL
    ) async -> PermissionCheckResult {
        var steps: [PermissionCheckStepResult] = []
        var quota: QuotaReading?

        func skipRest() -> PermissionCheckResult {
            let started = steps.map(\.step)
            for later in PermissionCheckStep.allCases where !started.contains(later) {
                steps.append(PermissionCheckStepResult(step: later, outcome: .notRun))
            }
            return PermissionCheckResult(steps: steps, quota: nil)
        }

        // Step 1: write the probe.
        let probeFile = scratchDirectory.appendingPathComponent("permission-check")
        do {
            try FileManager.default.createDirectory(
                at: scratchDirectory, withIntermediateDirectories: true)
            try probeContents.write(to: probeFile, options: .atomic)
        } catch {
            steps.append(
                PermissionCheckStepResult(
                    step: .write,
                    outcome: .failed(
                        .rejected(message: "this device could not write the probe file"))))
            return skipRest()
        }
        defer { try? FileManager.default.removeItem(at: probeFile) }

        do {
            try await provider.put(localFile: probeFile, path: probePath)
            steps.append(PermissionCheckStepResult(step: .write, outcome: .passed))
        } catch {
            steps.append(PermissionCheckStepResult(step: .write, outcome: .failed(error)))
            return skipRest()
        }

        // Step 2: list it.
        do {
            let objects = try await provider.list(prefix: probePath)
            guard objects.contains(where: { $0.path == probePath }) else {
                steps.append(PermissionCheckStepResult(step: .list, outcome: .failed(.notFound)))
                return skipRest()
            }
            steps.append(PermissionCheckStepResult(step: .list, outcome: .passed))
        } catch {
            steps.append(PermissionCheckStepResult(step: .list, outcome: .failed(error)))
            return skipRest()
        }

        // Step 3: delete it.
        do {
            try await provider.delete(paths: [probePath])
            steps.append(PermissionCheckStepResult(step: .delete, outcome: .passed))
        } catch {
            steps.append(PermissionCheckStepResult(step: .delete, outcome: .failed(error)))
            return skipRest()
        }

        // Step 4: read the free space, where the target answers.
        do {
            if let reading = try await provider.quota() {
                quota = reading
                steps.append(PermissionCheckStepResult(step: .freeSpace, outcome: .passed))
            } else {
                steps.append(PermissionCheckStepResult(step: .freeSpace, outcome: .skipped))
            }
        } catch {
            steps.append(PermissionCheckStepResult(step: .freeSpace, outcome: .failed(error)))
        }

        return PermissionCheckResult(steps: steps, quota: quota)
    }
}
