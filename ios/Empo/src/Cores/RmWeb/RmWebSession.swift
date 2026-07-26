// The rmWeb session adapter: conforms the rmweb-core host
// (`RmWebHostController`, sibling repo mateo-m/rmweb-core,
// host-apple/Sources/RmWebHost) to Empo's `CoreSession` contract.
//
// DORMANT CODE, twice over, and intentionally so:
// - The rmweb-core submodule has not landed, so `RmWebHost` is not
//   importable and this whole file compiles to nothing (see the
//   TODO(rmweb-activation) block in project.yml).
// - Even once it lands, the importer still rejects MV/MZ games
//   (phase 2 of docs/plans/emulator-cores.md), so no library entry
//   resolves to `.rmWeb` until the import gate opens after
//   on-device validation.
// Landing the wiring now, activating later, is the plan's intent.
#if canImport(RmWebHost)
    import Foundation
    import RmWebCommon
    import RmWebHost
    import UIKit

    /// The rmWeb `CoreSession`: owns one `RmWebHostController` (one
    /// disposable `WKWebView` per game run). Because the web content
    /// process is out-of-process, teardown is clean and repeatable -
    /// the capability asymmetry (`quitToLibrary` /
    /// `sequentialSessions` true) that motivated the core contract.
    @MainActor
    final class RmWebSession: CoreSession {
        private let host: RmWebHostController
        private let launch: GameSession.LaunchInput
        private weak var delegate: CoreSessionDelegate?
        /// True once the app asked for termination; suppresses the
        /// host's `.ended` state change so an expected quit is not
        /// re-reported as an unexpected one. Same idea as
        /// `EngineSessionCoordinator.terminationExpected`.
        private var terminationExpected = false

        let capabilities: CoreCapabilities

        /// The webview is an ordinary `UIView`, hosted by
        /// `CoreViewEmbedder` behind the player chrome.
        var surface: CoreSurface { .view(host.view) }

        /// nil when the game folder no longer probes as MV/MZ (it
        /// was validated at import, but files can change under
        /// Files.app); the caller surfaces the invalid-game error.
        init?(launch: GameSession.LaunchInput, delegate: CoreSessionDelegate) {
            guard let layout = RmWebGameDetector.detect(root: launch.gameDir) else {
                return nil
            }
            self.launch = launch
            self.delegate = delegate
            self.capabilities = RmWebCore().capabilities(
                for: launch.game, metadata: launch.metadata)
            let descriptor = RmWebGameDescriptor(
                gameRoot: launch.gameDir,
                // Saves live in the container's `UserData/`, inside
                // the existing per-game contract (migration,
                // deletion, future export) - owner decision 5 in
                // docs/plans/emulator-cores.md.
                saveDirectory: launch.userDataDir,
                layout: layout,
                options: RmWebOptions(
                    // Same per-game setting + default the mkxp
                    // bridge config applies (`GameSession`).
                    networkAllowed: launch.settings.networkEnabled ?? true,
                    debugLogging: launch.debugLogsEnabled
                )
            )
            self.host = RmWebHostController(descriptor: descriptor)
            host.delegate = self
        }

        // MARK: - CoreSession

        func start() {
            host.start()
        }

        /// Snapshot-then-pause, so the frozen frame the pause card /
        /// hero transition shows is the last live frame (mkxp orders
        /// it the same way: the engine captures inside its pause
        /// callback). The completion arrives on the main thread.
        func requestPause() {
            host.takeSnapshot { [weak self] image in
                guard let self else { return }
                self.host.pause()
                self.delegate?.sessionDidPause(snapshot: image)
            }
        }

        func requestResume() {
            // paused → running fires `didChangeState(.running)`,
            // which re-signals `sessionFrameRendered` and releases
            // the resume-snapshot overlay.
            host.resume()
        }

        func requestTerminate() {
            terminationExpected = true
            // Hold self (and thereby the webview) alive until the
            // host has flushed pending saves - `AppState` drops its
            // reference synchronously after this call, and the
            // host's 3s watchdog guarantees the completion runs.
            let retained = self
            host.terminate {
                _ = retained
            }
        }

        func injectInput(_ event: CoreInputEvent) {
            switch event {
            case .scancode(let scancode, let pressed):
                guard let name = Self.logicalKeyNames[scancode] else { return }
                host.setButton(name, pressed: pressed)
            }
        }

        // MARK: - Input mapping

        /// SDL scancode → the runtime's logical key names (the
        /// `LOGICAL_KEYS` table in rmweb-core runtime/src/input.ts).
        /// Lives here in the adapter, not in shared code: scancodes
        /// stay the controls layer's currency and each core
        /// translates at its own boundary. Unmapped scancodes drop
        /// silently - MV/MZ's `Input` class only listens for these
        /// keys anyway. (The runtime also knows "pageup"/"pagedown",
        /// but `KeyCatalog` has no PageUp/PageDown entries, so no
        /// call site can emit them.)
        private static let logicalKeyNames: [Int32: String] = [
            Int32(MKXP_SCANCODE_Z): "ok",
            Int32(MKXP_SCANCODE_X): "cancel",
            Int32(MKXP_SCANCODE_ESCAPE): "menu",
            Int32(MKXP_SCANCODE_LSHIFT): "shift",
            Int32(MKXP_SCANCODE_LCTRL): "control",
            Int32(MKXP_SCANCODE_TAB): "tab",
            Int32(MKXP_SCANCODE_SPACE): "space",
            Int32(MKXP_SCANCODE_RETURN): "enter",
            Int32(MKXP_SCANCODE_LEFT): "left",
            Int32(MKXP_SCANCODE_UP): "up",
            Int32(MKXP_SCANCODE_RIGHT): "right",
            Int32(MKXP_SCANCODE_DOWN): "down",
            Int32(MKXP_SCANCODE_F9): "f9",
        ]

        // MARK: - Host event handling (main actor)

        private func handleStateChange(_ state: RmWebSessionState) {
            switch state {
            case .idle, .loading:
                break
            case .running:
                // The runtime booted inside the page (or the page
                // resumed) - the closest analogue to mkxp's
                // first-frame callback: it flips the loading view to
                // ready and releases the pause snapshot after a
                // resume.
                delegate?.sessionFrameRendered()
            case .paused:
                break  // requestPause() already delivered the snapshot
            case .ended(let reason):
                handleEnded(reason)
            }
        }

        private func handleEnded(_ reason: RmWebEndReason) {
            // An app-requested terminate also lands here; the
            // requestTerminate caller already handled teardown.
            guard !terminationExpected else { return }
            switch reason {
            case .terminated:
                // The page ended on its own (saves flushed, webview
                // torn down) - a clean exit.
                delegate?.sessionTerminated(cleanExit: true)
            case .contentProcessTerminated:
                // WebKit killed the content process (usually memory
                // pressure) - terminated uncleanly.
                // TODO(rmweb-activation): consider the plan's
                // reload-to-title recovery path instead of ending
                // the session outright.
                delegate?.sessionTerminated(cleanExit: false)
            case .loadFailed(let message):
                // Terminate first so `AppState` resets phase before
                // the alert binding evaluates, then overwrite the
                // generic message with the specific failure.
                delegate?.sessionTerminated(cleanExit: false)
                delegate?.sessionDidReportError(
                    "The game failed to load. (\(message))")
            }
        }

        /// Appends host/runtime log lines (page errors, shim
        /// diagnostics) to the game's `Logs/` directory, mirroring
        /// `GameSession.logEngineConfigOverlay`'s append pattern.
        /// The host only delivers these when the user enabled debug
        /// logs (`RmWebOptions.debugLogging`).
        private func appendRuntimeLog(_ line: String) {
            let logsDir = launch.container.ensureLogsDirectory()
            let path = logsDir.appendingPathComponent("rmweb-runtime.log").path
            let text = line.hasSuffix("\n") ? line : line + "\n"
            if FileManager.default.fileExists(atPath: path),
                let data = text.data(using: .utf8),
                let handle = FileHandle(forWritingAtPath: path)
            {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
            } else {
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - RmWebHostDelegate

    extension RmWebSession: RmWebHostDelegate {
        // `RmWebHostDelegate` documents that every call arrives on
        // the main thread, but the protocol itself is not
        // actor-annotated, so hop in with `assumeIsolated` (a
        // re-ordering `Task { @MainActor }` would let state changes
        // race the synchronous flows above).
        nonisolated func rmWebHost(
            _ host: RmWebHostController, didChangeState state: RmWebSessionState
        ) {
            MainActor.assumeIsolated {
                handleStateChange(state)
            }
        }

        nonisolated func rmWebHost(_ host: RmWebHostController, didLog line: String) {
            MainActor.assumeIsolated {
                appendRuntimeLog(line)
            }
        }

        nonisolated func rmWebHost(
            _ host: RmWebHostController, savePersistenceFailed fileName: String,
            error: Error
        ) {
            // Logged, not alerted: RootView's error alert frames
            // messages as session-enders ("Restart Empo") while a
            // game runs, which is wrong for a recoverable save
            // failure. TODO(rmweb-activation): surface this to the
            // user once a non-fatal in-game notice exists.
            MainActor.assumeIsolated {
                appendRuntimeLog(
                    "save persistence failed for \(fileName): \(error.localizedDescription)")
            }
        }
    }

    extension RmWebCore: SessionProviding {
        func makeSession(
            launch: GameSession.LaunchInput,
            delegate: CoreSessionDelegate
        ) -> (any CoreSession)? {
            RmWebSession(launch: launch, delegate: delegate)
        }
    }
#endif
