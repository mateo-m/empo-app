// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// The game keys that the inputs hold, and when the engine sees each
/// press and release.
///
/// Touch buttons, controller elements and keyboard keys all press the
/// same small set of keys, so the engine sees a release only when the
/// last holder lets go.
@available(iOS 16, macOS 13, *)
@MainActor
public final class HeldKeys<Holder: Hashable> {
    /// Light taps release before the RGSS thread sees the press, so a
    /// release waits until the key was down for at least one frame
    /// (about 16 ms at 60 fps, with headroom).
    public static var minimumHold: Duration { .milliseconds(50) }

    private let send: (Int32, Bool) -> Void
    private var holders: [Int32: Set<Holder>] = [:]
    private var pressStartedAt: [Int32: ContinuousClock.Instant] = [:]
    private var pendingReleases: [Int32: Task<Void, Never>] = [:]

    /// `send` gives one key event to the engine: the scancode, and true
    /// for a press.
    public init(send: @escaping (Int32, Bool) -> Void) {
        self.send = send
    }

    /// The engine sees a press when the first holder arrives. Holding
    /// twice with the same holder changes nothing.
    public func hold(_ scancode: Int32, by holder: Holder) {
        var keyHolders = holders[scancode] ?? []
        let wasEmpty = keyHolders.isEmpty
        keyHolders.insert(holder)
        holders[scancode] = keyHolders
        if wasEmpty {
            inject(scancode, pressed: true)
        }
    }

    /// The engine sees a release when the last holder lets go.
    public func release(_ scancode: Int32, by holder: Holder) {
        guard var keyHolders = holders[scancode], keyHolders.remove(holder) != nil else { return }
        if keyHolders.isEmpty {
            holders.removeValue(forKey: scancode)
            inject(scancode, pressed: false)
        } else {
            holders[scancode] = keyHolders
        }
    }

    /// Drops every key that the matching holders hold.
    public func release(where matches: (Holder) -> Bool) {
        for (scancode, keyHolders) in holders {
            for holder in keyHolders where matches(holder) {
                release(scancode, by: holder)
            }
        }
    }

    /// Sends a key event with no holder. A release still waits for the
    /// minimum hold.
    public func inject(_ scancode: Int32, pressed: Bool) {
        pendingReleases.removeValue(forKey: scancode)?.cancel()
        if pressed {
            pressStartedAt[scancode] = .now
            send(scancode, true)
            return
        }
        guard let started = pressStartedAt[scancode] else {
            send(scancode, false)
            return
        }
        let held = ContinuousClock.now - started
        if held >= Self.minimumHold {
            pressStartedAt.removeValue(forKey: scancode)
            send(scancode, false)
            return
        }
        pendingReleases[scancode] = Task { @MainActor in
            try? await Task.sleep(for: Self.minimumHold - held)
            guard !Task.isCancelled else { return }
            self.pressStartedAt.removeValue(forKey: scancode)
            self.pendingReleases.removeValue(forKey: scancode)
            self.send(scancode, false)
        }
    }

    public func tap(_ scancode: Int32, holdMilliseconds: Int) {
        inject(scancode, pressed: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(holdMilliseconds))
            inject(scancode, pressed: false)
        }
    }

    /// Releases every key at once and forgets every holder. A holder
    /// left behind would make the next session's first press look like
    /// a second one, and the engine would never see it.
    public func clear() {
        for task in pendingReleases.values {
            task.cancel()
        }
        pendingReleases.removeAll()
        for scancode in pressStartedAt.keys {
            send(scancode, false)
        }
        pressStartedAt.removeAll()
        holders.removeAll()
    }
}
