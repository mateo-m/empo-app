import Foundation
import GameProbe

/// The join step of SPEC 10.4.
///
/// Empo never syncs settings without an explicit join. The first
/// device makes a group when the user adds a target. A second device
/// finds that group on the same target and asks.
@MainActor
enum SyncJoin {

    /// The groups every configured target holds, minus the one this
    /// device already joined.
    static func ask() async -> SyncJoinAsk {
        let state = SyncStore.state()
        var records: [DeviceRecord] = []
        guard let mine = try? BackupKeychain.namespaceId() else { return .none }

        for descriptor in BackupTargets.load() where !descriptor.isPaused {
            guard let provider = await BackupTargets.provider(for: descriptor) else { continue }
            for namespace in await SyncRemote.namespaces(
                root: descriptor.root, provider: provider)
            where namespace.id != mine {
                guard let record = namespace.record else { continue }
                records.append(record)
            }
        }
        return SyncGroupDiscovery.ask(
            of: SyncGroupDiscovery.groups(in: records), joined: state.groupId)
    }

    /// The user said yes. The next pass reads the group's copies and
    /// publishes this device's own.
    ///
    /// The local document goes first. Two documents that never shared
    /// a history give the root a second `preferences` map, and
    /// Automerge answers one of the two, so the group's keys would
    /// read as absent here. This device's own values are not lost
    /// with it: step 4 of 10.5 reads them from the device and writes
    /// them over the merged document.
    static func join(_ group: DiscoveredSyncGroup) {
        SyncDocumentFile.delete()
        try? SyncStore.update { $0.join(group.groupId, at: Date()) }
        SyncPass.shared.schedule(.now)
    }

    /// The first target makes a group, per 10.4. A device with a
    /// group keeps it.
    static func startAGroup() {
        try? SyncStore.update { state in
            guard !state.hasJoined else { return }
            state.startAGroup(at: Date())
        }
    }
}
