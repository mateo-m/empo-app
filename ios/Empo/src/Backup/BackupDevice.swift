import Foundation
import UIKit

/// What the engine and the sync pass write into `writer.json` and
/// `device.json`, per SPEC 5.5.
@MainActor
enum BackupDevice {

    /// The vendor id. iOS mints a new one after the user removes
    /// every app of this vendor, and a namespace outlives that, so a
    /// device that comes back with a new id meets the writer
    /// mismatch of 5.12 and asks.
    static var id: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    }

    static var name: String { UIDevice.current.name }
    static var model: String { UIDevice.current.model }
}
