// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// Throws for a move out of `failMoveFrom` or a removal of
/// `failRemoveAt`. All other calls go to the real file system.
final class FailingFileManager: FileManager {
    var failMoveFrom: URL?
    var failRemoveAt: URL?

    struct Injected: Error {}

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.standardizedFileURL.path == failMoveFrom?.standardizedFileURL.path {
            throw Injected()
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func removeItem(at url: URL) throws {
        if url.standardizedFileURL.path == failRemoveAt?.standardizedFileURL.path {
            throw Injected()
        }
        try super.removeItem(at: url)
    }
}
