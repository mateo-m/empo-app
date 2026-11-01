// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit

/// Runs one game: opens its core, starts it, and owns its window and
/// menus. Empo starts one Empo Player process for each game.
@MainActor
final class PlayerAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let launch: PlayerLaunch
    private var core: GameCoreLibrary!
    private var window: NSWindow!
    private let pausedOverlay = PausedOverlay()
    private lazy var controllers = ControllerInput(
        pressKey: { [weak self] scancode, pressed in self?.core.injectKeyEvent(scancode, pressed ? 1 : 0) },
        runAction: { [weak self] action in
            if action == "$pauseMenu" { self?.togglePause(nil) }
        })
    private var aspectRatio: CGFloat?
    private var isPaused = false
    private var pausedBySystem = false
    private var isFastForwarding = false
    private var gameEnded = false
    private var isAskingToQuit = false
    private var adoptedGame = false
    private var terminationSignal: DispatchSourceSignal?

    init(launch: PlayerLaunch) {
        self.launch = launch
    }

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private static func delegate(_ context: UnsafeMutableRawPointer?) -> PlayerAppDelegate {
        Unmanaged<PlayerAppDelegate>.fromOpaque(context!).takeUnretainedValue()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = PlayerMenu.make(gameTitle: launch.title, fastForward: launch.fastForwardMultiplier)
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTag: PlayerMenu.windowMenuTag)?.submenu
        if let iconPath = launch.iconPath, let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        }
        do {
            core = try GameCoreLibrary(path: launch.corePath)
        } catch {
            NSLog("[player] cannot open %@: %@", launch.corePath, "\(error)")
            exit(70)
        }
        makeWindow()
        startGame()
        controllers.start()
        NSApp.activate()
    }

    private func makeWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = launch.title
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        window.center()
    }

    private func startGame() {
        // SDL blocks SIGTERM in every thread it starts, and the other
        // threads block it too, so `kill` never ends the mkxp core. A
        // kqueue signal source still sees a blocked signal.
        let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminationSignal.setEventHandler(handler: Self.endOnTerminationSignal)
        terminationSignal.resume()
        self.terminationSignal = terminationSignal
        core.setLauncherIdentity("empo")
        core.setCABundlePath(launch.caBundlePath)
        core.setDebugLogPath(launch.debugLogPath)
        for setting in launch.settings {
            core.setSetting(setting.key, setting.value)
        }
        let fonts = strdup(launch.fontsDirectory)
        let userData = launch.userDataDirectory.flatMap { strdup($0) }
        defer {
            free(fonts)
            free(userData)
        }
        var config = GameCoreSessionConfig()
        config.userDataDirectory = UnsafePointer(userData)
        config.sharedFontsDirectory = UnsafePointer(fonts)
        config.verticalAlignment = GameCoreVerticalAlignment(rawValue: UInt32(launch.verticalAlignment))
        core.applySessionConfig(&config)
        core.resetSessionState()
        // Empo Player reads the controllers and sends their keys.
        core.setGameControllerCaptureEnabled(false)
        core.setEngineTerminatedCallback(
            { context in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { PlayerAppDelegate.delegate(context).engineTerminated() }
                }
            }, context)
        core.setGameRectChangedCallback(
            { _, _, width, height, context in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        PlayerAppDelegate.delegate(context).gameRectChanged(width: width, height: height)
                    }
                }
            }, context)
        core.setErrorMessageCallback(
            { message, context in
                let text = message.map { String(cString: $0) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { PlayerAppDelegate.delegate(context).showError(text) }
                }
            }, context)
        core.setInfoMessageCallback(
            { message, context in
                let text = message.map { String(cString: $0) } ?? ""
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { PlayerAppDelegate.delegate(context).showInfo(text) }
                }
            }, context)
        core.setGamePath(launch.gamePath)

        // gamecore_run_app may hold the main thread for the whole game,
        // so it runs from a run loop callout and not from a main queue
        // block (GameCore.h).
        RunLoop.main.perform { [self] in
            MainActor.assumeIsolated { _ = core.runApp(CommandLine.argc, CommandLine.unsafeArgv) }
        }
        RunLoop.main.perform { [self] in
            MainActor.assumeIsolated { adoptGame() }
        }
    }

    /// The MV/MZ core gives a view, which goes in this app's window. The
    /// mkxp core gives the NSWindow that SDL made for it. SDL keeps
    /// that window's delegate, and reads its size from that window.
    private func adoptGame() {
        guard !adoptedGame, let pointer = core.getGameWindow() else { return }
        switch Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() {
        case let gameWindow as NSWindow:
            window.close()
            window = gameWindow
            window.title = launch.title
            // SFML makes the PSDK window without these, and a window that
            // cannot resize cannot go full screen.
            window.styleMask.formUnion([.resizable, .miniaturizable])
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.tabbingMode = .disallowed
        case let view as NSView:
            guard let content = window.contentView else { return }
            view.frame = content.bounds
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
            window.makeFirstResponder(Self.firstKeyView(in: view) ?? view)
            window.makeKeyAndOrderFront(nil)
        default:
            NSLog("[player] the core's game window is neither an NSWindow nor an NSView")
            return
        }
        adoptedGame = true
        if let content = window.contentView {
            pausedOverlay.frame = content.bounds
            pausedOverlay.autoresizingMask = [.width, .height]
            pausedOverlay.isHidden = !isPaused
            content.addSubview(pausedOverlay)
        }
        let close = window.standardWindowButton(.closeButton)
        close?.target = self
        close?.action = #selector(closeGame(_:))
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(windowDidMiniaturize(_:)), name: NSWindow.didMiniaturizeNotification,
            object: window)
        center.addObserver(
            self, selector: #selector(windowDidDeminiaturize(_:)),
            name: NSWindow.didDeminiaturizeNotification,
            object: window)
        center.addObserver(
            self, selector: #selector(windowDidExitFullScreen(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: window)
    }

    private static func firstKeyView(in view: NSView) -> NSView? {
        for subview in view.subviews {
            if subview.acceptsFirstResponder { return subview }
            if let found = firstKeyView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Window size

    private func gameRectChanged(width: Float, height: Float) {
        // The mkxp core makes its window while it starts, and sends the
        // first game rect once that window exists.
        adoptGame()
        guard width > 0, height > 0 else { return }
        let ratio = CGFloat(width / height)
        if let aspectRatio, abs(aspectRatio - ratio) < 0.01 { return }
        aspectRatio = ratio
        guard !window.styleMask.contains(.fullScreen) else {
            window.contentAspectRatio = NSSize(width: CGFloat(width), height: CGFloat(height))
            return
        }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        var size = NSSize(width: visible.height * 0.75 * ratio, height: visible.height * 0.75)
        if size.width > visible.width * 0.9 {
            size = NSSize(width: visible.width * 0.9, height: visible.width * 0.9 / ratio)
        }
        window.contentAspectRatio = NSSize(width: CGFloat(width), height: CGFloat(height))
        window.setContentSize(size)
        window.center()
    }

    nonisolated private static func endOnTerminationSignal() {
        _exit(128 + SIGTERM)
    }

    // MARK: - Engine events

    private func engineTerminated() {
        gameEnded = true
        if core.didEngineExitCleanly() != 0 {
            NSApp.terminate(nil)
        } else {
            showError(nil)
        }
    }

    private func showError(_ message: String?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "The game stopped")
        alert.informativeText = message ?? String(localized: "Something went wrong while it was running.")
        alert.addButton(withTitle: String(localized: "Got it"))
        alert.beginSheetModal(for: windowForSheet()) { [self] _ in
            core.signalErrorDismissed()
            if gameEnded { NSApp.terminate(nil) }
        }
    }

    private func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = launch.title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.beginSheetModal(for: windowForSheet()) { [self] _ in core.signalInfoDismissed() }
    }

    /// A core that fails before it shows its game leaves this app's
    /// window hidden, and a sheet on a hidden window does not show.
    private func windowForSheet() -> NSWindow {
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        return window
    }

    // MARK: - Pause and fast forward

    @objc func togglePause(_ sender: Any?) {
        setPaused(!isPaused)
        pausedBySystem = false
    }

    private func setPaused(_ paused: Bool) {
        guard paused != isPaused, !gameEnded else { return }
        isPaused = paused
        if paused {
            controllers.releaseAll()
            core.requestPause()
        } else {
            core.requestResume()
        }
        pausedOverlay.isHidden = !paused
    }

    @objc func toggleFastForward(_ sender: Any?) {
        guard let multiplier = launch.fastForwardMultiplier else { return }
        isFastForwarding.toggle()
        core.setFastForwardMultiplier(Int32(isFastForwarding ? multiplier : 1))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePause(_:)):
            item.title = isPaused ? String(localized: "Resume") : String(localized: "Pause")
            return !gameEnded
        case #selector(toggleFastForward(_:)):
            item.state = isFastForwarding ? .on : .off
            return !gameEnded && !isPaused
        default:
            return true
        }
    }

    private func pauseForSystem() {
        guard !isPaused else { return }
        setPaused(true)
        pausedBySystem = true
    }

    private func resumeAfterSystem() {
        guard pausedBySystem else { return }
        pausedBySystem = false
        setPaused(false)
    }

    @objc private func windowDidMiniaturize(_ notification: Notification) { pauseForSystem() }
    @objc private func windowDidDeminiaturize(_ notification: Notification) { resumeAfterSystem() }

    // macOS 27: when the pointer is over the title bar as a window leaves
    // full screen, the system stops sending key presses to the window,
    // but AppKit still reports it as the key window. A plain AppKit window
    // does the same. Taking the key status again makes the keys come back.
    // AppKit still sees the window as key, so makeKey posts no "did become
    // key" to match the "did resign key", and SFML (PSDK) ignores every key
    // after a lost focus with no gained focus. A call to becomeKey posts it,
    // but the keys then stay lost, so the notification goes out directly.
    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        window.resignKey()
        window.makeKey()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }
    func applicationDidHide(_ notification: Notification) { pauseForSystem() }
    func applicationDidUnhide(_ notification: Notification) { resumeAfterSystem() }
    func applicationDidResignActive(_ notification: Notification) { controllers.releaseAll() }

    // MARK: - Quit

    @objc func closeGame(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if gameEnded { return .terminateNow }
        guard !isAskingToQuit else { return .terminateCancel }
        isAskingToQuit = true
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Quit \"\(launch.title)\"?",
            comment: "Alert title. The placeholder is the game's name.")
        alert.informativeText = String(localized: "Progress you haven't saved will be lost.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: windowForSheet()) { [self] response in
            isAskingToQuit = false
            NSApp.reply(toApplicationShouldTerminate: response == .alertFirstButtonReturn)
        }
        return .terminateLater
    }

    // The quit comes from inside the core's frame, which still holds the
    // main thread, and exit() then runs the core's C++ static destructors
    // under it. PSDK's fonts free their textures after SFML's GL context
    // is gone, and the process crashes.
    func applicationWillTerminate(_ notification: Notification) {
        fflush(nil)
        _exit(0)
    }
}

/// Covers the game while it is paused.
final class PausedOverlay: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        let label = NSTextField(labelWithString: String(localized: "Paused"))
        label.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .largeTitle).pointSize, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
