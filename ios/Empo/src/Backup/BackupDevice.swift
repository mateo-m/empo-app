import Foundation
import UIKit

/// What the engine and the sync pass write into `writer.json` and
/// `device.json`, per SPEC 5.5.
@MainActor
enum BackupDevice {

    /// iOS mints a new vendor id after the user removes every app of
    /// this vendor, so a device that comes back meets the writer
    /// mismatch of 5.12 and asks. The id is nil after a restart until
    /// the first unlock.
    static var id: String? {
        UIDevice.current.identifierForVendor?.uuidString
    }

    static var name: String { UIDevice.current.name }
    static var model: String { UIDevice.current.model }
}
