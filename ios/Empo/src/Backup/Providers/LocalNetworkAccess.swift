import Foundation
import GameProbe
import Network

/// iOS 27 shows the local network alert on the first connection to a
/// private address, and the URLSession request that caused it fails
/// while the alert is up. A connection opened here sits in
/// `waiting(ENETDOWN)` until the user answers, so the check that
/// follows meets an answered alert. A refusal keeps the same state,
/// so the wait has a limit.
enum LocalNetworkAccess {

    static func waitForTheAnswer(to address: URL) async {
        guard let host = address.host, LocalNetworkRule.asksThePermission(host: host),
            let port = NWEndpoint.Port(rawValue: UInt16(clamping: address.port ?? 443))
        else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let states = AsyncStream<NWConnection.State> { continuation in
            connection.stateUpdateHandler = { continuation.yield($0) }
            connection.start(queue: .global())
        }
        let waiting = Task {
            for await state in states {
                BackupLog.line("LocalNetworkAccess", "\(host): \(state)")
                switch state {
                case .setup, .preparing: continue
                case .waiting(.posix(.ENETDOWN)): continue
                case .ready, .waiting, .failed, .cancelled: return
                @unknown default: return
                }
            }
        }
        let limit = Task {
            try? await Task.sleep(for: .seconds(60))
            waiting.cancel()
        }
        await waiting.value
        limit.cancel()
        connection.cancel()
    }
}
