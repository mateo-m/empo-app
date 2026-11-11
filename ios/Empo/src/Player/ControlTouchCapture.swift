// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

/// A `DragGesture(minimumDistance: 0)` shares the SwiftUI gesture graph
/// with the edit-mode recognizers, and the graph holds a touch back
/// until it can tell a tap from a drag. Then a tap sends its press and
/// release in one engine frame, and RGSS `Input.update` does not see
/// it. Raw UIKit touches have no such delay. UIKit also sends the full
/// touch sequence to the view that got its begin, also after the
/// finger leaves the bounds.
struct ControlTouchCapture: UIViewRepresentable {
    /// The hit shape of each control. Touches on the corners of the
    /// frame go to the views below.
    static let hitShape = Circle()

    /// Edit mode toggles inside `withAnimation`. A layer removed with
    /// an `if` fades out, takes touches during the fade, and can lose
    /// the touch end when SwiftUI removes it. `isUserInteractionEnabled`
    /// does not animate, so this flag stops touches at once.
    var enabled: Bool
    var onBegan: (Int, CGPoint) -> Void
    var onMoved: (Int, CGPoint) -> Void
    /// `idle` reports that this finger was the last one on the
    /// control, which is where a button releases its key.
    var onEnded: (Int, _ idle: Bool) -> Void

    func makeUIView(context: Context) -> ControlTouchCaptureView {
        let view = ControlTouchCaptureView()
        apply(to: view)
        return view
    }

    func updateUIView(_ view: ControlTouchCaptureView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: ControlTouchCaptureView) {
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.setEnabled(enabled)
    }
}

final class ControlTouchCaptureView: UIView {
    var onBegan: ((Int, CGPoint) -> Void)?
    var onMoved: ((Int, CGPoint) -> Void)?
    var onEnded: ((Int, Bool) -> Void)?

    private var touchSet = ControlTouchSet<Int>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// UIKit does not always send `touchesCancelled` to a view that
    /// stops getting events during a sequence.
    func setEnabled(_ enabled: Bool) {
        guard isUserInteractionEnabled != enabled else { return }
        isUserInteractionEnabled = enabled
        if !enabled {
            cancelActiveTouches()
        }
    }

    /// UIKit does not send the touch end to a view that left the
    /// window.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            cancelActiveTouches()
        }
    }

    /// Ends each live touch as a lift does, the oldest first.
    private func cancelActiveTouches() {
        let abandoned = touchSet.reset()
        for (index, id) in abandoned.enumerated() {
            onEnded?(id, index == abandoned.count - 1)
        }
    }

    /// UIKit keeps one `UITouch` object for each finger while it is
    /// down. An `Int` is safe to keep after UIKit uses the object again.
    private static func identifier(of touch: UITouch) -> Int {
        Int(bitPattern: ObjectIdentifier(touch))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        ControlTouchCapture.hitShape.path(in: bounds).contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        dropVanishedTouches(in: event)
        for touch in touches {
            let id = Self.identifier(of: touch)
            _ = touchSet.begin(id)
            onBegan?(id, touch.location(in: self))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        dropVanishedTouches(in: event)
        for touch in touches {
            let id = Self.identifier(of: touch)
            guard touchSet.isTracking(id) else { continue }
            onMoved?(id, touch.location(in: self))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTracked(touches)
        dropVanishedTouches(in: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTracked(touches)
        dropVanishedTouches(in: event)
    }

    private func endTracked(_ touches: Set<UITouch>) {
        for touch in touches {
            let id = Self.identifier(of: touch)
            // UIKit can send touchesEnded and then touchesCancelled
            // for one touch.
            let outcome = touchSet.end(id)
            guard outcome != .notTracked else { continue }
            onEnded?(id, outcome == .idle)
        }
    }

    /// UIKit can lose a `touchesEnded`. The event holds each touch in
    /// the window with its phase, so a tracked finger that is not in it,
    /// or that ended in it, is gone. A nil `allTouches` does not mean
    /// "no fingers".
    private func dropVanishedTouches(in event: UIEvent?) {
        guard let allTouches = event?.allTouches else { return }
        let stillDown = Set(
            allTouches
                .filter { $0.phase != .ended && $0.phase != .cancelled }
                .map(Self.identifier(of:))
        )
        for id in touchSet.live where !stillDown.contains(id) {
            let outcome = touchSet.end(id)
            onEnded?(id, outcome == .idle)
        }
    }
}
