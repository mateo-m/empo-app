// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import MetricKit

final class BackgroundExitReports: NSObject, MXMetricManagerSubscriber {
    static let shared = BackgroundExitReports()

    func didReceive(_ payloads: [MXMetricPayload]) {
        let exits = payloads.compactMap { $0.applicationExitMetrics?.backgroundExitData }.map {
            (
                memoryLimit: Int($0.cumulativeMemoryResourceLimitExitCount),
                memoryPressure: Int($0.cumulativeMemoryPressureExitCount),
                normal: Int($0.cumulativeNormalAppExitCount)
            )
        }
        Task { @MainActor in
            for day in exits {
                ErrorReports.backgroundExits(
                    memoryLimit: day.memoryLimit, memoryPressure: day.memoryPressure, normal: day.normal)
            }
        }
    }
}
