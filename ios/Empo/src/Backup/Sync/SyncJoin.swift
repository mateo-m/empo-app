import Foundation
import GameProbe

/// Empo never syncs settings without an explicit join. The first
/// device makes a group when the user adds a target. A second device
/// finds that group on the same target and asks.
@MainActor
enum SyncJoin {

    static func ask() async -> SyncJoinAsk {
        let state = SyncStore.state()
        var records: [DeviceRecord] = []
        let mine: String
        do {
            mine = try BackupKeychain.namespaceId()
        } catch {
            BackupLog.line("SyncJoin", "The namespace id was not read: \(error)")
            return .none
        }

        for descriptor in BackupTargets.writable() {
            guard let provider = await BackupTargets.provider(for: descriptor) else { continue }
            for namespace in await SyncRemote.namespaces(
                root: descriptor.root, provider: provider) ?? []
            where namespace.id != mine {
                guard let record = namespace.record else { continue }
                records.append(record)
            }
        }
        return SyncGroupDiscovery.ask(
            of: SyncGroupDiscovery.groups(in: records), joined: state.groupId)
    }

    /// The local document goes only after the join is saved. Two
    /// documents that never shared a history give the root a second
    /// `preferences` map, and Automerge answers one of the two, so the
    /// group's keys would read as absent here. The next pass reads
    /// this device's own values and adds the ones the group does not
    /// hold.
    static func join(_ group: DiscoveredSyncGroup) {
        SyncPass.shared.join {
            do {
                try SyncStore.update { $0.join(group.groupId) }
            } catch {
                BackupLog.line("SyncJoin", "The join was not saved: \(error)")
                return
            }
            do {
                try AutomergeDocumentStore.delete()
            } catch {
                BackupLog.line("SyncJoin", "The old document was not deleted: \(error)")
            }
        }
    }

    static func startAGroup() {
        do {
            try SyncStore.update { state in
                guard !state.hasJoined else { return }
                state.startAGroup()
            }
        } catch {
            BackupLog.line("SyncJoin", "The new group was not saved: \(error)")
        }
    }
}
