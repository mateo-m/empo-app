// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import Observation

@MainActor @Observable
final class MacUpdates {
    static let shared = MacUpdates()

    private(set) var status: UpdateChecker.Status = .unknown
    private var launchCheck: Task<Void, Never>?
    private var isCheckingNow = false

    func checkIfStale() {
        guard UpdateChecker.isSideloadBuild else { return }
        launchCheck = Task {
            status = .checking
            status = await UpdateChecker.checkIfStale()
        }
    }

    /// Shows the result in an alert, also when there is no update.
    func checkNow() async {
        guard !isCheckingNow else { return }
        isCheckingNow = true
        defer { isCheckingNow = false }
        await launchCheck?.value
        status = .checking
        status = await UpdateChecker.checkNow()

        let alert = NSAlert()
        switch status {
        case .available(let latestVersion, let releaseURL):
            alert.messageText = String(localized: "Update available: v\(latestVersion)")
            alert.addButton(withTitle: String(localized: "Update"))
            alert.addButton(withTitle: String(localized: "Not now"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(releaseURL)
            }
            return
        case .upToDate:
            alert.messageText = String(localized: "Up to date")
            alert.informativeText = String(localized: "You have the newest version of Empo.")
        case .failed(let message):
            alert.messageText = message
        case .unknown, .checking:
            return
        }
        alert.runModal()
    }
}
