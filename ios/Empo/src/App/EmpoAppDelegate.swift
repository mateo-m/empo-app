import BackgroundTasks
import UIKit

/// Empo's app delegate, on top of SDL's.
///
/// SDL owns `main` and its own delegate does the engine work, so this
/// class calls `super` first and adds what SDL knows nothing about.
/// Two things need a delegate and reach no other way.
///
/// 1. `BGTaskScheduler` wants every launch handler in place before
///    launch ends, per its header. A scene delegate is too late.
/// 2. iOS wakes the app for a finished background transfer through
///    `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
///    alone.
@objc(EmpoAppDelegate)
final class EmpoAppDelegate: SDLUIKitDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [AnyHashable: Any]? = nil
    ) -> Bool {
        let started = super.application(
            application, didFinishLaunchingWithOptions: launchOptions)
        // SDL defers its own `postFinishLaunch` by a run loop turn, so
        // this line still runs inside launch.
        MainActor.assumeIsolated {
            BackupTaskScheduler.register()
            BackupNotifier.start()
        }
        return started
    }

    /// Hands the wake to the one background session of 7.3. iOS gives
    /// the app a few seconds here, and the completion handler ends
    /// them.
    override func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackupTransferSession.identifier else {
            completionHandler()
            return
        }
        BackupTransferSession.shared.takeSystemWake(completion: completionHandler)
    }
}
