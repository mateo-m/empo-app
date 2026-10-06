import Foundation

// The scene connects before the splash lifts, so the catch-up
// timer, the sync pass, the pill, and the resume question would
// all start under the logo without this hold.
@MainActor
@Observable
final class BackupLaunchGate {

    static let shared = BackupLaunchGate()

    private init() {}

    private(set) var isOpen = false
    private var waiting: [() -> Void] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let work = waiting
        waiting = []
        work.forEach { $0() }
    }

    func whenOpen(_ work: @escaping () -> Void) {
        if isOpen { work() } else { waiting.append(work) }
    }
}
