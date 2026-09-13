//
//  DynamicProperty.swift
//  NucleantSwiftUI
//

/// A property of a view that the framework has to wire up before the view's
/// `body` runs — `@State` needs its storage from the state store, `@Environment`
/// needs the current environment.
///
/// Views are structs rebuilt from scratch on every pass, so a property wrapper
/// can't carry state in its own stored fields. Each wrapper instead holds a
/// small reference *holder*, which survives being copied out of a `Mirror`;
/// binding writes into that holder, and `wrappedValue` reads back through it.
@MainActor
public protocol DynamicProperty {
    func _bind(to context: BindingContext)
}

/// Everything a dynamic property may need at bind time.
@MainActor
public struct BindingContext {
    let store: StateStore
    let key: StateKey
    let environment: EnvironmentValues

    init(store: StateStore, key: StateKey, environment: EnvironmentValues) {
        self.store = store
        self.key = key
        self.environment = environment
    }
}

/// Hands each dynamic property of one view its `BindingContext`, and keeps
/// the keys it made so the view's record can release them later.
///
/// `@View`'s generated `_bindDynamicProperties` calls `bind` once per wrapped
/// property, with the property's ordinal among the struct's stored
/// properties — the same number `Mirror` would have produced, so a view's
/// state keys do not change with how it was bound.
@MainActor
public struct DynamicPropertyBinder {
    let store: StateStore
    let environment: EnvironmentValues
    let path: [Int]
    let viewType: ObjectIdentifier
    let viewID: ViewID

    /// Collected as `bind` is called; a class so the generated code needs no
    /// `inout` plumbing.
    final class Keys {
        var keys: [StateKey] = []
    }
    let keys = Keys()

    public func bind<P: DynamicProperty>(_ property: P, index: Int) {
        let key = StateKey(path: path, propertyIndex: index, viewType: viewType, viewID: viewID)
        keys.keys.append(key)
        property._bind(to: BindingContext(store: store, key: key, environment: environment))
    }

    /// A wrapped property that is not a dynamic property — a user's own
    /// wrapper — needs nothing from the framework. The overload exists so the
    /// macro can emit a `bind` for every wrapper without knowing which are.
    public func bind<P>(_ property: P, index: Int) {}

    /// For the reflective default, which only has the existential.
    func bind(_ property: any DynamicProperty, index: Int) {
        let key = StateKey(path: path, propertyIndex: index, viewType: viewType, viewID: viewID)
        keys.keys.append(key)
        property._bind(to: BindingContext(store: store, key: key, environment: environment))
    }
}

/// Where a piece of `@State` lives: the structural position of the view that
/// declared it, plus which of its properties it is.
///
/// Structural — not object — identity, because views are values. The same
/// position in the same shape of tree is the same view across rebuilds, which
/// is exactly SwiftUI's rule.
public struct StateKey: Hashable, Sendable {
    /// The structural path of the view that declared the state — also the
    /// subtree a write to it invalidates.
    let path: [Int]
    let propertyIndex: Int
    /// The view's metatype. Only ever compared, never printed, so the
    /// identity of the type is enough — `String(reflecting:)` was the last
    /// reflective call on the build path.
    let viewType: ObjectIdentifier
    /// The call site (`ViewID.unknown` when there is none). Two constructions
    /// of the same type at the same position are still different views if
    /// they were written in different places.
    let viewID: ViewID

    init(path: [Int], propertyIndex: Int, viewType: ObjectIdentifier, viewID: ViewID = .unknown) {
        self.path = path
        self.propertyIndex = propertyIndex
        self.viewType = viewType
        self.viewID = viewID
    }
}
