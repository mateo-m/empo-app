import BackgroundTasks
import UIKit

/// Two things need an app delegate and reach no other way.
///
/// 1. `BGTaskScheduler` wants every launch handler in place before
///    launch ends, per its header. A scene delegate is too late.
/// 2. iOS wakes the app for a finished background transfer through
///    `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
///    alone.
@objc(EmpoAppDelegate)
final class EmpoAppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackupTaskScheduler.register()
        BackupNotifier.start()
        return true
    }

    /// Hands the wake to the one background session of 7.3. iOS gives
    /// the app a few seconds here, and the completion handler ends
    /// them.
    func application(
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
