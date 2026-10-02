//
//  NavigationModifiers.swift
//  NucleantUI
//
//  Each files something with the enclosing `NavigationStack` while it
//  builds, through the router in the environment — the stack reads it back
//  when it builds its screens and its bar.
//

/// A bar a container draws, for `.toolbarVisibility(_:for:)` to name.
public struct ToolbarPlacement: Hashable, Sendable {
    enum Bar: Hashable, Sendable {
        case automatic
        case navigationBar
    }

    let bar: Bar

    /// The container's main bar — inside a `NavigationStack`, its
    /// navigation bar.
    public static let automatic = ToolbarPlacement(bar: .automatic)

    /// The bar across the top of a `NavigationStack`: the title and the
    /// back button.
    public static let navigationBar = ToolbarPlacement(bar: .navigationBar)
}

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

    /// Shows or hides the enclosing stack's bar while this view's screen is
    /// on top.
    ///
    /// ```swift
    /// PhotoViewer(photo: photo)
    ///     .toolbarVisibility(isImmersive ? .hidden : .visible, for: .navigationBar)
    /// ```
    ///
    /// The screen gets the stack's whole height while the bar is hidden.
    /// The back button goes with it, so give the screen its own way back
    /// (`navigationRouter.pop()`). No `bars` means `.automatic`, and
    /// `.automatic` visibility shows the bar. Other screens keep their own
    /// setting: hiding the bar on a pushed screen brings it back when that
    /// screen is popped.
    public func toolbarVisibility(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View {
        navigationBarVisibility(visibility, for: bars)
    }

    /// The name `toolbarVisibility(_:for:)` had before SwiftUI renamed it.
    public func toolbar(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View {
        navigationBarVisibility(visibility, for: bars)
    }

    private func navigationBarVisibility(_ visibility: Visibility, for bars: [ToolbarPlacement]) -> some View {
        let bars = bars.isEmpty ? [.automatic] : bars
        // A stack draws one bar, which both placements name.
        let appliesToStack = bars.contains(.automatic) || bars.contains(.navigationBar)
        return _ModifierView(content: self, key: ["toolbarVisibility", visibility, bars] as [AnyHashable]) { context in
            if appliesToStack,
               let router = context.environment.navigationRouter,
               let screen = context.environment.navigationScreen {
                router.storage.setBarVisibility(visibility, for: screen)
            }
            return EnvironmentContent(colorScheme: context.environment.colorScheme)
        }
    }
}
