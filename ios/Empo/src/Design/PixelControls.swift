// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

/// A segmented control drawn with pixel corners. The brand knob slides
/// to the selected segment.
struct PixelSegmentedPicker<Value: Hashable>: View {
    let title: LocalizedStringResource
    @Binding var selection: Value
    let options: [(value: Value, label: LocalizedStringResource)]

    @Namespace private var knob

    init(
        _ title: LocalizedStringResource, selection: Binding<Value>,
        options: [(value: Value, label: LocalizedStringResource)]
    ) {
        self.title = title
        _selection = selection
        self.options = options
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                segment(options[index])
            }
        }
        .padding(PixelGrid.step)
        .background(Color(.tertiarySystemFill), in: .pixelRect(cornerRadius: Radius.sm))
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private func segment(_ option: (value: Value, label: LocalizedStringResource)) -> some View {
        let selected = option.value == selection
        return Button {
            withAnimation(Motion.standard) { selection = option.value }
        } label: {
            Text(option.label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background {
                    if selected {
                        PixelRect(cornerRadius: Radius.sm)
                            .fill(Color.brand)
                            .matchedGeometryEffect(id: "knob", in: knob)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An on and off switch drawn with pixel corners, the size of the
/// system switch.
struct PixelToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(Motion.snappy) { configuration.isOn.toggle() }
        } label: {
            HStack {
                configuration.label
                Spacer(minLength: Spacing.md)
                track(isOn: configuration.isOn)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : Alpha.disabled)
        .sensoryFeedback(.selection, trigger: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private func track(isOn: Bool) -> some View {
        PixelRect.pixelCapsule
            .fill(isOn ? Color.brand : Color(.systemFill))
            .frame(width: 51, height: 31)
            .overlay(alignment: isOn ? .trailing : .leading) {
                PixelRect.pixelCapsule
                    .fill(.white)
                    .padding(PixelGrid.step)
                    .frame(width: 31, height: 31)
                    .shadow(color: .black.opacity(Alpha.shadow), radius: 1, y: 1)
            }
    }
}

/// A slider drawn with pixel corners: a 2-pixel track and a pixel knob.
struct PixelSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @State private var editing = false

    private let knob: CGFloat = PixelGrid.step * 9
    private let track: CGFloat = PixelGrid.step * 2

    init(
        value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - knob, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = travel * min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                PixelRect.pixelCapsule
                    .fill(Color(.systemFill))
                    .frame(height: track)
                PixelRect.pixelCapsule
                    .fill(Color.brand)
                    .frame(width: x + knob / 2, height: track)
                PixelRect.pixelCapsule
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(Alpha.shadow), radius: 2, y: 1)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !editing {
                            editing = true
                            onEditingChanged(true)
                        }
                        set(fraction: (drag.location.x - knob / 2) / travel)
                    }
                    .onEnded { _ in
                        editing = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 44)
        .opacity(isEnabled ? 1 : Alpha.disabled)
        .sensoryFeedback(.selection, trigger: value) { _, _ in step != nil }
        .accessibilityRepresentation {
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }

    private func set(fraction: Double) {
        var next = range.lowerBound + min(max(fraction, 0), 1) * (range.upperBound - range.lowerBound)
        if let step {
            next = range.lowerBound + ((next - range.lowerBound) / step).rounded() * step
        }
        if next != value { value = next }
    }
}
