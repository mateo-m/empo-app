import Foundation
import GameProbe

/// What the system reports about one item in the ubiquity container.
struct ICloudItemReading: Sendable {
    /// `NSMetadataUbiquitousItemIsUploadedKey`. The one thing that
    /// makes a put durable on iCloud, per SPEC 8.5.
    var isUploaded: Bool
    /// The item is on this device, so a `get` can read it.
    var isDownloaded: Bool
    /// `NSMetadataUbiquitousItemUploadingErrorKey`, mapped onto the
    /// seven kinds of 8.4. A full account arrives here, per 9.1.
    var uploadingError: BackupProviderError?
    var downloadingError: BackupProviderError?
    var percentDownloaded: Double
    /// The size in the cloud. The file on this device can be a small
    /// placeholder that stands in for it.
    var sizeBytes: Int64?
}

/// The one metadata query the iCloud target reads, per SPEC 9.1.
///
/// A local write into the container returns at once, even when the
/// account is full, so the write proves nothing. `NSMetadataQuery` is
/// the only thing that reports the real state of the transfer, and
/// 8.5 rests on it: the manifest-last rule of 5.8 waits for it, the
/// freshness clock of 7.1 starts at it, and proven coverage in 11.12
/// reads it.
///
/// One live query serves the whole target. A fresh query per call
/// would rescan the container every time, and the engine calls
/// `confirm` once per blob.
///
/// `NSMetadataQuery` needs a run loop, so it lives on the main actor.
@MainActor
final class ICloudUploadWatch {

    /// The longest wait for the first gather. Nothing else ends that
    /// wait when the gather never finishes.
    private static let gatherWait: Duration = .seconds(60)

    private let query = NSMetadataQuery()
    /// Every item the query holds, by resolved file path.
    private var readings: [String: ICloudItemReading] = [:]
    private var didGather = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var observers: [NSObjectProtocol] = []
    private var didStart = false
    private(set) var isStopped = false

    /// Starts the query and gathers once. Safe to call again.
    func start() {
        guard !didStart, !isStopped else { return }
        didStart = true

        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // The scope already holds this app's container and nothing
        // else, so the predicate takes every name in it.
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")
        query.valueListAttributes = [
            NSMetadataUbiquitousItemIsUploadedKey,
            NSMetadataUbiquitousItemUploadingErrorKey,
            NSMetadataUbiquitousItemDownloadingStatusKey,
        ]

        let center = NotificationCenter.default
        observers = [
            NSNotification.Name.NSMetadataQueryDidFinishGathering,
            NSNotification.Name.NSMetadataQueryDidUpdate,
        ].map { name in
            center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collect() }
            }
        }

        query.start()
    }

    /// Ends the query. A target that still holds this watch reads no
    /// item from now on.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        query.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        readings = [:]
        wakeEveryWaiter()
    }

    /// What the system reports about the item at `url`, or `nil`
    /// where the query holds no item there.
    ///
    /// The first call waits for the gather to finish. Every later
    /// call reads what the last update left.
    func reading(for url: URL) async -> ICloudItemReading? {
        await gathered()
        return readings[Self.key(for: url)]
    }

    /// The size in the cloud of every item, by resolved file path.
    func sizes() async -> [String: Int64] {
        await gathered()
        return readings.compactMapValues(\.sizeBytes)
    }

    /// Waits for the next update of the query, or for `limit`. It
    /// answers false at once when the watch is stopped.
    @discardableResult
    func nextChange(within limit: Duration) async -> Bool {
        guard !isStopped else { return false }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                self?.waiters.removeValue(forKey: id)?.resume()
            }
        }
        return !isStopped
    }

    private func gathered() async {
        start()
        guard !didGather else { return }
        await nextChange(within: Self.gatherWait)
    }

    private func wakeEveryWaiter() {
        let waiting = waiters.values
        waiters = [:]
        for continuation in waiting { continuation.resume() }
    }

    /// Reads the results into a dictionary. Updates must stop while
    /// a reader walks the results, per `NSMetadataQuery`.
    private func collect() {
        query.disableUpdates()
        var found: [String: ICloudItemReading] = [:]
        for row in 0..<query.resultCount {
            guard let item = query.result(at: row) as? NSMetadataItem,
                let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL
            else { continue }
            found[Self.key(for: url)] = Self.reading(of: item)
        }
        query.enableUpdates()

        readings = found
        didGather = true
        wakeEveryWaiter()
    }

    private static func reading(of item: NSMetadataItem) -> ICloudItemReading {
        let isUploaded =
            (item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? NSNumber)?
            .boolValue ?? false
        let status =
            item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
        return ICloudItemReading(
            isUploaded: isUploaded,
            isDownloaded: status == NSMetadataUbiquitousItemDownloadingStatusCurrent
                || status == NSMetadataUbiquitousItemDownloadingStatusDownloaded,
            uploadingError: error(of: item, key: NSMetadataUbiquitousItemUploadingErrorKey),
            downloadingError: error(of: item, key: NSMetadataUbiquitousItemDownloadingErrorKey),
            percentDownloaded: (item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey)
                as? NSNumber)?.doubleValue ?? 0,
            sizeBytes: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value)
    }

    private static func error(of item: NSMetadataItem, key: String) -> BackupProviderError? {
        guard let error = item.value(forAttribute: key) as? NSError else { return nil }
        return ICloudDrive.error(
            domain: error.domain, code: error.code, description: error.localizedDescription)
    }

    /// The path both sides agree on. The container URL and the query
    /// results can name the same file through different symlinks.
    nonisolated static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
