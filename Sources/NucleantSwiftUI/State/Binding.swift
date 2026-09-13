//
//  Binding.swift
//  NucleantSwiftUI
//

/// A two-way reference to a value owned elsewhere — what `$state` produces and
/// what a child view takes when it needs to write back.
@propertyWrapper
@dynamicMemberLookup
@MainActor
public struct Binding<Value>: DynamicProperty {

    /// Read the value. The chain is the full key path of the *outermost*
    /// binding, handed down unchanged so the slot at the root records the
    /// read at that granularity; `nil` reads without recording, for a
    /// write's read-modify-write.
    private let rawGet: ([AnyKeyPath]?) -> Value
    /// Write the value, again carrying the outermost binding's chain down to
    /// the slot so it can dirty only the readers that overlap it.
    private let rawSet: (Value, [AnyKeyPath]) -> Void

    /// What this binding points at, when the framework can tell: the `@State`
    /// slot it was projected from, and the key paths walked since. Two
    /// bindings with the same source are the same input to a view, whatever
    /// their closures look like — see `ViewInput`. A binding built from raw
    /// closures has no source and never counts as equivalent.
    let source: BindingSource?

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.rawGet = { _ in get() }
        self.rawSet = { newValue, _ in set(newValue) }
        self.source = nil
    }

    init(
        source: BindingSource?,
        get: @escaping ([AnyKeyPath]?) -> Value,
        set: @escaping (Value, [AnyKeyPath]) -> Void
    ) {
        self.rawGet = get
        self.rawSet = set
        self.source = source
    }

    /// A binding that ignores writes — for previews and constant inputs.
    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }

    private var chain: [AnyKeyPath] { source?.keyPaths ?? [] }

    public var wrappedValue: Value {
        get { rawGet(chain) }
        nonmutating set { rawSet(newValue, chain) }
    }

    /// `$binding` on a binding is the binding itself, so it can be forwarded
    /// down another level.
    public var projectedValue: Binding<Value> { self }

    /// A binding to one property of the bound value — `$model.name`.
    public subscript<Subject>(
        dynamicMember keyPath: WritableKeyPath<Value, Subject>
    ) -> Binding<Subject> {
        let rawGet = self.rawGet
        let rawSet = self.rawSet
        return Binding<Subject>(
            source: source?.appending(keyPath),
            get: { chain in rawGet(chain)[keyPath: keyPath] },
            set: { newValue, chain in
                var copy = rawGet(nil)
                copy[keyPath: keyPath] = newValue
                rawSet(copy, chain)
            }
        )
    }

    /// Nothing to wire up — a binding carries its own closures.
    public func _bind(to context: BindingContext) {}
}

extension Binding: @preconcurrency Equatable where Value: Equatable {
    public static func == (lhs: Binding<Value>, rhs: Binding<Value>) -> Bool {
        lhs.wrappedValue == rhs.wrappedValue
    }
}

/// The state slot a binding was projected from plus the key paths applied to
/// it since — `$tracks[3].level` is `(tracks slot, [\.[3], \.level])`.
struct BindingSource: Hashable {
    let root: ObjectIdentifier
    let keyPaths: [AnyKeyPath]

    func appending(_ keyPath: AnyKeyPath) -> BindingSource {
        BindingSource(root: root, keyPaths: keyPaths + [keyPath])
    }
}
