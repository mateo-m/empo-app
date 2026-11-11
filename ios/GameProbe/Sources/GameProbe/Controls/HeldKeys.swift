// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// The game keys that the inputs hold, and when the engine sees each
/// press and release.
///
/// Touch buttons, controller elements and keyboard keys all press the
/// same small set of keys, so the engine sees a release only when the
/// last holder lets go. Every event goes through a holder, so the
/// engine sees one press when the first holder arrives and one release
/// when the last holder goes.
@available(iOS 16, macOS 13, *)
@MainActor
public final class HeldKeys<Holder: Hashable> {
    /// Light taps release before the RGSS thread sees the press, so a
    /// release waits until the key was down for at least one frame
    /// (about 16 ms at 60 fps, with headroom).
    public nonisolated static var minimumHold: Duration { .milliseconds(50) }

    /// The hold of one key tap. Heavy scenes read input at well below
    /// 40 fps, and a shorter tap can fall between two reads.
    public nonisolated static var tapHoldMilliseconds: Int { 120 }

    /// A key the engine sees as down. A holder with a release task
    /// still holds the key until the task ends.
    private struct Key {
        let pressedAt: ContinuousClock.Instant
        var holders: Set<Holder>
        var releases: [Holder: Task<Void, Never>] = [:]
    }

    private let send: (Int32, Bool) -> Void
    private var keys: [Int32: Key] = [:]

    /// `send` gives one key event to the engine: the scancode, and true
    /// for a press.
    public init(send: @escaping (Int32, Bool) -> Void) {
        self.send = send
    }

    /// The engine sees a press when the first holder arrives. A holder
    /// that holds again cancels its own release that waits.
    public func hold(_ scancode: Int32, by holder: Holder) {
        guard var key = keys[scancode] else {
            keys[scancode] = Key(pressedAt: .now, holders: [holder])
            send(scancode, true)
            return
        }
        key.holders.insert(holder)
        key.releases.removeValue(forKey: holder)?.cancel()
        keys[scancode] = key
    }

    /// The engine sees a release when the last holder lets go, and not
    /// before the key was down for `minimum`.
    public func release(
        _ scancode: Int32, by holder: Holder, notBefore minimum: Duration = minimumHold
    ) {
        guard var key = keys[scancode], key.holders.contains(holder) else { return }
        key.releases.removeValue(forKey: holder)?.cancel()
        let remaining = minimum - (ContinuousClock.now - key.pressedAt)
        guard remaining > .zero else {
            keys[scancode] = key
            drop(holder, from: scancode)
            return
        }
        key.releases[holder] = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
            self?.drop(holder, from: scancode)
        }
        keys[scancode] = key
    }

    /// Lets go of every key that the matching holders hold.
    public func release(where matches: (Holder) -> Bool) {
        for (scancode, key) in keys {
            for holder in key.holders where matches(holder) {
                release(scancode, by: holder)
            }
        }
    }

    /// Holds the key, then lets go after `holdMilliseconds`.
    public func tap(_ scancode: Int32, holdMilliseconds: Int, by holder: Holder) {
        hold(scancode, by: holder)
        release(scancode, by: holder, notBefore: .milliseconds(holdMilliseconds))
    }

    /// Releases every key at once and forgets every holder. A holder
    /// left behind would make the next session's first press look like
    /// a second one, and the engine would never see it.
    public func clear() {
        let held = keys
        keys.removeAll()
        for (scancode, key) in held {
            for task in key.releases.values {
                task.cancel()
            }
            send(scancode, false)
        }
    }

    private func drop(_ holder: Holder, from scancode: Int32) {
        guard var key = keys[scancode] else { return }
        key.holders.remove(holder)
        key.releases.removeValue(forKey: holder)
        if key.holders.isEmpty {
            keys.removeValue(forKey: scancode)
            send(scancode, false)
        } else {
            keys[scancode] = key
        }
    }
}
