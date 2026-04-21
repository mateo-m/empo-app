import Foundation

/// Tracks unclean engine terminations via a marker file in Documents.
///
/// Each game session writes the marker on start and removes it on clean
/// exit. If it's still present on next launch, the previous session died
/// unexpectedly (user force-kill, OOM, C++ crash) — unless the binary was
/// replaced in the meantime (redeploy, TestFlight update, App Store update),
/// in which case the marker belongs to a prior install and is discarded.
@MainActor
final class CrashTracker {
    private static let markerURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(".session-active")

    /// True iff a marker from THIS install was found at launch.
    /// Flipped to false once `consumeRecovery()` has run so repeated
    /// checks after handling the alert don't re-trigger.
    private(set) var pendingCrashRecovery: Bool

    init() {
        if Self.isMarkerFromCurrentInstall() {
            pendingCrashRecovery = true
        } else {
            // Stale marker from a previous install. The session it
            // recorded can't have been in this binary, so treat the
            // crash state as already resolved and clean up. Avoids a
            // spurious "didn't exit cleanly" alert on first launch
            // after a redeploy.
            try? FileManager.default.removeItem(at: Self.markerURL)
            pendingCrashRecovery = false
        }
    }

    /// Marks the pending recovery as handled. Call once the UI has
    /// surfaced the alert so subsequent reads see false.
    func consumeRecovery() {
        pendingCrashRecovery = false
    }

    func writeMarker() {
        FileManager.default.createFile(atPath: Self.markerURL.path, contents: nil)
    }

    func removeMarker() {
        try? FileManager.default.removeItem(at: Self.markerURL)
    }

    /// Compare the marker's mtime with the executable's bundle mtime.
    /// The bundle executable is replaced on every install, so its
    /// mtime is a reliable install-time proxy across simulators, real
    /// devices, TestFlight, and App Store updates.
    private static func isMarkerFromCurrentInstall() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: markerURL.path) else { return false }

        guard let markerAttrs = try? fm.attributesOfItem(atPath: markerURL.path),
              let markerMtime = markerAttrs[.modificationDate] as? Date else {
            // Couldn't stat the marker — assume current install so we
            // don't silently swallow a real crash. Conservative default.
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
