// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let launch: PlayerLaunch
do {
    guard let decoded = try PlayerLaunch.fromProcessArguments() else {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Open games from Empo.")
        alert.runModal()
        exit(0)
    }
    launch = decoded
} catch {
    NSLog("[player] cannot read the launch data: %@", "\(error)")
    exit(64)
}

let core: GameCoreLibrary
do {
    core = try GameCoreLibrary(path: launch.corePath)
} catch {
    NSLog("[player] cannot open %@: %@", launch.corePath, "\(error)")
    exit(70)
}

// The cores print to standard output, which Empo reads for
// PlayerMessage lines. Their output goes to standard error instead.
let messages = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
dup2(STDERR_FILENO, STDOUT_FILENO)
// A write after Empo is gone fails with EPIPE, not with a SIGPIPE that
// ends the game.
_ = fcntl(messages.fileDescriptor, F_SETNOSIGPIPE, 1)

let delegate = MainActor.assumeIsolated { PlayerAppDelegate(launch: launch, core: core, messages: messages) }
app.delegate = delegate
app.run()
