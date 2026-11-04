// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import OSLog

/// os_signpost instrumentation for the import pipeline. View in
/// Instruments ("os_signpost" instrument, subsystem sh.mateo.empo,
/// category Import) or via `log stream --signpost`.
enum ImportSignpost {
    static let log = OSLog(subsystem: "sh.mateo.empo", category: "Import")

    /// Wraps `body` in a signpost interval named `name`.
    /// `id` groups intervals belonging to one import (use importID).
    static func interval<T>(
        _ name: StaticString,
        id: String,
        _ body: () throws -> T
    ) rethrows -> T {
        let spid = OSSignpostID(log: log, object: NSString(string: id))
        os_signpost(.begin, log: log, name: name, signpostID: spid, "%{public}s", id)
        defer { os_signpost(.end, log: log, name: name, signpostID: spid) }
        return try body()
    }
}
