//
//  Animatable.swift
//  NucleantUI
//
//  The protocols a type adopts to animate its *own* values — SwiftUI's
//  `Animatable` and `VectorArithmetic`. A view, a shape or a view modifier
//  exposes `animatableData`; when a change gives it a new value under an
//  animation, the framework hands it every value in between, one frame at
//  a time: a shape redraws its path at each (no rebuild — see
//  `_ShapeView`), a view or modifier has its body rebuilt at each.
//

import Foundation

// MARK: - VectorArithmetic

/// A value that can be interpolated: added, subtracted and scaled.
public protocol VectorArithmetic: AdditiveArithmetic {
    /// Multiplies each component by `rhs`.
    mutating func scale(by rhs: Double)

    /// The dot product of the value with itself.
    var magnitudeSquared: Double { get }
}

extension VectorArithmetic {
    /// A copy with each component multiplied by `rhs`.
    public func scaled(by rhs: Double) -> Self {
        var copy = self
        copy.scale(by: rhs)
        return copy
    }

    /// `from` moved `fraction` of the way to `to` — 0 is `from`, 1 is `to`,
    /// and outside 0…1 overshoots, as a spring does.
    static func interpolate(from: Self, to: Self, fraction: Double) -> Self {
        from + (to - from).scaled(by: fraction)
    }
}

extension Double: VectorArithmetic {
    public mutating func scale(by rhs: Double) { self *= rhs }
    public var magnitudeSquared: Double { self * self }
}

extension Float: VectorArithmetic {
    public mutating func scale(by rhs: Double) { self *= Float(rhs) }
    public var magnitudeSquared: Double { Double(self * self) }
}

extension CGFloat: VectorArithmetic {
    public mutating func scale(by rhs: Double) { self *= CGFloat(rhs) }
    public var magnitudeSquared: Double { Double(self * self) }
}

/// Two animatable values animated together — how a type with more than one
/// animatable property exposes them as one `animatableData`.
@frozen
public struct AnimatablePair<First: VectorArithmetic, Second: VectorArithmetic>: VectorArithmetic {
    public var first: First
    public var second: Second

    public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }

    public static var zero: Self { Self(.zero, .zero) }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(lhs.first + rhs.first, lhs.second + rhs.second)
    }

    public static func - (lhs: Self, rhs: Self) -> Self {
        Self(lhs.first - rhs.first, lhs.second - rhs.second)
    }

    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
    public static func -= (lhs: inout Self, rhs: Self) { lhs = lhs - rhs }

    public mutating func scale(by rhs: Double) {
        first.scale(by: rhs)
        second.scale(by: rhs)
    }

    public var magnitudeSquared: Double { first.magnitudeSquared + second.magnitudeSquared }
}

extension AnimatablePair: Sendable where First: Sendable, Second: Sendable {}

/// Nothing to animate — the `animatableData` of a type that has none.
@frozen
public struct EmptyAnimatableData: VectorArithmetic, Sendable {
    public init() {}

    public static var zero: Self { Self() }
    public static func + (lhs: Self, rhs: Self) -> Self { lhs }
    public static func - (lhs: Self, rhs: Self) -> Self { lhs }
    public static func += (lhs: inout Self, rhs: Self) {}
    public static func -= (lhs: inout Self, rhs: Self) {}
    public mutating func scale(by rhs: Double) {}
    public var magnitudeSquared: Double { 0 }
}

// MARK: - Animatable

/// A type that animates its own values.
///
/// ```swift
/// @View
/// struct Countdown: Animatable {
///     var value: Double
///     var animatableData: Double {
///         get { value }
///         set { value = newValue }
///     }
///     var body: some View { Text("\(Int(value))") }
/// }
///
/// Countdown(value: done ? 0 : 10)
///     .animation(.linear(duration: 2), value: done)   // 10, 9, 8 … 0
/// ```
///
/// Every `Shape` is `Animatable`; one with nothing to animate gets
/// `EmptyAnimatableData` by default.
@MainActor @preconcurrency
public protocol Animatable {
    associatedtype AnimatableData: VectorArithmetic

    /// The values to interpolate.
    var animatableData: AnimatableData { get set }
}

extension Animatable where AnimatableData == EmptyAnimatableData {
    public var animatableData: EmptyAnimatableData {
        get { EmptyAnimatableData() }
        set {}
    }
}

extension Animatable where Self: VectorArithmetic {
    public var animatableData: Self {
        get { self }
        set { self = newValue }
    }
}

/// A view modifier that animates its own values — SwiftUI's name for
/// `ViewModifier & Animatable`, kept for source compatibility.
@MainActor @preconcurrency
public protocol AnimatableModifier: Animatable, ViewModifier {}

/// A view made with an animatable modifier animates through it.
extension ModifiedContent: Animatable where Modifier: Animatable {
    public var animatableData: Modifier.AnimatableData {
        get { modifier.animatableData }
        set { modifier.animatableData = newValue }
    }
}

// MARK: - Geometry

extension Angle: Animatable {
    public var animatableData: Double {
        get { radians }
        set { radians = newValue }
    }
}

extension Point: Animatable {
    public var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(x, y) }
        set { (x, y) = (newValue.first, newValue.second) }
    }
}

extension Size: Animatable {
    public var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(width, height) }
        set { (width, height) = (newValue.first, newValue.second) }
    }
}

extension Rect: Animatable {
    public var animatableData: AnimatablePair<Point.AnimatableData, Size.AnimatableData> {
        get { AnimatablePair(origin.animatableData, size.animatableData) }
        set {
            origin.animatableData = newValue.first
            size.animatableData = newValue.second
        }
    }
}

extension UnitPoint: Animatable {
    public var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(x, y) }
        set { (x, y) = (newValue.first, newValue.second) }
    }
}

extension EdgeInsets: Animatable {
    public var animatableData: AnimatablePair<Double, AnimatablePair<Double, AnimatablePair<Double, Double>>> {
        get { AnimatablePair(top, AnimatablePair(leading, AnimatablePair(bottom, trailing))) }
        set {
            top = newValue.first
            leading = newValue.second.first
            bottom = newValue.second.second.first
            trailing = newValue.second.second.second
        }
    }
}

// MARK: - Driving animatable data

/// One path's `animatableData` on its way to `target`. Shared by every
/// build of the view at that path, so a change mid-flight turns from where
/// the value is showing.
@MainActor
final class AnimatableDataState<Data: VectorArithmetic> {
    private(set) var target: Data
    private var from: Data
    private var run: AnimationRun?

    init(_ target: Data) {
        self.target = target
        self.from = target
    }

    func update(to newTarget: Data, animation: Animation?, in store: AnimationStore) {
        guard newTarget != target else { return }
        if let animation {
            from = sample(at: store.now).value
            let run = AnimationRun(animation, start: store.now)
            self.run = run
            store.noteStarted(run)
        } else {
            run = nil
        }
        target = newTarget
    }

    /// The value showing at `now`, and whether it has arrived.
    func sample(at now: Double) -> (value: Data, isFinished: Bool) {
        guard let run else { return (target, true) }
        let progress = run.progress(at: now)
        if progress.isFinished {
            self.run = nil
            return (target, true)
        }
        return (Data.interpolate(from: from, to: target, fraction: progress.fraction), false)
    }
}

extension AnimationStore {

    /// `value` with its `animatableData` at what is showing in this frame,
    /// having moved it towards the value just built under `animation`.
    /// `isFinished` is false while it is still on its way.
    func animated<A: Animatable>(
        _ value: A,
        at path: [Int],
        animation: Animation?
    ) -> (value: A, isFinished: Bool) {
        guard A.AnimatableData.self != EmptyAnimatableData.self else { return (value, true) }
        let target = value.animatableData
        let state: AnimatableDataState<A.AnimatableData>
        if let existing = animatableData[path]?.object(as: AnimatableDataState<A.AnimatableData>.self) {
            state = existing
            state.update(to: target, animation: animation, in: self)
        } else {
            state = AnimatableDataState(target)
            animatableData[path] = OpaqueReference(state)
        }
        let sample = state.sample(at: now)
        var shown = value
        shown.animatableData = sample.value
        return (shown, sample.isFinished)
    }
}

extension BuildContext {

    /// A view about to have its body evaluated, as it should show in this
    /// frame: an `Animatable` one with its data part of the way to where
    /// it is going, and its path dirtied for the next frame until it gets
    /// there. Everything else as it is.
    func showing<V: View>(_ view: V) -> V {
        let type = ObjectIdentifier(V.self)
        guard !_AnimatableTypes.inanimate.contains(type) else { return view }
        // A shape animates where it is drawn (`drawnShape`), which needs no
        // rebuild; its body only hands it on.
        guard !(view is any Shape), let animatable = view as? any Animatable else {
            _AnimatableTypes.inanimate.insert(type)
            return view
        }
        return showing(animatable: animatable) as? V ?? view
    }

    private func showing<A: Animatable>(animatable: A) -> A {
        let result = animations.animated(animatable, at: path, animation: transaction.animation)
        if !result.isFinished {
            animations.rebuildNextFrame(path)
        }
        return result.value
    }

    /// A shape's paint for the node being built: the shape itself, or — an
    /// animatable one on its way somewhere — the shape as it stands at the
    /// moment of drawing. No rebuild: the path is simply made again at each
    /// frame's value, and the node asks for the frames it needs.
    func drawnShape<S: Shape>(_ shape: S) -> @MainActor () -> S {
        guard S.AnimatableData.self != EmptyAnimatableData.self else { return { shape } }
        let result = animations.animated(shape, at: path, animation: transaction.animation)
        guard !result.isFinished,
              let state = animations.animatableData[path]?.object(as: AnimatableDataState<S.AnimatableData>.self)
        else { return { shape } }
        return {
            guard let store = AnimationStore.current else { return shape }
            let sample = state.sample(at: store.now)
            if !sample.isFinished { store.requestFrame() }
            var drawn = shape
            drawn.animatableData = sample.value
            return drawn
        }
    }
}

/// View types known to have nothing animatable — asked once per type, like
/// `_ReflectiveBinding` remembers types without dynamic properties.
@MainActor
enum _AnimatableTypes {
    static var inanimate: Set<ObjectIdentifier> = []
}

// MARK: - Type-erased storage

/// A class instance held behind a raw pointer, with its type kept alongside
/// so it can only be taken back out as what it is. How the store keeps
/// values whose type only the call site knows.
@MainActor
final class OpaqueReference {
    private let type: ObjectIdentifier
    private let pointer: UnsafeMutableRawPointer
    private let release: (UnsafeMutableRawPointer) -> Void

    init<T: AnyObject>(_ object: T) {
        type = ObjectIdentifier(T.self)
        pointer = Unmanaged.passRetained(object).toOpaque()
        release = { Unmanaged<T>.fromOpaque($0).release() }
    }

    func object<T: AnyObject>(as _: T.Type) -> T? {
        guard type == ObjectIdentifier(T.self) else { return nil }
        return Unmanaged<T>.fromOpaque(pointer).takeUnretainedValue()
    }

    isolated deinit {
        release(pointer)
    }
}

/// A value of any type held in its own allocation, with its type kept
/// alongside. The value-type counterpart of `OpaqueReference`.
final class OpaqueValue: @unchecked Sendable {
    private let type: ObjectIdentifier
    private let pointer: UnsafeMutableRawPointer
    private let destroy: @Sendable (UnsafeMutableRawPointer) -> Void

    init<T>(_ value: T) {
        type = ObjectIdentifier(T.self)
        let typed = UnsafeMutablePointer<T>.allocate(capacity: 1)
        typed.initialize(to: value)
        pointer = UnsafeMutableRawPointer(typed)
        destroy = { raw in
            let typed = raw.assumingMemoryBound(to: T.self)
            typed.deinitialize(count: 1)
            typed.deallocate()
        }
    }

    func value<T>(as _: T.Type) -> T? {
        guard type == ObjectIdentifier(T.self) else { return nil }
        return pointer.assumingMemoryBound(to: T.self).pointee
    }

    deinit {
        destroy(pointer)
    }
}
