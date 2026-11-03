// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// The functions of GameCore.h in one core framework.
struct GameCoreLibrary {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias MessageCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    typealias RectCallback = @convention(c) (Float, Float, Float, Float, UnsafeMutableRawPointer?) -> Void

    let runApp: @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    let setGamePath: @convention(c) (UnsafePointer<CChar>?) -> Void
    let setSetting: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    let setDebugLogPath: @convention(c) (UnsafePointer<CChar>?) -> Void
    let setCABundlePath: @convention(c) (UnsafePointer<CChar>?) -> Void
    let setLauncherIdentity: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    let applySessionConfig: @convention(c) (UnsafePointer<GameCoreSessionConfig>?) -> Void
    let resetSessionState: @convention(c) () -> Void
    let setGameControllerCaptureEnabled: @convention(c) (Bool) -> Void
    let getGameWindow: @convention(c) () -> UnsafeMutableRawPointer?
    let didEngineExitCleanly: @convention(c) () -> Int32
    let injectKeyEvent: @convention(c) (Int32, Int32) -> Void
    let requestPause: @convention(c) () -> Void
    let requestResume: @convention(c) () -> Void
    let getFastForwardMultiplier: @convention(c) () -> Int32
    let setFastForwardMultiplier: @convention(c) (Int32) -> Void
    let setCheatsEnabled: @convention(c) (Bool) -> Void
    let signalErrorDismissed: @convention(c) () -> Void
    let signalInfoDismissed: @convention(c) () -> Void
    let setEngineTerminatedCallback: @convention(c) (Callback?, UnsafeMutableRawPointer?) -> Void
    let setGameRectChangedCallback: @convention(c) (RectCallback?, UnsafeMutableRawPointer?) -> Void
    let setErrorMessageCallback: @convention(c) (MessageCallback?, UnsafeMutableRawPointer?) -> Void
    let setInfoMessageCallback: @convention(c) (MessageCallback?, UnsafeMutableRawPointer?) -> Void

    struct OpenError: Error, CustomStringConvertible {
        let description: String
    }

    init(path: String) throws {
        // RTLD_LOCAL, so that the core's own names stay in its image.
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw OpenError(description: String(cString: dlerror()))
        }
        func function<T>(_ name: String) throws -> T {
            guard let symbol = dlsym(handle, "gamecore_" + name) else {
                throw OpenError(description: "\(path) has no gamecore_\(name)")
            }
            return unsafeBitCast(symbol, to: T.self)
        }
        runApp = try function("run_app")
        setGamePath = try function("setGamePath")
        setSetting = try function("setSetting")
        setDebugLogPath = try function("setDebugLogPath")
        setCABundlePath = try function("setCABundlePath")
        setLauncherIdentity = try function("setLauncherIdentity")
        applySessionConfig = try function("applySessionConfig")
        resetSessionState = try function("resetSessionState")
        setGameControllerCaptureEnabled = try function("setGameControllerCaptureEnabled")
        getGameWindow = try function("getGameWindow")
        didEngineExitCleanly = try function("didEngineExitCleanly")
        injectKeyEvent = try function("injectKeyEvent")
        requestPause = try function("requestPause")
        requestResume = try function("requestResume")
        getFastForwardMultiplier = try function("getFastForwardMultiplier")
        setFastForwardMultiplier = try function("setFastForwardMultiplier")
        setCheatsEnabled = try function("setCheatsEnabled")
        signalErrorDismissed = try function("signalErrorDismissed")
        signalInfoDismissed = try function("signalInfoDismissed")
        setEngineTerminatedCallback = try function("setEngineTerminatedCallback")
        setGameRectChangedCallback = try function("setGameRectChangedCallback")
        setErrorMessageCallback = try function("setErrorMessageCallback")
        setInfoMessageCallback = try function("setInfoMessageCallback")
    }
}
