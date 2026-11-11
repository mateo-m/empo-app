// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

/// Why Empo did not use a controls file.
public enum ControlsRejection: Equatable, Sendable {
    case newerVersion
    case errors(count: Int)
}

extension ControlsManifestLoader.Result {
    public var rejection: ControlsRejection? {
        if ignoredNewerVersion { return .newerVersion }
        guard manifest == nil else { return nil }
        let count = findings.filter { $0.severity == .error }.count
        return count > 0 ? .errors(count: count) : nil
    }
}

extension LayoutProfileStore.ProfileRead {
    public var rejection: ControlsRejection? {
        if ignoredNewerVersion { return .newerVersion }
        guard touch == nil else { return nil }
        return .errors(count: max(errors.count, 1))
    }
}
