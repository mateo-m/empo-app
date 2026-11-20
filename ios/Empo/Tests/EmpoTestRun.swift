import Foundation
import StoreKitTest

/// XCTest makes the principal class of the test bundle when it loads the
/// bundle, before the first test.
final class EmpoTestRun: NSObject {

    // StoreKit uses the sandbox store for the whole run when the app makes
    // a StoreKit call before the session exists. Tests that run before
    // PlusStoreTests read Plus too, for example the backup tests.
    static let storeSession = Result { try SKTestSession(configurationFileNamed: "Empo") }

    override init() {
        _ = Self.storeSession
        super.init()
    }
}
