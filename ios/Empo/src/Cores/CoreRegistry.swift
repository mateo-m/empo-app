import Foundation

/// Ordered list of the built-in cores, mapping a persisted
/// `CoreKind` to the live `GameCore` that implements it. Cores are
/// a compile-time source contract (`docs/plans/emulator-cores.md`):
/// registration happens here, not at runtime.
struct CoreRegistry: Sendable {
    static let shared = CoreRegistry()

    /// Every core built into this binary, in registration order.
    /// mkxp is the only core today; rmWeb joins in phase 3 of the
    /// cores plan.
    let allCores: [any GameCore] = [MkxpCore()]

    /// The core registered for `kind`, or nil when this build has
    /// none (`.unsupported`, or a kind added by a future build).
    func core(for kind: CoreKind) -> (any GameCore)? {
        allCores.first { $0.kind == kind }
    }
}
