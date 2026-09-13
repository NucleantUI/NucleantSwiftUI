//
//  View.swift
//  NucleantSwiftUI
//

/// The core view protocol — the same shape as SwiftUI's and SDLUI's.
///
/// Views are value types. `SwiftNucleatUI`'s earlier attempt made `View`
/// class-bound; that breaks `@ViewBuilder` ergonomics (every literal becomes an
/// allocation with reference identity) and makes structural identity — which is
/// what `@State` storage is keyed on — impossible to derive from position.
@MainActor @preconcurrency
public protocol View: ViewInput {
    /// The type of view representing the body of this view.
    associatedtype Body: View

    /// The content and behavior of the view. Primitive views declare
    /// `Body == Never` and are never asked for it.
    @ViewBuilder @MainActor @preconcurrency var body: Body { get }

    // The three things the builder needs from a view besides its body. `@View`
    // generates all of them from the struct's declaration; a plain
    // `struct S: View` gets the defaults below, which work the same way but
    // through reflection. The builder calls these directly — there is no
    // separate fast path and slow path, only cheap witnesses and dear ones.

    /// Where this view was written. Settable because the call site is
    /// stamped from outside: `@ViewBuilder` sees every view expression in a
    /// body and knows the line it sits on, which no initializer can.
    var _viewID: ViewID { get set }

    /// Bind every `@State` / `@Binding` / `@Environment` on this view.
    func _bindDynamicProperties(_ binder: DynamicPropertyBinder)
}

extension View {
    /// Type-only identity: the builder tells views apart by position and
    /// type, and this adds nothing. `@View` replaces it with stored, stamped
    /// identity.
    public var _viewID: ViewID {
        get { .unknown }
        set {}
    }

    /// Reflection: walk the stored properties for wrappers. `Mirror` hands
    /// back *copies* of the wrappers, which is fine — each holds a reference
    /// to its own holder object, and that reference is what the copy shares
    /// with the original. Types that turn out to have nothing are remembered,
    /// so the walk is paid once per type rather than once per build.
    public func _bindDynamicProperties(_ binder: DynamicPropertyBinder) {
        let type = ObjectIdentifier(Self.self)
        if _ReflectiveBinding.typesWithoutDynamicProperties.contains(type) { return }
        var found = false
        var index = 0
        for child in Mirror(reflecting: self).children {
            defer { index += 1 }
            guard let property = child.value as? DynamicProperty else { continue }
            found = true
            binder.bind(property, index: index)
        }
        if !found {
            _ReflectiveBinding.typesWithoutDynamicProperties.insert(type)
        }
    }

    /// Runtime equivalence — `Equatable` if the type is, a field walk
    /// otherwise. `@View` replaces it with a field-by-field function that
    /// needs neither cast nor `Mirror`.
    public func _isEquivalent(to other: Self) -> Bool {
        _equatableOrStructurallyEquivalent(self, other)
    }
}

@MainActor
enum _ReflectiveBinding {
    static var typesWithoutDynamicProperties: Set<ObjectIdentifier> = []
}

// MARK: - Never as a View

extension Never: View {
    public var body: Never { fatalError("Never has no body") }
}

extension View where Body == Never {
    public var body: Never {
        preconditionFailure("body should not be called on the primitive view \(Self.self).")
    }
}

/// A view the framework knows how to lay out and draw directly, instead of by
/// evaluating `body`. This is the erasure seam: everything the renderer
/// understands is a `BuiltinView`, and everything else reduces to one by
/// recursion through `body`.
///
/// Kept internal — third-party views compose builtins rather than adding to
/// them, exactly as in SwiftUI.
@MainActor
protocol BuiltinView {
    /// Build this view's layout node. `context` carries the traversal state
    /// the node needs: environment values and the identity path `@State`
    /// storage is keyed on.
    func makeNode(_ context: inout BuildContext) -> ViewNode
}
