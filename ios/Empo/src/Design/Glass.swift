// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct GlassStyle {
    var tint: Color?
    var isInteractive = false

    static let regular = GlassStyle()

    func tint(_ color: Color) -> GlassStyle {
        GlassStyle(tint: color, isInteractive: isInteractive)
    }

    func interactive(_ isInteractive: Bool = true) -> GlassStyle {
        GlassStyle(tint: tint, isInteractive: isInteractive)
    }

    @available(iOS 26.0, macOS 26.0, *)
    fileprivate var glass: Glass {
        let glass = tint.map { Glass.regular.tint($0) } ?? .regular
        return glass.interactive(isInteractive)
    }
}

extension View {
    @ViewBuilder
    func glass(_ style: GlassStyle = .regular, in shape: some Shape) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(style.glass, in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.thinMaterial)
                    if let tint = style.tint {
                        shape.fill(tint)
                    }
                }
            }
            .overlay(shape.stroke(.white.opacity(Alpha.border), lineWidth: 0.5))
        }
    }

    /// Interactive glass reacts to a press by itself. The material
    /// fallback does not, so it scales down.
    @ViewBuilder
    func glassPress(_ isPressed: Bool) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
        } else {
            scaleEffect(isPressed ? PressScale.standard : 1)
                .animation(Motion.snappy, value: isPressed)
        }
    }
}
