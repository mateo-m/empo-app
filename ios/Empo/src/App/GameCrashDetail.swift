// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe

/// What the report "The game crashed." says about the session.
struct GameCrashDetail: Codable, Equatable {
    /// Nil on Mac, where each game runs in Empo Player.
    let runner: GameRunner?
    /// Nil for a core that has no Ruby.
    let ruby: RubyVersion?
    var resources: DeviceResources
    /// Nil on Mac, which sends no memory warning.
    var memoryWarning: Bool?

    struct RubyVersion: Codable, Equatable {
        /// "auto", or the version that the game settings fix.
        let setting: String
        /// The version that Empo gave the core.
        let used: String
    }
}

extension GameCrashDetail.RubyVersion {
    @MainActor init?(launched: LaunchedSettings, coreSettings: [CoreSetting]) {
        guard let mkxp = launched.core as? MkxpLaunchedSettings,
            let used = coreSettings.first(where: { $0.key == GAMECORE_SETTING_RUBY_VERSION })?.value
        else { return nil }
        setting = mkxp.settings.rubyVersionOverride.map(String.init) ?? "auto"
        self.used = used
    }
}

/// How the game ended.
enum GameCrashEnd: Equatable {
    /// Empo ended while the game ran. The next launch reports it.
    case empo
    /// The game, or the process that ran it, ended while Empo ran.
    case game
    case player(Exit)

    enum Exit: Equatable {
        case signal(Int32)
        case status(Int32)
    }
}

/// The memory and the heat of the device at one moment.
struct DeviceResources: Codable, Equatable {
    /// Nil on Mac, where the memory of Empo tells nothing about the game.
    let appMemoryMB: Int?
    let freeMemoryMB: Int?
    let thermalState: DeviceThermalState

    static func read() -> DeviceResources {
        #if os(iOS)
        let appMemoryMB = readAppMemoryMB().map { Int($0) }
        #else
        let appMemoryMB: Int? = nil
        #endif
        return DeviceResources(
            appMemoryMB: appMemoryMB, freeMemoryMB: readFreeMemoryMB(),
            thermalState: DeviceThermalState(ProcessInfo.processInfo.thermalState))
    }

    static func readAppMemoryMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    private static func readFreeMemoryMB() -> Int? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(UInt64(info.free_count) * UInt64(vm_kernel_page_size) / 1_048_576)
    }
}

extension DeviceThermalState {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}
