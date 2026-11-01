// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit

guard let launch = PlayerLaunch.fromProcessArguments() else {
    FileHandle.standardError.write(Data("Empo Player: start it from Empo\n".utf8))
    exit(64)
}

let delegate = MainActor.assumeIsolated { PlayerAppDelegate(launch: launch) }
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
