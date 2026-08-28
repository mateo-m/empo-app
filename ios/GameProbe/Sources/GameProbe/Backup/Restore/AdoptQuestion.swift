import Foundation

/// The adopt question of SPEC 11.5.
///
/// Asked once per namespace whose recorded device matches this
/// device. It appears inside the fresh-install flow, right before the
/// progress screen, and otherwise as a banner on the Backups screen.
///
/// A genuinely new device sees neither form.
///
/// A device that adopts a namespace leaves no empty one behind,
/// because a namespace id is created only at the first write, per
/// 5.2. There is nothing here that makes a namespace, and nothing
/// downstream may make one before the first write either.
public enum AdoptQuestion {

    /// Where the question shows.
    public enum Place: Equatable, Sendable {
        /// Inside the fresh-install flow, right before the progress
        /// screen.
        case freshInstall
        /// As a banner on the Backups screen.
        case backupsScreen
    }

    public enum Answer: String, Codable, Sendable, CaseIterable, Equatable {
        /// Continue that namespace's history. The default.
        case adopt
        /// Leave it and write a new namespace at the first write.
        case startFresh = "start-fresh"
    }

    public static let question = "Empo found backups from this device. Continue its backup history?"

    /// Continue is the default.
    public static let defaultAnswer: Answer = .adopt

    /// Whether the question fires for one namespace.
    ///
    /// The recorded device is what `device.json` carries, per 5.1. A
    /// namespace this device already owns needs no question, because
    /// it is already ours.
    public static func fires(
        recordedDeviceId: String?, thisDeviceId: String, alreadyOwned: Bool
    ) -> Bool {
        guard !alreadyOwned, let recordedDeviceId else { return false }
        return recordedDeviceId == thisDeviceId
    }

    /// Every namespace this device may adopt, from the device
    /// records the scan read.
    public static func namespaces(
        records: [String: DeviceRecord], thisDeviceId: String, owned: Set<String> = []
    ) -> [String] {
        records
            .filter {
                fires(
                    recordedDeviceId: $0.value.deviceId, thisDeviceId: thisDeviceId,
                    alreadyOwned: owned.contains($0.key))
            }
            .keys
            .sorted()
    }
}
