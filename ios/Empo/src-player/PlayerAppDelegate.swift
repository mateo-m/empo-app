// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import GameProbe

/// Runs one game: starts its core, and owns its window and menus. Empo
/// starts one Empo Player process for each game.
@MainActor
final class PlayerAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let launch: PlayerLaunch
    private let messages: FileHandle
    private let liveChanges: FileHandle
    private var window: NSWindow
    private let pausedOverlay = PausedOverlay()
    private let controllers: ControllerInputManager
    private var aspectRatio: CGFloat?
    private enum PauseReason { case user, minimized, hidden }
    private var pauseReasons: Set<PauseReason> = []
    private var isPaused: Bool { !pauseReasons.isEmpty }
    private let actions: PlayerActionRegistry
    private var gameEnded = false
    private var reportedError = false
    private var errorAlertsOnScreen = 0
    private var isAskingToQuit = false
    private var adoptedGame = false
    private var endSources: [any DispatchSourceProtocol] = []

    init(launch: PlayerLaunch, messages: FileHandle, liveChanges: FileHandle) {
        self.launch = launch
        self.messages = messages
        self.liveChanges = liveChanges
        window = Self.makeWindow(title: launch.title)
        let keys = HeldKeys<KeyHolder>(send: { scancode, pressed in
            gamecore_injectKeyEvent(scancode, pressed ? 1 : 0)
        })
        actions = PlayerActionRegistry(
            engine: PlayerEngine(
                fastForwardMultiplier: { Int(gamecore_getFastForwardMultiplier()) },
                setFastForwardMultiplier: { gamecore_setFastForwardMultiplier(Int32($0)) },
                setCheatsEnabled: { gamecore_setCheatsEnabled($0) },
                tapKey: { keys.tap($0, holdMilliseconds: $1, by: .touch("tap")) }))
        controllers = ControllerInputManager(keys: keys)
    }

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private static func delegate(_ context: UnsafeMutableRawPointer?) -> PlayerAppDelegate? {
        context.map { Unmanaged<PlayerAppDelegate>.fromOpaque($0).takeUnretainedValue() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconPath = launch.iconPath, let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        }
        endWithEmpo()
        prepareGame()
        actions.pauseMenu = { [weak self] in self?.togglePause(nil) }
        actions.runtime.bind(
            fastForwardMultiplier: launch.live.fastForwardMultiplier, cheatsAvailable: launch.supportsCheats)
        NSApp.mainMenu = PlayerMenu.make(
            gameTitle: launch.title, fastForward: actions.runtime.fastForwardMultiplier,
            cheats: actions.isAvailable(EmpoActionCatalog.toggleCheats))
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTag: PlayerMenu.windowMenuTag)?.submenu
        controllers.actionHandler = { [weak self] action, pressed in
            self?.handleAction(action, pressed: pressed) ?? false
        }
        applyBindings(launch.live.bindingLayers)
        // SDL's first scan for controllers runs the main run loop. With
        // the game queued, that run loop would start the game inside the
        // scan, and the game holds the main thread until it ends.
        #if DEBUG
        UITestVirtualController.connectIfRequested()
        #endif
        controllers.start()
        runGame()
        readLiveChanges()
        NSApp.activate()
    }

    private func applyBindings(_ layers: [BindingMap]) {
        controllers.updateResolvedMap(BindingResolver.resolveRuntime(layers: layers).elements)
    }

    private func readLiveChanges() {
        Task { [weak self, liveChanges] in
            do {
                for try await line in liveChanges.bytes.lines {
                    do {
                        self?.apply(try JSONDecoder().decode(PlayerLiveSettings.self, from: Data(line.utf8)))
                    } catch {
                        NSLog("[player] cannot read the settings change: %@", "\(error)")
                    }
                }
            } catch {
                NSLog("[player] cannot read settings changes from Empo: %@", "\(error)")
            }
        }
    }

    private func apply(_ live: PlayerLiveSettings) {
        guard !gameEnded else { return }
        SDLControllers.shared.add(mappings: live.controllerMappings)
        applyBindings(live.bindingLayers)
        guard live.fastForwardMultiplier != actions.runtime.fastForwardMultiplier else { return }
        actions.runtime.reconcile(fastForwardMultiplier: live.fastForwardMultiplier)
        if let bar = NSApp.mainMenu { PlayerMenu.update(bar, fastForward: live.fastForwardMultiplier) }
    }

    private static func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        window.center()
        return window
    }

    /// Ends the game when Empo quits it with SIGTERM, and when Empo
    /// itself ends, also by a crash or a force quit.
    private func endWithEmpo() {
        // SDL blocks SIGTERM in every thread it starts, and the other
        // threads block it too, so `kill` never ends the mkxp core. A
        // kqueue signal source still sees a blocked signal.
        let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminationSignal.setEventHandler(handler: Self.endNow)
        let parentExit = DispatchSource.makeProcessSource(
            identifier: getppid(), eventMask: .exit, queue: .global())
        parentExit.setEventHandler(handler: Self.endNow)
        endSources = [terminationSignal, parentExit]
        endSources.forEach { $0.resume() }
        // When Empo ended before the source above existed, launchd
        // (pid 1) is already the parent, and its exit never comes.
        if getppid() == 1 { Self.endNow() }
    }

    private func prepareGame() {
        gamecore_setLauncherIdentity("empo", AppInfo.version)
        gamecore_setCABundlePath(launch.caBundlePath)
        GameCoreLaunch.configure(
            settings: launch.settings,
            userDataDirectory: launch.userDataDirectory,
            fontsDirectory: launch.fontsDirectory,
            verticalAlignment: launch.verticalAlignment,
            debugLogPath: launch.debugLogPath)
        gamecore_setEngineTerminatedCallback(
            { context in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { PlayerAppDelegate.delegate(context)?.engineTerminated() }
                }
            }, context)
        gamecore_setGameRectChangedCallback(
            { _, _, width, height, context in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        PlayerAppDelegate.delegate(context)?.gameRectChanged(width: width, height: height)
                    }
                }
            }, context)
        gamecore_setErrorMessageCallback(
            { message, context in
                let text = message.map { String(cString: $0) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { PlayerAppDelegate.delegate(context)?.showError(text) }
                }
            }, context)
        gamecore_setInfoMessageCallback(
            { message, context in
                let text = message.map { String(cString: $0) } ?? ""
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { PlayerAppDelegate.delegate(context)?.showInfo(text) }
                }
            }, context)
    }

    private func runGame() {
        RunLoop.main.perform { [launch] in
            GameCoreLaunch.run(gamePath: launch.gamePath)
        }
        RunLoop.main.perform { [self] in
            MainActor.assumeIsolated { adoptGame() }
        }
    }

    /// The MV/MZ core gives a view, which goes in this app's window. The
    /// mkxp core gives the NSWindow that SDL made for it. SDL keeps
    /// that window's delegate, and reads its size from that window.
    private func adoptGame() {
        guard !adoptedGame, let pointer = gamecore_getGameWindow() else { return }
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
        let isFirstRect = aspectRatio == nil
        aspectRatio = ratio
        if launch.fixedAspectRatio {
            window.contentAspectRatio = NSSize(width: CGFloat(width), height: CGFloat(height))
        }
        // With the ratio free, the core reports a picture the size of the
        // window, so a resize here would undo the user's own resize.
        guard launch.fixedAspectRatio || isFirstRect, !window.styleMask.contains(.fullScreen) else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        var size = NSSize(width: visible.height * 0.75 * ratio, height: visible.height * 0.75)
        if size.width > visible.width * 0.9 {
            size = NSSize(width: visible.width * 0.9, height: visible.width * 0.9 / ratio)
        }
        window.setContentSize(size)
        window.center()
    }

    /// No core has a call that stops its game cleanly, so a save that
    /// the game writes at this moment is cut short.
    nonisolated private static func endNow() {
        fflush(nil)
        _exit(128 + SIGTERM)
    }

    // MARK: - Engine events

    private func engineTerminated() {
        gameEnded = true
        if gamecore_didEngineExitCleanly() == 0, !reportedError {
            showError(nil)
        } else if errorAlertsOnScreen == 0 {
            NSApp.terminate(nil)
        }
    }

    private func showError(_ message: String?) {
        send(.error(message))
        reportedError = true
        errorAlertsOnScreen += 1
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "The game stopped")
        alert.informativeText = message ?? String(localized: "Something went wrong while it was running.")
        alert.addButton(withTitle: String(localized: "Got it"))
        alert.beginSheetModal(for: windowForSheet()) { [self] _ in
            errorAlertsOnScreen -= 1
            gamecore_signalErrorDismissed()
            if gameEnded, errorAlertsOnScreen == 0 { NSApp.terminate(nil) }
        }
    }

    private func showInfo(_ message: String) {
        send(.info(message))
        let alert = NSAlert()
        alert.messageText = launch.title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.beginSheetModal(for: windowForSheet()) { _ in gamecore_signalInfoDismissed() }
    }

    /// A core that fails before it shows its game leaves this app's
    /// window hidden, and a sheet on a hidden window does not show.
    private func windowForSheet() -> NSWindow {
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        return window
    }

    // MARK: - Pause and fast forward

    /// A resume by the user clears every reason, as the menu shows one
    /// paused state.
    @objc func togglePause(_ sender: Any?) {
        setPauseReasons(isPaused ? [] : [.user])
    }

    private func setPauseReasons(_ reasons: Set<PauseReason>) {
        guard !gameEnded else { return }
        let wasPaused = isPaused
        pauseReasons = reasons
        guard isPaused != wasPaused else { return }
        let paused = isPaused
        if paused {
            controllers.releaseAllHeldInputs()
            gamecore_requestPause()
        } else {
            gamecore_requestResume()
        }
        pausedOverlay.isHidden = !paused
        send(paused ? .paused : .resumed)
    }

    private func send(_ message: PlayerMessage) {
        guard let line = try? JSONEncoder().encode(message) else { return }
        try? messages.write(contentsOf: line + Data("\n".utf8))
    }

    @objc func toggleFastForward(_ sender: Any?) {
        actions.runtime.setFastForward(active: !actions.runtime.fastForwardActive)
    }

    @objc func showCheats(_ sender: Any?) {
        actions.handle(EmpoActionCatalog.toggleCheats, pressed: true)
    }

    /// Only Pause works while the game is paused, as in the menu. A
    /// release always goes through, so a held button cannot stick.
    private func handleAction(_ action: String, pressed: Bool) -> Bool {
        guard !gameEnded, !(pressed && isPaused && action != EmpoActionCatalog.pauseMenu) else {
            return false
        }
        return actions.handle(action, pressed: pressed)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePause(_:)):
            item.title = isPaused ? String(localized: "Resume") : String(localized: "Pause")
            return !gameEnded
        case #selector(toggleFastForward(_:)):
            item.state = actions.runtime.fastForwardActive ? .on : .off
            return !gameEnded && !isPaused
        case #selector(showCheats(_:)):
            return !gameEnded && !isPaused
        default:
            return true
        }
    }

    @objc private func windowDidMiniaturize(_ notification: Notification) {
        setPauseReasons(pauseReasons.union([.minimized]))
    }
    @objc private func windowDidDeminiaturize(_ notification: Notification) {
        setPauseReasons(pauseReasons.subtracting([.minimized]))
    }

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
    func applicationDidHide(_ notification: Notification) { setPauseReasons(pauseReasons.union([.hidden])) }
    func applicationDidUnhide(_ notification: Notification) {
        setPauseReasons(pauseReasons.subtracting([.hidden]))
    }
    func applicationDidResignActive(_ notification: Notification) { controllers.releaseAndForgetHeldInputs() }

    // MARK: - Quit

    @objc func closeGame(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc func showAboutEmpo(_ sender: Any?) {
        let empo = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Empo",
            .applicationIcon: NSWorkspace.shared.icon(forFile: empo.path),
        ])
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
