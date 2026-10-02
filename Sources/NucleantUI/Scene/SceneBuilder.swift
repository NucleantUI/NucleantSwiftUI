//
//  SceneBuilder.swift
//  NucleantUI
//

/// Constructs scenes from closures. Multi-statement blocks become a
/// `TupleScene`.
@resultBuilder
@MainActor
public struct SceneBuilder {

    public static func buildExpression<Content: Scene>(_ content: Content) -> Content {
        content
    }

    public static func buildBlock<Content: Scene>(_ content: Content) -> Content {
        content
    }

    /// Everything past one scene. Parameter packs cover any arity.
    @_disfavoredOverload
    public static func buildBlock<each Content: Scene>(
        _ content: repeat each Content
    ) -> TupleScene<repeat each Content> {
        TupleScene((repeat each content))
    }
}
