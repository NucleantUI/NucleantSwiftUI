//
//  State.swift
//  NucleantSwiftUI
//

/// A value the view owns and mutates, preserved across rebuilds.
///
/// ```swift
/// struct Counter: View {
///     @State private var count = 0
///     var body: some View {
///         Button("tapped \(count)") { count += 1 }
///     }
/// }
/// ```
@propertyWrapper
@MainActor
public struct State<Value>: DynamicProperty {

    /// The one reference that survives `Mirror`'s copy of the wrapper. Binding
    /// fills in `storage`; `wrappedValue` reads through it.
    final class Holder {
        var storage: StateStorage<Value>?
    }

    private let holder = Holder()
    private let initialValue: () -> Value

    public init(wrappedValue: Value) {
        // Autoclosure-free on purpose: the initial value is only wanted the
        // first time this state slot is created, not on every rebuild.
        self.initialValue = { wrappedValue }
    }

    public init(initialValue: Value) {
        self.init(wrappedValue: initialValue)
    }

    public var wrappedValue: Value {
        get {
            guard let storage = holder.storage else {
                preconditionFailure(
                    "@State read before the view was built. Reading state outside of "
                    + "`body` (in an initializer, say) is not supported."
                )
            }
            // `read()`, not `value`: a read inside a `body` is what registers
            // this view as depending on this state, and so what decides whether
            // a later write has to rebuild it.
            return storage.read()
        }
        nonmutating set {
            guard let storage = holder.storage else {
                preconditionFailure("@State written before the view was built.")
            }
            storage.set(newValue)
        }
    }

    /// `$state` — a two-way binding to this value.
    public var projectedValue: Binding<Value> {
        let holder = self.holder
        return Binding(
            source: holder.storage.map { BindingSource(root: ObjectIdentifier($0), keyPaths: []) },
            get: { chain in
                guard let storage = holder.storage else {
                    preconditionFailure("@State projected before the view was built.")
                }
                return chain.map { storage.read(via: $0) } ?? storage.peek()
            },
            // Through the same setter as `wrappedValue`, so a binding write
            // can't bump the version without invalidating, or vice versa.
            set: { newValue, chain in holder.storage?.set(newValue, via: chain) }
        )
    }

    public func _bind(to context: BindingContext) {
        holder.storage = context.store.slot(for: context.key, initialValue: initialValue)
    }
}

extension State where Value: ExpressibleByNilLiteral {
    public init() {
        self.init(wrappedValue: nil)
    }
}
