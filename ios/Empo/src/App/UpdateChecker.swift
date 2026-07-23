import Foundation

/// Update checker for sideloaded / IPA installs.
///
/// Hits GitHub's Releases API to compare the running build's
/// `CFBundleShortVersionString` against the latest tagged release on
/// the project's repo. It stays hidden on App Store / TestFlight
/// builds because the platform handles updates there.
///
/// **Install-source detection.** Apple stamps a receipt file on App
/// Store and TestFlight installs at `Bundle.main.appStoreReceiptURL`.
/// Sideloaded IPAs (AltStore, Sideloadly, SideStore, ESign, Feather)
/// do not get one because no purchase occurred. We treat the
/// receipt's presence as the App Store / TestFlight signal and absence
/// as "sideloaded or local Xcode build". Local debug builds also have
/// no receipt. They get the banner too, which is fine for dogfooding.
///
/// **Throttle.** A successful check writes a timestamp to
/// UserDefaults. Later launches within `recheckInterval` reuse the
/// last cached result instead of another GitHub hit. GitHub's
/// unauthenticated rate limit is 60 req/hour/IP, and we only fire one
/// request per launch even without the cache. The throttle mainly
/// keeps offline launches from repeated "failed to check" spam.
enum UpdateChecker {

    /// Result of a check, also persisted between launches.
    enum Status: Equatable {
        /// No check ran yet this launch.
        case unknown
        /// A fetch of the latest release is in progress.
        case checking
        /// The build is up to date relative to the latest tag.
        case upToDate(currentVersion: String)
        /// A newer release is available. `releaseURL` opens the
        /// GitHub release page with the IPA attached.
        case available(latestVersion: String, releaseURL: URL)
        /// Network error, JSON parse error, rate limit, or any
        /// other transient failure. Never raises. The UI shows a
        /// retry control.
        case failed(message: String)
    }

    /// True when this build is sideloaded or a dev install (no
    /// App Store or TestFlight receipt). The update banner is
    /// hidden when this is false: the App Store handles those
    /// installs natively.
    static var isSideloadOrDevBuild: Bool {
        guard let receiptURL = Bundle.main.appStoreReceiptURL else {
            // No receipt URL at all: definitely not App Store /
            // TestFlight. Common for non-paid-team builds and for
            // some sideload tools that strip the URL entirely.
            return true
        }
        // The receipt URL is set, but the file does not exist (Apple
        // issues the file only on App Store / TestFlight). On
        // sideload and Xcode debug installs, the URL exists in the
        // bundle layout, but the actual receipt is absent.
        return !FileManager.default.fileExists(atPath: receiptURL.path)
    }

    /// GitHub repo coordinates for the API and release URLs. They
    /// stay hardcoded because the project has a single canonical
    /// home. Move them to Info.plist if a fork ever needs to point
    /// elsewhere.
    private static let owner = "mateo-m"
    private static let repo = "empo-app"

    /// How long to trust a successful "up to date" or "available"
    /// result before a recheck. One hour keeps repeat launches
    /// quiet, and it does not hold stale info long enough to
    /// mislead a user who just released a new build.
    private static let recheckInterval: TimeInterval = 60 * 60

    /// Minimum time the UI should stay in `.checking` before a
    /// result shows. Cached or fast network hits otherwise
    /// flash the spinner for a single frame, which feels broken.
    private static let minimumCheckingDuration: Duration = .milliseconds(500)

    /// UserDefaults keys for the persisted check result. They stay
    /// raw strings (no enum), so older builds can still decode the
    /// payload schema even when a future build adds new fields.
    private enum DefaultsKey {
        static let lastCheckedAt = "UpdateChecker.lastCheckedAt"
        static let lastKnownLatestVersion = "UpdateChecker.lastKnownLatestVersion"
    }

    /// Returns the freshest status without a recheck when a
    /// previous check is still inside `recheckInterval`. `RootView`
    /// calls it once at launch. Use `checkNow()` for a forced
    /// refresh.
    static func checkIfStale() async -> Status {
        await withMinimumCheckingDuration {
            // Hide entirely on App Store / TestFlight.
            guard isSideloadOrDevBuild else {
                return .upToDate(currentVersion: AppInfo.version)
            }
            if let cached = cachedStatus() {
                return cached
            }
            return await fetchLatestRelease()
        }
    }

    /// Forces a network fetch. The manual refresh control in
    /// Settings and the retry controls in the update UI use it.
    static func checkNow() async -> Status {
        await withMinimumCheckingDuration {
            guard isSideloadOrDevBuild else {
                return .upToDate(currentVersion: AppInfo.version)
            }
            return await fetchLatestRelease()
        }
    }

    private static func fetchLatestRelease() async -> Status {
        guard
            let url = URL(
                string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
            )
        else {
            return .failed(message: "Could not build the update URL.")
        }
        var request = URLRequest(url: url)
        // GitHub recommends an explicit Accept header in their
        // API guide. Without it, the response shape is free to
        // change between API versions.
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "Empo/\(AppInfo.version) (iOS update-check)",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(message: "No HTTP response.")
            }
            guard http.statusCode == 200 else {
                return .failed(message: "GitHub returned \(http.statusCode).")
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = json["tag_name"] as? String,
                let htmlURLString = json["html_url"] as? String,
                let htmlURL = URL(string: htmlURLString)
            else {
                return .failed(message: "Could not parse the GitHub response.")
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            persist(latestVersion: latest)
            return verdict(currentVersion: AppInfo.version, latestVersion: latest, releaseURL: htmlURL)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Internals

    private static func withMinimumCheckingDuration(
        _ operation: () async -> Status
    ) async -> Status {
        let started = ContinuousClock.now
        let status = await operation()
        let elapsed = started.duration(to: .now)
        let remaining = minimumCheckingDuration - elapsed
        if remaining > .zero {
            try? await Task.sleep(for: remaining)
        }
        return status
    }

    /// Returns the cached result when the last successful check is
    /// still inside `recheckInterval`. Each call re-compares the
    /// cached version, so a hot-fix bump to MARKETING_VERSION
    /// (without an app restart) still flips status to `upToDate`
    /// instead of a stale `available`.
    private static func cachedStatus() -> Status? {
        let defaults = UserDefaults.standard
        guard
            let lastChecked = defaults.object(forKey: DefaultsKey.lastCheckedAt) as? Date,
            Date().timeIntervalSince(lastChecked) < recheckInterval,
            let latest = defaults.string(forKey: DefaultsKey.lastKnownLatestVersion)
        else {
            return nil
        }
        let url = URL(
            string: "https://github.com/\(owner)/\(repo)/releases/latest"
        )!
        return verdict(currentVersion: AppInfo.version, latestVersion: latest, releaseURL: url)
    }

    private static func persist(latestVersion: String) {
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: DefaultsKey.lastCheckedAt)
        defaults.set(latestVersion, forKey: DefaultsKey.lastKnownLatestVersion)
    }

    /// Compares two semver-shaped version strings. Returns
    /// `.upToDate` when current >= latest, otherwise
    /// `.available`. Non-numeric components compare lexically so
    /// pre-release suffixes degrade gracefully instead of crashing.
    private static func verdict(
        currentVersion: String,
        latestVersion: String,
        releaseURL: URL
    ) -> Status {
        if compareSemver(currentVersion, latestVersion) >= 0 {
            return .upToDate(currentVersion: currentVersion)
        }
        return .available(latestVersion: latestVersion, releaseURL: releaseURL)
    }

    /// Returns 1 / 0 / -1 like `<=>` for two dotted version
    /// strings. Splits on dot, parses each chunk as Int when
    /// possible (lexical fallback otherwise), pads the shorter
    /// list with zeros so "1.0" compares equal to "1.0.0".
    private static func compareSemver(_ a: String, _ b: String) -> Int {
        let lhs = a.split(separator: ".").map(String.init)
        let rhs = b.split(separator: ".").map(String.init)
        let n = max(lhs.count, rhs.count)
        for i in 0..<n {
            let l = i < lhs.count ? lhs[i] : "0"
            let r = i < rhs.count ? rhs[i] : "0"
            if let li = Int(l), let ri = Int(r) {
                if li != ri { return li > ri ? 1 : -1 }
            } else {
                if l != r { return l > r ? 1 : -1 }
            }
        }
        return 0
    }
}
