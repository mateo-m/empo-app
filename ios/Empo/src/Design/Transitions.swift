// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct EmptyStateView: View {
    let icon: Image
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    var revealed: Bool = true
    var initialDelay: TimeInterval = 0.2
    static let staggerInterval: TimeInterval = 0.1
    static let elementCount = 3

    @State private var appeared = false
    @State private var floating = false

    private func stagger(_ index: Int) -> Animation {
        Motion.standard.delay(initialDelay + Self.staggerInterval * Double(index))
    }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            icon
                .resizable()
                .scaledToFit()
                .frame(width: IconSize.emptyState, height: IconSize.emptyState)
                .foregroundStyle(.secondary)
                .offset(y: floating ? -3 : 3)
                .animation(Motion.float, value: floating)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(stagger(0), value: appeared)
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .centeredMessageWidth()
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(stagger(1), value: appeared)
            Text(subtitle)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .centeredMessageWidth()
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(stagger(2), value: appeared)
        }
        .accessibilityElement(children: .combine)
        .onChange(of: revealed, initial: true) {
            guard revealed, !appeared else { return }
            appeared = true
            let totalDelay = initialDelay + Self.staggerInterval * 2 + 0.3
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(totalDelay))
                floating = true
            }
        }
    }
}

struct StaggeredAppearance: ViewModifier {
    let index: Int
    let trigger: UUID
    var initialDelay: TimeInterval = 0

    private var delay: Double { initialDelay + Double(index) * Motion.staggerFast }

    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 12)
            .onChange(of: trigger) {
                visible = false
                Task { @MainActor in
                    withAnimation(Motion.standard.delay(delay)) {
                        visible = true
                    }
                }
            }
    }
}

extension View {
    func staggered(index: Int, trigger: UUID, initialDelay: TimeInterval = 0) -> some View {
        modifier(StaggeredAppearance(index: index, trigger: trigger, initialDelay: initialDelay))
    }
}

struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

struct ScaleFadeBlurTransition: ViewModifier {
    let active: Bool
    let blurRadius: CGFloat
    var scale: CGFloat = 0.8

    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? scale : 1)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? blurRadius : 0)
    }
}

struct FadeBlurTransition: ViewModifier {
    let active: Bool
    let blurRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? blurRadius : 0)
    }
}

struct ControlTransition: ViewModifier {
    let active: Bool
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.8 : 1, anchor: anchor)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 6 : 0)
    }
}

extension AnyTransition {
    static var emptyState: AnyTransition {
        .modifier(
            active: ScaleFadeBlurTransition(active: true, blurRadius: 10),
            identity: ScaleFadeBlurTransition(active: false, blurRadius: 10)
        )
    }

    static var cardAppear: AnyTransition {
        .modifier(
            active: ScaleFadeBlurTransition(active: true, blurRadius: 6),
            identity: ScaleFadeBlurTransition(active: false, blurRadius: 6)
        )
    }

    static var fadeBlur: AnyTransition {
        .modifier(
            active: FadeBlurTransition(active: true, blurRadius: 6),
            identity: FadeBlurTransition(active: false, blurRadius: 6)
        )
    }

    /// One element that changes state in place: the old one shrinks
    /// a little as it fades and blurs out, the new one grows into
    /// place.
    static var stateChange: AnyTransition {
        .modifier(
            active: ScaleFadeBlurTransition(active: true, blurRadius: 6, scale: 0.9),
            identity: ScaleFadeBlurTransition(active: false, blurRadius: 6, scale: 0.9)
        )
    }

    static var viewModeSwitch: AnyTransition {
        .modifier(
            active: ScaleFadeBlurTransition(active: true, blurRadius: 10),
            identity: ScaleFadeBlurTransition(active: false, blurRadius: 10)
        )
    }

    static func controlAppear(anchor: UnitPoint) -> AnyTransition {
        .modifier(
            active: ControlTransition(active: true, anchor: anchor),
            identity: ControlTransition(active: false, anchor: anchor)
        )
    }

    static var hintBanner: AnyTransition {
        let blurIn = AnyTransition.modifier(
            active: BlurModifier(radius: 8),
            identity: BlurModifier(radius: 0)
        )
        return .opacity.combined(with: .move(edge: .top)).combined(with: blurIn)
    }
}
