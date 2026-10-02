//
//  Equivalence.swift
//  NucleantUI
//
//  "Would this view build the same tree as that one?" — the question behind
//  reusing a subtree instead of rebuilding it.
//
//  Equality is the wrong tool: a `Binding` is two closures, a `Button` holds
//  an action, and neither has a meaningful `==`. *Equivalence* is the weaker
//  claim the builder actually needs — same inputs from the view's point of
//  view. A binding is equivalent to another that points at the same state; a
//  closure is never equivalent to anything, because there is no way to tell.
//  Getting it wrong in the "equivalent" direction shows stale UI, so every
//  undecidable case answers no.
//

/// A type whose values can be compared for equivalence as view inputs.
///
/// Every `View` is one (`@View` generates the witness; a primitive without
/// one compares by `Equatable`); property wrappers and a few framework types
/// conform by hand. Anything else falls back to `Equatable` where available
/// and is otherwise not equivalent — there is no reflection.
@MainActor
public protocol ViewInput {
    func _isEquivalent(to other: Self) -> Bool
}

// MARK: - Comparing two inputs

// Four overloads, so the generated `_isEquivalent` can write one call per
// property and let the compiler pick: the static path when the type is known
// to be `Equatable` or `ViewInput`, the dynamic one otherwise. The doubly
// constrained overload exists only to break the tie for a type that is both.

@MainActor
public func _areEquivalent<T: Equatable>(_ a: T, _ b: T) -> Bool {
    a == b
}

@MainActor
public func _areEquivalent<T: ViewInput>(_ a: T, _ b: T) -> Bool {
    a._isEquivalent(to: b)
}

@MainActor
public func _areEquivalent<T: Equatable & ViewInput>(_ a: T, _ b: T) -> Bool {
    a._isEquivalent(to: b)
}

@MainActor
public func _areEquivalent<T>(_ a: T, _ b: T) -> Bool {
    _dynamicallyEquivalent(a, b)
}

/// The runtime answer for a value whose static type says nothing.
///
/// Order matters: `ViewInput` first, so a `Binding` compares by source and
/// not through its `Equatable` conformance (which reads the value — and two
/// bindings onto the same slot always read the same value, changed or not).
@MainActor
func _dynamicallyEquivalent(_ a: Any, _ b: Any) -> Bool {
    guard type(of: a) == type(of: b) else { return false }
    if let a = a as? any ViewInput {
        return _openViewInput(a, b)
    }
    // The same object is the same input: what a view reads *from* it is
    // tracked by observation, so a change inside it dirties the readers
    // without the reference having to look different. A different object
    // is a different input, whatever its contents.
    if type(of: a) is AnyClass {
        return (a as AnyObject) === (b as AnyObject)
    }
    // Nothing that says how to compare it: undecidable, so not equivalent.
    // A type that should compare declares `Equatable`.
    if let a = a as? any Equatable {
        return _openEquatable(a, b)
    }
    return false
}

@MainActor
private func _openViewInput<T: ViewInput>(_ a: T, _ b: Any) -> Bool {
    guard let b = b as? T else { return false }
    return a._isEquivalent(to: b)
}

private func _openEquatable<T: Equatable>(_ a: T, _ b: Any) -> Bool {
    guard let b = b as? T else { return false }
    return a == b
}

// MARK: - Property wrappers

extension State: ViewInput {
    /// Owned, not received: the value lives in the store and a write to it
    /// dirties this view directly. As an *input* it never changes.
    public func _isEquivalent(to other: State<Value>) -> Bool { true }
}

extension Environment: ViewInput {
    /// The environment is compared by the builder before it ever asks about
    /// the view's own fields.
    public func _isEquivalent(to other: Environment<Value>) -> Bool { true }
}

extension Binding: ViewInput {
    /// Same source — the same state slot through the same key path. Not the
    /// same *value*: whether the value changed is tracked separately, by the
    /// reads the view made through this binding when its body last ran.
    public func _isEquivalent(to other: Binding<Value>) -> Bool {
        guard let source, let otherSource = other.source else { return false }
        return source == otherSource
    }
}

// MARK: - Structural views

extension TupleView {
    public func _isEquivalent(to other: TupleView<repeat each T>) -> Bool {
        for (a, b) in repeat (each value, each other.value) {
            guard _areEquivalent(a, b) else { return false }
        }
        return true
    }
}

extension _ViewArray {
    public func _isEquivalent(to other: _ViewArray<Content>) -> Bool {
        guard elements.count == other.elements.count else { return false }
        for (a, b) in zip(elements, other.elements) {
            guard _areEquivalent(a, b) else { return false }
        }
        return true
    }
}

extension _ConditionalContent where TrueContent: View, FalseContent: View {
    public func _isEquivalent(to other: _ConditionalContent<TrueContent, FalseContent>) -> Bool {
        switch (storage, other.storage) {
        case (.trueContent(let a), .trueContent(let b)):
            return _areEquivalent(a, b)
        case (.falseContent(let a), .falseContent(let b)):
            return _areEquivalent(a, b)
        default:
            return false
        }
    }
}

extension Optional where Wrapped: View {
    @MainActor
    public func _isEquivalent(to other: Wrapped?) -> Bool {
        switch (self, other) {
        case (.some(let a), .some(let b)):
            return _areEquivalent(a, b)
        case (.none, .none):
            return true
        default:
            return false
        }
    }
}

// The rest carry closures, so there is nothing to compare.

extension AnyView {
    public func _isEquivalent(to other: AnyView) -> Bool { false }
}

extension ForEach {
    public func _isEquivalent(to other: ForEach<Data, ID, Content>) -> Bool { false }
}
