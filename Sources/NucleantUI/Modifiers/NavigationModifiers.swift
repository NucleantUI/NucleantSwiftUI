//
//  NavigationModifiers.swift
//  NucleantUI
//
//  Both file something with the enclosing `NavigationStack` while they
//  build, through the router in the environment — the stack reads it back
//  when it builds its screens and its bar.
//

extension View {

    /// Shows values of type `D` pushed onto the enclosing stack as
    /// `destination(value)`.
    ///
    /// ```swift
    /// List…
    ///     .navigationDestination(for: Recipe.self) { recipe in
    ///         RecipeDetail(recipe: recipe)
    ///     }
    /// ```
    ///
    /// Put it on the stack's root or on a screen below the ones it serves:
    /// screens are built bottom first, so a destination declared on a
    /// screen above isn't known yet when one below it is resolved.
    public func navigationDestination<D: Hashable, C: View>(
        for data: D.Type,
        @ViewBuilder destination: @escaping (D) -> C
    ) -> some View {
        // No key: the closure can't be compared, so this re-registers every
        // time its parent re-runs, and the stack always resolves with the
        // latest one.
        _ModifierView(content: self) { context in
            context.environment.navigationRouter?.storage.register(D.self) { value in
                AnyView(destination(value))
            }
            return EnvironmentContent(colorScheme: context.environment.colorScheme)
        }
    }

    /// The title the enclosing stack's bar shows while this view's screen
    /// is on top.
    public func navigationTitle<S: StringProtocol>(_ title: S) -> some View {
        navigationTitle(String(title))
    }

    public func navigationTitle(_ title: Text) -> some View {
        navigationTitle(title.content)
    }

    private func navigationTitle(_ title: String) -> some View {
        _ModifierView(content: self, key: ["navigationTitle", title] as [AnyHashable]) { context in
            if let router = context.environment.navigationRouter,
               let screen = context.environment.navigationScreen {
                router.storage.setTitle(title, for: screen)
            }
            return EnvironmentContent(colorScheme: context.environment.colorScheme)
        }
    }
}
