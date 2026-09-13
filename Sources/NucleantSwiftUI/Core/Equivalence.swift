//
//  Equivalence.swift
//  NucleantSwiftUI
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
/// Every `View` is one (`@View` generates the witness, the protocol default
/// reflects); property wrappers and a few framework types conform by hand.
/// Anything else falls back to `Equatable` where available and to a
/// structural walk otherwise.
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
    return _equatableOrStructurallyEquivalent(a, b)
}

/// The part after `ViewInput` — what a `View` without a generated witness
/// falls back to. Kept separate so that default cannot call itself.
@MainActor
func _equatableOrStructurallyEquivalent(_ a: Any, _ b: Any) -> Bool {
    if let a = a as? any Equatable {
        return _openEquatable(a, b)
    }
    return _structurallyEquivalent(a, b)
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

/// Field-by-field through `Mirror`, for plain structs, tuples, optionals and
/// collections that declare nothing. Stops at the first difference.
///
/// What it refuses to decide: closures and classes (no `Mirror` children to
/// speak of, and a class can mutate underneath), and enums without payloads —
/// their `Mirror` is empty, so two different cases would look identical.
@MainActor
private func _structurallyEquivalent(_ a: Any, _ b: Any) -> Bool {
    let ma = Mirror(reflecting: a)
    let mb = Mirror(reflecting: b)
    switch ma.displayStyle {
    case .struct, .tuple, .optional, .collection, .set:
        guard ma.children.count == mb.children.count else { return false }
        for (x, y) in zip(ma.children, mb.children) {
            guard _dynamicallyEquivalent(x.value, y.value) else { return false }
        }
        return true
    case .enum:
        // A payload case shows as one child labelled with the case name; a
        // bare case shows nothing at all, and is left to `Equatable`.
        guard let x = ma.children.first, let y = mb.children.first, x.label == y.label else {
            return false
        }
        return _dynamicallyEquivalent(x.value, y.value)
    default:
        return false
    }
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

extension _ConditionalContent {
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

extension ModifiedContent {
    public func _isEquivalent(to other: ModifiedContent<Content, Modifier>) -> Bool {
        _areEquivalent(content, other.content) && _areEquivalent(modifier, other.modifier)
    }
}

// The rest carry closures, so there is nothing to compare — and saying so
// outright is cheaper than having `Mirror` discover it.

extension AnyView {
    public func _isEquivalent(to other: AnyView) -> Bool { false }
}

extension _ViewModifier_Content {
    public func _isEquivalent(to other: _ViewModifier_Content<Modifier>) -> Bool { false }
}

extension ForEach {
    public func _isEquivalent(to other: ForEach<Data, ID, Content>) -> Bool { false }
}

extension Button {
    public func _isEquivalent(to other: Button<Label>) -> Bool { false }
}

extension NavigationLink {
    public func _isEquivalent(to other: NavigationLink<Label, Destination>) -> Bool { false }
}
