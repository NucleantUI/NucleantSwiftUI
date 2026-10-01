//
//  Gesture.swift
//  NucleantUI
//
//  The `Gesture` protocol and the gestures that conform to it: `TapGesture`,
//  `LongPressGesture`, `MagnifyGesture`, `RotateGesture`, and `DragGesture`
//  (Gestures.swift). Attaching one is `.gesture`, `.simultaneousGesture` or
//  `.highPriorityGesture` (GestureModifiers.swift); recognizing it is the
//  host's `GestureArena`.
//

import Foundation

/// An input a view recognizes: a tap, a hold, a drag, a pinch, a twist.
///
/// As in SwiftUI, a gesture is a value with its actions attached —
/// `TapGesture(count: 2).onEnded { … }` — handed to a view with
/// `.gesture(_:)`. Unlike SwiftUI's, the gestures here are the five built
/// in; composing them (`simultaneously(with:)`, `sequenced(before:)`) is
/// done by attaching several to the same view instead.
public protocol Gesture {
    /// What the gesture reports as it changes and when it ends.
    associatedtype Value

    /// The recognizer behind this gesture. Framework-internal: what the
    /// host runs when a press reaches the view the gesture is attached to.
    var _recognition: _GestureRecognition { get }
}

/// One of the built-in gestures with its actions, as the host's gesture
/// arena runs it.
public struct _GestureRecognition {
    enum Kind {
        case tap(TapGesture)
        case longPress(LongPressGesture)
        case drag(DragGesture)
        case magnify(MagnifyGesture)
        case rotate(RotateGesture)
    }

    let kind: Kind
}

extension DragGesture: Gesture {
    public var _recognition: _GestureRecognition { _GestureRecognition(kind: .drag(self)) }
}

// MARK: - Tap

/// A gesture that recognizes one or more taps.
///
/// ```swift
/// photo.gesture(
///     TapGesture(count: 2).onEnded { zoomed.toggle() }
/// )
/// ```
///
/// A tap is a press released inside the view without having moved more
/// than a few points. With a `count` above one, the taps must follow each
/// other closely; a single-tap gesture outside a double-tap one on the same
/// view waits until the double tap can no longer happen — attach the
/// double tap first, as in SwiftUI.
public struct TapGesture: Gesture {
    public typealias Value = Void

    /// How many taps it takes.
    public var count: Int

    var endedAction: (@MainActor () -> Void)?
    /// The last tap's location, for `.onTapGesture(count:perform:)`'s
    /// located form — SwiftUI's `SpatialTapGesture` folded in.
    var locatedAction: (@MainActor (Point) -> Void)?

    public init(count: Int = 1) {
        self.count = max(1, count)
    }

    /// Runs `action` when the last tap is released.
    public func onEnded(_ action: @escaping @MainActor () -> Void) -> TapGesture {
        var copy = self
        copy.endedAction = action
        return copy
    }

    public var _recognition: _GestureRecognition { _GestureRecognition(kind: .tap(self)) }
}

// MARK: - Long press

/// A gesture that succeeds once a press has been held for long enough
/// without moving far.
///
/// Its value is whether the press is in progress: `onChanged` reports
/// `true` when the press starts, `onEnded` reports `true` the moment the
/// hold reaches `minimumDuration` — while the press is still down, as in
/// SwiftUI.
public struct LongPressGesture: Gesture {
    public typealias Value = Bool

    /// Seconds the press must be held.
    public var minimumDuration: Double
    /// Points the press may wander before it fails.
    public var maximumDistance: Double

    var changedAction: (@MainActor (Bool) -> Void)?
    var endedAction: (@MainActor (Bool) -> Void)?
    /// `.onLongPressGesture`'s `onPressingChanged` — `true` when the press
    /// starts, `false` when it ends, however it ends.
    var pressingAction: (@MainActor (Bool) -> Void)?

    public init(minimumDuration: Double = 0.5, maximumDistance: Double = 10) {
        self.minimumDuration = minimumDuration
        self.maximumDistance = maximumDistance
    }

    public func onChanged(_ action: @escaping @MainActor (Bool) -> Void) -> LongPressGesture {
        var copy = self
        copy.changedAction = action
        return copy
    }

    public func onEnded(_ action: @escaping @MainActor (Bool) -> Void) -> LongPressGesture {
        var copy = self
        copy.endedAction = action
        return copy
    }

    public var _recognition: _GestureRecognition { _GestureRecognition(kind: .longPress(self)) }
}

// MARK: - Magnify

/// A pinch: two fingers moving apart or together, or a trackpad pinch.
///
/// ```swift
/// image
///     .scaleEffect(scale * pinch)
///     .gesture(
///         MagnifyGesture()
///             .onChanged { value in pinch = value.magnification }
///             .onEnded { value in scale *= value.magnification; pinch = 1 }
///     )
/// ```
public struct MagnifyGesture: Gesture {

    public struct Value: Equatable, Sendable {
        /// When this value was reported.
        public var time: Date
        /// The scale since the gesture began — 1 is unchanged, 2 is twice
        /// as far apart.
        public var magnification: Double
        /// How fast `magnification` is changing, per second.
        public var velocity: Double
        /// Where the gesture began, as a fraction of the view's size.
        public var startAnchor: UnitPoint
        /// Where the gesture began, in the view's own coordinates: the
        /// point between the two fingers, or the pointer for a trackpad.
        public var startLocation: Point
    }

    /// How far the scale must move from 1 before the gesture starts
    /// reporting.
    public var minimumScaleDelta: Double

    var changedAction: (@MainActor (Value) -> Void)?
    var endedAction: (@MainActor (Value) -> Void)?

    public init(minimumScaleDelta: Double = 0.01) {
        self.minimumScaleDelta = minimumScaleDelta
    }

    public func onChanged(_ action: @escaping @MainActor (Value) -> Void) -> MagnifyGesture {
        var copy = self
        copy.changedAction = action
        return copy
    }

    public func onEnded(_ action: @escaping @MainActor (Value) -> Void) -> MagnifyGesture {
        var copy = self
        copy.endedAction = action
        return copy
    }

    public var _recognition: _GestureRecognition { _GestureRecognition(kind: .magnify(self)) }
}

// MARK: - Rotate

/// A twist: two fingers turning around each other, or a trackpad rotation.
///
/// ```swift
/// card
///     .rotationEffect(angle + twist)
///     .gesture(
///         RotateGesture()
///             .onChanged { value in twist = value.rotation }
///             .onEnded { value in angle += value.rotation; twist = .zero }
///     )
/// ```
public struct RotateGesture: Gesture {

    public struct Value: Equatable, Sendable {
        /// When this value was reported.
        public var time: Date
        /// The turn since the gesture began, clockwise positive — the same
        /// sense as `.rotationEffect`.
        public var rotation: Angle
        /// How fast `rotation` is changing, per second.
        public var velocity: Angle
        /// Where the gesture began, as a fraction of the view's size.
        public var startAnchor: UnitPoint
        /// Where the gesture began, in the view's own coordinates.
        public var startLocation: Point
    }

    /// How far the turn must go before the gesture starts reporting.
    public var minimumAngleDelta: Angle

    var changedAction: (@MainActor (Value) -> Void)?
    var endedAction: (@MainActor (Value) -> Void)?

    public init(minimumAngleDelta: Angle = .degrees(1)) {
        self.minimumAngleDelta = minimumAngleDelta
    }

    public func onChanged(_ action: @escaping @MainActor (Value) -> Void) -> RotateGesture {
        var copy = self
        copy.changedAction = action
        return copy
    }

    public func onEnded(_ action: @escaping @MainActor (Value) -> Void) -> RotateGesture {
        var copy = self
        copy.endedAction = action
        return copy
    }

    public var _recognition: _GestureRecognition { _GestureRecognition(kind: .rotate(self)) }
}
