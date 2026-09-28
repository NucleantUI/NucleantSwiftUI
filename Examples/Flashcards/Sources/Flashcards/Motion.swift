//
//  Motion.swift
//  Flashcards
//
//  The app's own animatable pieces — each one a different way of taking
//  part in an animation, rather than only being moved by one:
//
//  * `FlipCard` — an `Animatable` *view*: its body is rebuilt at every
//    angle in between, which is how it can swap faces at the halfway point.
//  * `Shake` — an `AnimatableModifier`: a whole number of shakes in the
//    model, a wobble at every fraction in between.
//  * `ProgressArc` — an animatable `Shape`: its path is redrawn at every
//    fraction, nothing rebuilt.
//  * `CountingText` — a number that counts through the values in between.
//  * `Ticking` — a `CustomAnimation`: an odometer's stepped, slowing roll.
//

import Foundation
import NucleantUI

// MARK: - Flip

/// A card that turns over: squashed towards its edge as `angle` nears 90°,
/// then drawn from the other face as it opens out again.
@View
struct FlipCard: Animatable {
    let card: Card
    /// 0 shows the prompt, 180 the answer.
    var angle: Double

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let showsAnswer = angle >= 90
        // Never quite zero: a zero scale can't be hit or undone.
        let squash = max(abs(cos(angle * .pi / 180)), 0.02)
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(showsAnswer ? Theme.answerCard : Theme.card)
            VStack(spacing: 10) {
                Text(showsAnswer ? "ANSWER" : card.category.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(showsAnswer ? Theme.onAnswer.opacity(0.7) : .secondary)
                Text(showsAnswer ? card.answer : card.prompt)
                    .font(.system(size: showsAnswer ? 30 : 22, weight: showsAnswer ? .bold : .medium))
                    .foregroundColor(showsAnswer ? Theme.onAnswer : .primary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .scaleEffect(x: squash, y: 1)
    }
}

// MARK: - Shake

/// Side to side, three times per unit of `shakes` — so animating it up by
/// one plays one "no".
struct Shake: AnimatableModifier {
    var shakes: Double

    var animatableData: Double {
        get { shakes }
        set { shakes = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(x: sin(shakes * .pi * 6) * 10)
    }
}

// MARK: - Progress

/// The swept part of a ring, from twelve o'clock clockwise.
@View
struct ProgressArc: Shape {
    var progress: Double
    var inset: Double = 0

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: Rect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - inset
        let start = -Double.pi / 2
        return arc(
            center: rect.center,
            radius: radius,
            from: start,
            to: start + min(max(progress, 0), 1) * 2 * .pi
        )
    }
}

/// A circular arc as cubic Béziers — `Path` has no arc primitive.
func arc(center: Point, radius: Double, from start: Double, to end: Double) -> Path {
    var path = Path()
    let sweep = end - start
    guard sweep > 0.0001 else { return path }
    let segments = Int(ceil(sweep / (.pi / 2)))
    let step = sweep / Double(segments)
    let k = 4.0 / 3.0 * tan(step / 4)
    func point(_ a: Double) -> Point {
        Point(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
    }
    path.move(to: point(start))
    for i in 0..<segments {
        let a0 = start + Double(i) * step
        let a1 = a0 + step
        let p0 = point(a0), p3 = point(a1)
        path.addCurve(
            to: p3,
            control1: Point(x: p0.x - k * radius * sin(a0), y: p0.y + k * radius * cos(a0)),
            control2: Point(x: p3.x + k * radius * sin(a1), y: p3.y - k * radius * cos(a1))
        )
    }
    return path
}

// MARK: - Counting

/// A whole number that passes through every value on its way to a new one.
@View
struct CountingText: Animatable {
    var value: Double
    var suffix: String = ""

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))\(suffix)")
    }
}

// MARK: - A custom curve

/// An odometer: the value moves in `ticks` whole steps, quickly at first
/// and slower towards the end, then stops dead.
struct Ticking: CustomAnimation {
    var ticks: Int
    var duration: Double

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time < duration else { return nil }
        // Ease out, then snap down to the last whole tick passed.
        let eased = 1 - pow(1 - time / duration, 3)
        let tick = (eased * Double(ticks)).rounded(.down)
        return value.scaled(by: tick / Double(ticks))
    }
}
