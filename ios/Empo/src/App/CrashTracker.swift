import Foundation

/// Tracks unclean engine terminations via per-game marker files.
///
/// While a session runs, the marker `<container>/EmpoState/.session-active`
/// is present. On clean exit it's removed. If it's still present
/// on next launch, the previous session died unexpectedly (user
/// force-kill, OOM, C++ crash) - unless the binary was replaced
/// in the meantime (redeploy, TestFlight update, App Store
/// update), in which case the marker belongs to a prior install
/// and is discarded.
///
/// Per-game placement (vs. a single top-level marker) means we
/// also know WHICH game crashed - useful for surfacing context
/// in the recovery alert and for cleaning up only the affected
/// container's transient state.
@MainActor
final class CrashTracker {

    /// True iff a marker from THIS install was found at launch.
    /// Flipped to false once `consumeRecovery()` has run so
    /// repeated checks after handling the alert don't re-trigger.
    private(set) var pendingCrashRecovery: Bool

    init() {
        pendingCrashRecovery = false
        for container in GameContainer.discover() {
            let url = container.sessionActiveMarkerURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if Self.isMarkerFromCurrentInstall(at: url) {
                pendingCrashRecovery = true
                // Don't break - keep scanning so any other stale
                // markers from current install also get noticed
                // (rare; only happens if multiple games are
                // somehow active at once, which the rest of the
                // app structurally prevents).
            } else {
                // Stale marker from a previous install. The
                // session it recorded can't have been in this
                // binary, so treat as already resolved and clean
                // up. Avoids a spurious "didn't exit cleanly"
                // alert on first launch after a redeploy.
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Marks the pending recovery as handled. Call once the UI has
    /// surfaced the alert so subsequent reads see false.
    func consumeRecovery() {
        pendingCrashRecovery = false
    }

    func writeMarker(for container: GameContainer) {
        container.ensureEmpoStateDirectory()
        FileManager.default.createFile(
            atPath: container.sessionActiveMarkerURL.path,
            contents: nil
        )
    }

    func removeMarker(for container: GameContainer) {
        try? FileManager.default.removeItem(at: container.sessionActiveMarkerURL)
    }

    /// Compare the marker's mtime with the executable's bundle
    /// mtime. The bundle executable is replaced on every install,
    /// so its mtime is a reliable install-time proxy across
    /// simulators, real devices, TestFlight, and App Store
    /// updates.
    private static func isMarkerFromCurrentInstall(at markerURL: URL) -> Bool {
        let fm = FileManager.default
        guard let markerAttrs = try? fm.attributesOfItem(atPath: markerURL.path),
              let markerMtime = markerAttrs[.modificationDate] as? Date else {
            // Couldn't stat the marker - assume current install so
            // this doesn't silently swallow a real crash.
            // Conservative default.
            return true
        }

        guard let execPath = Bundle.main.executablePath,
              let bundleAttrs = try? fm.attributesOfItem(atPath: execPath),
              let bundleMtime = bundleAttrs[.modificationDate] as? Date else {
            return true
        }

        return markerMtime > bundleMtime
    }
}
