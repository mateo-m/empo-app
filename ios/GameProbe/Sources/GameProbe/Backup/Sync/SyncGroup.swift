import Foundation

/// The sync group of SPEC 10.4.
///
/// The id is random and non-secret. It names one group of devices
/// that share settings. It grants nothing: a device still needs a
/// target it can open to read the group's copies.
public enum SyncGroup {

    public static let idLength = 32

    public static func makeId() -> String {
        BackupKeys.randomHex(characters: idLength)
    }

    public static func isValidId(_ id: String) -> Bool {
        id.count == idLength && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// One group a target holds, as the join step of 10.4 sees it.
public struct DiscoveredSyncGroup: Equatable, Sendable, Identifiable {

    public var groupId: String
    /// The device names in the group, in the order the picker shows.
    public var deviceNames: [String]
    /// The newest confirmed change in the group, which the picker
    /// names beside the devices.
    public var lastChangeAt: Date?

    public var id: String { groupId }

    public init(groupId: String, deviceNames: [String], lastChangeAt: Date?) {
        self.groupId = groupId
        self.deviceNames = deviceNames
        self.lastChangeAt = lastChangeAt
    }
}

/// What the join step asks, per 10.4. Empo always asks before it
/// joins.
public enum SyncJoinAsk: Equatable, Sendable {
    /// No target holds a group, so there is nothing to join.
    case none
    case confirm(DiscoveredSyncGroup)
    case pick([DiscoveredSyncGroup])
}

public enum SyncGroupDiscovery {

    /// The groups the device records of one target name.
    ///
    /// A record with no group id belongs to a device that never
    /// joined, so it names no group.
    public static func groups(in records: [DeviceRecord]) -> [DiscoveredSyncGroup] {
        var names: [String: [String]] = [:]
        var newest: [String: Date] = [:]
        for record in records {
            guard let groupId = record.syncGroupId, SyncGroup.isValidId(groupId) else { continue }
            names[groupId, default: []].append(record.name)
            if let at = record.syncUpdatedAt, at > (newest[groupId] ?? .distantPast) {
                newest[groupId] = at
            }
        }
        return names.keys.sorted().map {
            DiscoveredSyncGroup(
                groupId: $0, deviceNames: names[$0]?.sorted() ?? [], lastChangeAt: newest[$0])
        }
    }

    /// One group produces a confirmation. Several produce a picker.
    public static func ask(of groups: [DiscoveredSyncGroup], joined: String? = nil) -> SyncJoinAsk {
        let open = groups.filter { $0.groupId != joined }
        switch open.count {
        case 0: return .none
        case 1: return .confirm(open[0])
        default: return .pick(open)
        }
    }
}

/// The copy of SPEC 10.4 and 10.11.
public enum SyncGroupCopy {

    /// The one stable line the Backups screen carries. There is no
    /// dashboard, no per-key state, and no success alert.
    public static let stableLine = "Settings sync when Empo opens."

    /// Two devices with no common target cannot sync.
    public static let noCommonTarget =
        "To sync settings, add one backup target that both devices can open."

    public static func confirmation(of group: DiscoveredSyncGroup) -> String {
        let devices = group.deviceNames.isEmpty ? "another device" : list(group.deviceNames)
        return "Sync settings with \(devices)?"
    }

    /// The join is the consent step, so this line says what changes.
    public static let joinBody =
        "Empo copies your settings, your controller binds, and your layout profiles between "
        + "these devices. It copies no save data."

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }
}
