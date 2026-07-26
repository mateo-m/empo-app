import Foundation

/// Ordered list of the built-in cores, mapping a persisted
/// `CoreKind` to the live `GameCore` that implements it. Cores are
/// a compile-time source contract (`docs/plans/emulator-cores.md`):
/// registration happens here, not at runtime.
struct CoreRegistry: Sendable {
    static let shared = CoreRegistry()

    /// Every core built into this binary, in registration order.
    /// Registration is conditional-compilation-friendly: a core
    /// whose host package is absent from the build simply does not
    /// register.
    let allCores: [any GameCore]

    init() {
        var cores: [any GameCore] = [MkxpCore()]
        #if canImport(RmWebHost)
            // `RmWebCore` is the Empo adapter compiled from the
            // rmweb-core submodule (adapters/empo/RmWebCore.swift);
            // it only exists once the submodule + its XcodeGen
            // entries land (see the TODO(rmweb-activation) block in
            // project.yml). Registering it is still dormant even
            // then: the importer rejects MV/MZ until the phase-2
            // gate opens, so no game resolves to `.rmWeb`.
            cores.append(RmWebCore())
        #endif
        allCores = cores
    }

    /// The core registered for `kind`, or nil when this build has
    /// none (`.unsupported`, or a kind added by a future build).
    func core(for kind: CoreKind) -> (any GameCore)? {
        allCores.first { $0.kind == kind }
    }
}
