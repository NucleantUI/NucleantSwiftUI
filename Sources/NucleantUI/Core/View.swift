//
//  View.swift
//  NucleantUI
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
    // generates all of them from the struct's declaration; only primitives
    // (`Body == Never`) get defaults, below. The builder calls these directly.

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
}

/// A primitive — `Body == Never`, drawn by the framework — holds no
/// `@State` or other dynamic property, and compares by `Equatable` when it
/// is that, else as never equivalent. A view with a body has no default: it
/// gets both from `@View`, and without `@View` it does not compile.
extension View where Body == Never {
    public func _bindDynamicProperties(_ binder: DynamicPropertyBinder) {}

    public func _isEquivalent(to other: Self) -> Bool { false }
}

extension View where Body == Never, Self: Equatable {
    public func _isEquivalent(to other: Self) -> Bool { self == other }
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
