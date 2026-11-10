// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit

if let index = CommandLine.arguments.firstIndex(of: PlayerLaunch.checkCoreArgument),
    index + 1 < CommandLine.arguments.count
{
    if let error = EmpoCoreOpen(CommandLine.arguments[index + 1]) {
        NSLog("[player] %s", error)
        exit(70)
    }
    exit(0)
}

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

if let error = EmpoCoreOpen(launch.corePath) {
    let reason = String(cString: error)
    NSLog("[player] %@", reason)
    // The core opens the debug log, so it cannot write this error there.
    if let path = launch.debugLogPath, let file = fopen(path, "a") {
        fputs("[player] \(reason)\n", file)
        fclose(file)
    }
    exit(70)
}

// The cores print to standard output, which Empo reads for
// PlayerMessage lines. Their output goes to standard error instead.
let messages = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
dup2(STDERR_FILENO, STDOUT_FILENO)
// A write after Empo is gone fails with EPIPE, not with a SIGPIPE that
// ends the game.
_ = fcntl(messages.fileDescriptor, F_SETNOSIGPIPE, 1)

// Empo writes settings changes to standard input. The cores read
// /dev/null there.
let liveChanges = FileHandle(fileDescriptor: dup(STDIN_FILENO), closeOnDealloc: true)
let devNull = open("/dev/null", O_RDONLY)
dup2(devNull, STDIN_FILENO)
close(devNull)

let delegate = MainActor.assumeIsolated {
    PlayerAppDelegate(launch: launch, messages: messages, liveChanges: liveChanges)
}
app.delegate = delegate
app.run()
