// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

extension FileManager {
    /// Moves `target` to `archive`, then `replacement` to `target`.
    /// When the second move fails, `target` moves back, so a file
    /// always has the name `target`.
    func archive(_ target: URL, to archive: URL, replacingWith replacement: URL) throws {
        try moveItem(at: target, to: archive)
        do {
            try moveItem(at: replacement, to: target)
        } catch {
            try? moveItem(at: archive, to: target)
            throw error
        }
    }
}
