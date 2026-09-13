//
//  ViewID.swift
//  NucleantSwiftUI
//
//  Call-site identity for views, and the `@View` macro that hands it out.
//
//  Structural position (`BuildContext.path`) already tells two *instances*
//  apart — the third row of a `ForEach` from the fourth. It cannot tell two
//  *call sites* apart when they land in the same position: `flag ? Row("a")
//  : Row("b")` builds the same type at the same path either way. `ViewID`
//  is the source location the view was constructed at, and together with the
//  path and the type it is what the builder treats as "the same view" when
//  deciding whether the tree it built last time can be kept.
//

/// Where a view was constructed: file, line and column.
public struct ViewID: Hashable, Sendable {
    public let fileID: String
    public let line: Int
    public let column: Int

    public init(fileID: String, line: Int, column: Int) {
        self.fileID = fileID
        self.line = line
        self.column = column
    }

    /// No call site: a view that was neither stamped by a builder nor made
    /// through a `@View` init. Identity then rests on position and type.
    public static let unknown = ViewID(fileID: "", line: 0, column: 0)
}

/// The identity of the place this is written.
///
/// Meant as a default argument — `_viewID: ViewID = #viewID` — where it is
/// expanded at the *call* site (SE-0422). A plain initializer with `#line`
/// defaults can't do that: nested magic literals name the line they are
/// written on, which for a default argument is the declaration.
@freestanding(expression)
public macro viewID() -> ViewID = #externalMacro(module: "NucleantSwiftUIMacros", type: "ViewIDMacro")

/// Makes a struct an identified, comparable view.
///
/// ```swift
/// @View
/// struct Row {
///     let title: String
///     @Binding var level: Double
///     @State private var expanded = false
///
///     var body: some View { … }
/// }
/// ```
///
/// Generates, from the struct's own declaration, the three members the
/// builder asks every `View` for — the ones a plain `struct S: View` falls
/// back to reflection for:
///
/// * `_viewID`, stored, so `@ViewBuilder` can stamp the call site on it;
/// * `_bindDynamicProperties`, listing the wrappers statically — no `Mirror`;
/// * `_isEquivalent(to:)`, comparing every stored property that is an
///   *input* (`@State` is owned rather than received, and `@Environment` is
///   compared by the builder separately, so both are left out) with the
///   comparison resolved at compile time wherever the type allows.
///
/// When the struct declares no initializer, one is generated with a trailing
/// `_viewID: ViewID = #viewID` parameter, for views constructed outside a
/// builder. A stored closure gets a warning: two values holding closures are
/// never equivalent, so such a view is rebuilt whenever its parent is.
///
/// The builder uses the result like SwiftUI does: when a parent's body re-runs
/// and produces a child that is equivalent to the one already standing at the
/// same position — same type, same identity, same inputs, same environment,
/// and no state it reads has changed — the child's whole subtree is kept and
/// its body is not evaluated.
@attached(extension, conformances: View)
@attached(memberAttribute)
@attached(member, names: named(_viewID), named(_isEquivalent), named(_bindDynamicProperties), named(init))
public macro View() = #externalMacro(module: "NucleantSwiftUIMacros", type: "ViewMacro")
