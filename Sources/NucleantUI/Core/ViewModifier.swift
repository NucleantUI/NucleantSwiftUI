//
//  ViewModifier.swift
//  NucleantUI
//

/// A modifier applied to a view to produce a different version of it.
@MainActor @preconcurrency
public protocol ViewModifier {
    associatedtype Body: View
    typealias Content = _ViewModifier_Content<Self>

    @ViewBuilder @MainActor @preconcurrency func body(content: Content) -> Body
}

/// The stand-in a `ViewModifier` receives for the view it wraps.
@View
public struct _ViewModifier_Content<Modifier: ViewModifier>: View {
    let view: AnyView

    init(view: AnyView, _viewID: ViewID = #viewID) {
        self.view = view
        self._viewID = _viewID
    }

    public var body: some View { view }
}

/// A view combined with a modifier.
@View
public struct ModifiedContent<Content: View, Modifier: ViewModifier>: View {
    public var content: Content
    public var modifier: Modifier

    public init(content: Content, modifier: Modifier, _viewID: ViewID = #viewID) {
        self.content = content
        self.modifier = modifier
        self._viewID = _viewID
    }

    public var body: some View {
        modifier.body(content: _ViewModifier_Content<Modifier>(view: AnyView(content)))
    }
}

extension View {
    /// Applies a modifier to this view.
    public func modifier<T: ViewModifier>(_ modifier: T) -> ModifiedContent<Self, T> {
        ModifiedContent(content: self, modifier: modifier)
    }
}
