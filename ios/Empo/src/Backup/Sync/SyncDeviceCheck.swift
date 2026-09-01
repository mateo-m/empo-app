import Foundation
import GameProbe

/// The launch arguments the preference-sync device checks of ticket
/// 020 use.
///
/// `-syncJoin YES` joins the first group a target holds, which is
/// check 1 with no sheet. `-syncDump YES` writes what the merged
/// document carries to the backup log, which is how checks 2 to 5
/// read what crossed between two devices.
///
/// Ticket 017 brings the screens that carry both. Delete this file
/// when they land.
@MainActor
enum SyncDeviceCheck {

    /// Whether each pass writes what the document carries to the log.
    private static var dumps = false

    static func run() {
        dumps = UserDefaults.standard.bool(forKey: "syncDump")
        guard UserDefaults.standard.bool(forKey: "syncJoin") else { return }
        Task {
            guard case .confirm(let group) = await SyncJoin.ask() else {
                log("no target holds a group to join")
                return
            }
            SyncJoin.join(group)
            log("joined \(group.groupId) with \(group.deviceNames.joined(separator: ", "))")
        }
    }

    /// Writes what one pass merged. It does nothing without
    /// `-syncDump YES`.
    static func dump(_ model: SyncDocumentModel, heads: [String]) {
        guard dumps else { return }
        log("heads \(heads.joined(separator: " "))")
        log("schema \(model.schemaVersion), writer \(model.minimumWriterVersion)")
        for (key, value) in model.preferences.sorted(by: { $0.key < $1.key }) {
            log("preference \(key) = \(value)")
        }
        for (id, binding) in model.controllerBindings.sorted(by: { $0.key < $1.key }) {
            log("binding \(id) = \(binding)")
        }
        for (id, profile) in model.layoutProfiles.sorted(by: { $0.key < $1.key }) {
            let state = profile.isDeleted ? "deleted" : "\(profile.controls.count) controls"
            log("profile \(id) \"\(profile.name)\" \(state)")
        }
        for id in model.targetDescriptors.keys.sorted() {
            log("descriptor \(id)")
        }
    }

    private static func log(_ message: String) {
        guard AppSettings.shared.debugLogs else { return }
        BackupLog.line("SyncDeviceCheck", message)
    }
}
