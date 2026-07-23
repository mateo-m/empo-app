import Foundation

/// Tracks unclean engine terminations via per-game marker files.
///
/// While a session runs, the marker `<container>/EmpoState/.session-active`
/// is present. A clean exit removes it. If it is still present on
/// the next launch, the previous session died unexpectedly (user
/// force-kill, OOM, C++ crash). Exception: when an update replaced
/// the binary in the meantime (redeploy, TestFlight, App Store),
/// the marker belongs to a prior install, and we discard it.
///
/// Per-game placement (vs. a single top-level marker) means we
/// also know WHICH game crashed. That gives context for the
/// recovery alert, and it lets us clean up only the affected
/// container's transient state.
@MainActor
final class CrashTracker {

    /// True iff launch found a marker from THIS install.
    /// Becomes false once `consumeRecovery()` has run, so repeated
    /// checks after we handle the alert do not re-trigger.
    private(set) var pendingCrashRecovery: Bool

    init() {
        pendingCrashRecovery = false
        for container in GameContainer.discover() {
            let url = container.sessionActiveMarkerURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if Self.isMarkerFromCurrentInstall(at: url) {
                pendingCrashRecovery = true
                // Do not break. Keep the scan, so we also notice
                // any other stale markers from the current install.
                // This is rare: it only occurs when multiple games
                // are somehow active at once, which the rest of the
                // app structurally prevents.
            } else {
                // A stale marker from a previous install. The
                // session it recorded cannot have run in this
                // binary, so treat it as resolved and clean up.
                // This avoids a spurious "did not exit cleanly"
                // alert on the first launch after a redeploy.
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Marks the pending recovery as handled. Call it once the UI
    /// has shown the alert, so subsequent reads see false.
    ///
    /// It also deletes every current-install marker on disk, so the
    /// next launch does not trigger the same alert again. Without
    /// this step, a force-quit after the alert would show the alert
    /// again on every later launch. The marker outlives the
    /// in-memory flag because no clean game exit ran to remove it.
    func consumeRecovery() {
        pendingCrashRecovery = false
        let fm = FileManager.default
        for container in GameContainer.discover() {
            let url = container.sessionActiveMarkerURL
            guard fm.fileExists(atPath: url.path) else { continue }
            if Self.isMarkerFromCurrentInstall(at: url) {
                try? fm.removeItem(at: url)
            }
        }
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
    /// mtime. Every install replaces the bundle executable, so its
    /// mtime is a reliable install-time proxy across simulators,
    /// real devices, TestFlight, and App Store updates.
    private static func isMarkerFromCurrentInstall(at markerURL: URL) -> Bool {
        let fm = FileManager.default
        guard let markerAttrs = try? fm.attributesOfItem(atPath: markerURL.path),
            let markerMtime = markerAttrs[.modificationDate] as? Date
        else {
            // We could not stat the marker. Assume the current
            // install, so we do not silently swallow a real crash.
            // Conservative default.
            return true
        }

        guard let execPath = Bundle.main.executablePath,
            let bundleAttrs = try? fm.attributesOfItem(atPath: execPath),
            let bundleMtime = bundleAttrs[.modificationDate] as? Date
        else {
            return true
        }

        return markerMtime > bundleMtime
    }
}
