//
//  ViewBuilder.swift
//  NucleantSwiftUI
//

/// Constructs views from closures. Multi-statement blocks become a
/// `TupleView`; `if`/`else` becomes `_ConditionalContent`; a bare `if` becomes
/// an `Optional`.
@resultBuilder
@MainActor
public struct ViewBuilder {

    /// Every view expression in a body passes through here, and the implicit
    /// call sits on the expression — so this is the one place a view's call
    /// site is actually known, whatever initializer it went through. A
    /// `@View` struct stores it; the default setter on a plain `View` drops
    /// it, and that view is then identified by type and position alone.
    public static func buildExpression<Content: View>(
        _ content: Content,
        fileID: String = #fileID,
        line: Int = #line,
        column: Int = #column
    ) -> Content {
        var content = content
        content._viewID = ViewID(fileID: fileID, line: line, column: column)
        return content
    }

    public static func buildBlock() -> EmptyView {
        EmptyView()
    }

    public static func buildBlock<Content: View>(_ content: Content) -> Content {
        content
    }

    /// Everything past one child. Parameter packs cover any arity, so there is
    /// no 10-view ceiling the way there was before variadic generics.
    @_disfavoredOverload
    public static func buildBlock<each Content: View>(
        _ content: repeat each Content
    ) -> TupleView<repeat each Content> {
        TupleView((repeat each content))
    }

    public static func buildOptional<Content: View>(_ content: Content?) -> Content? {
        content
    }

    public static func buildIf<Content: View>(_ content: Content?) -> Content? {
        content
    }

    public static func buildEither<TrueContent: View, FalseContent: View>(
        first: TrueContent
    ) -> _ConditionalContent<TrueContent, FalseContent> {
        .init(storage: .trueContent(first))
    }

    public static func buildEither<TrueContent: View, FalseContent: View>(
        second: FalseContent
    ) -> _ConditionalContent<TrueContent, FalseContent> {
        .init(storage: .falseContent(second))
    }

    public static func buildArray<Content: View>(_ components: [Content]) -> _ViewArray<Content> {
        _ViewArray(components)
    }

    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView {
        AnyView(content)
    }
}
