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

    private let query = NSMetadataQuery()
    /// Every item the query holds, by resolved file path.
    private var readings: [String: ICloudItemReading] = [:]
    private var didGather = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    /// Starts the query and gathers once. Safe to call again.
    func start() {
        guard !didStart else { return }
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
        for name in [
            NSNotification.Name.NSMetadataQueryDidFinishGathering,
            NSNotification.Name.NSMetadataQueryDidUpdate,
        ] {
            center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collect() }
            }
        }

        query.start()
    }

    /// What the system reports about the item at `url`, or `nil`
    /// where the query holds no item there.
    ///
    /// The first call waits for the gather to finish. Every later
    /// call reads what the last update left.
    func reading(for url: URL) async -> ICloudItemReading? {
        start()
        await waitForTheFirstGather()
        return readings[Self.key(for: url)]
    }

    private func waitForTheFirstGather() async {
        guard !didGather else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
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
        guard !didGather else { return }
        didGather = true
        let waiting = waiters
        waiters = []
        for continuation in waiting { continuation.resume() }
    }

    private static func reading(of item: NSMetadataItem) -> ICloudItemReading {
        let isUploaded =
            (item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? NSNumber)?
            .boolValue ?? false
        let status =
            item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
        var uploadingError: BackupProviderError?
        if let error = item.value(forAttribute: NSMetadataUbiquitousItemUploadingErrorKey)
            as? NSError
        {
            uploadingError = ICloudDrive.error(
                domain: error.domain, code: error.code,
                description: error.localizedDescription)
        }
        return ICloudItemReading(
            isUploaded: isUploaded,
            isDownloaded: status == NSMetadataUbiquitousItemDownloadingStatusCurrent
                || status == NSMetadataUbiquitousItemDownloadingStatusDownloaded,
            uploadingError: uploadingError)
    }

    /// The path both sides agree on. The container URL and the query
    /// results can name the same file through different symlinks.
    static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
