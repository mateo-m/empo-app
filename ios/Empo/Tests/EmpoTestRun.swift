import Foundation
import StoreKitTest

/// XCTest makes the principal class of the test bundle when it loads the
/// bundle.
final class EmpoTestRun: NSObject {

    // StoreKit picks the test store or the sandbox when the app starts. It
    // picks the test store only after a session put the StoreKit file on
    // the Simulator, so a new Simulator sends the first start to the
    // sandbox. This start puts the file there. The scheme runs
    // EmpoPurchaseTests after this bundle, in a new start of the app.
    private let storeSession: SKTestSession

    override init() {
        do {
            storeSession = try SKTestSession(configurationFileNamed: "Empo")
        } catch {
            fatalError("The test store did not start: \(error)")
        }
        super.init()
    }
}
