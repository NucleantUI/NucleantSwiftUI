//
//  EnvironmentModifiers.swift
//  NucleantSwiftUI
//

extension View {

    /// Sets one environment value for this view and everything inside it.
    public func environment<Value>(
        _ keyPath: WritableKeyPath<EnvironmentValues, Value>,
        _ value: Value
    ) -> some View {
        _ModifierView(
            content: self,
            // Comparable only when the value is — a closure or a class put
            // into the environment makes this modifier, and so its subtree,
            // always rebuild.
            key: (value as? AnyHashable).map { ["environment", AnyHashable(keyPath), $0] as [AnyHashable] },
            environment: { $0[keyPath: keyPath] = value },
            // The scheme in effect below this point, whether or not this is
            // the modifier that set it: dynamic colors are resolved at draw
            // time, so it has to travel with the draw context.
            node: { context in EnvironmentContent(colorScheme: context.environment.colorScheme) }
        )
    }

    /// Fixes the appearance for this view and everything inside it,
    /// whatever the system is set to.
    public func colorScheme(_ scheme: ColorScheme) -> some View {
        environment(\.colorScheme, scheme)
    }

    public func font(_ font: Font) -> some View {
        environment(\.font, font)
    }

    public func foregroundColor(_ color: Color) -> some View {
        environment(\.foregroundColor, color)
    }

    /// Alias for `foregroundColor` — `foregroundStyle` is the name SwiftUI
    /// moved to, and only its flat-color form applies here.
    public func foregroundStyle(_ color: Color) -> some View {
        foregroundColor(color)
    }

    public func tint(_ color: Color) -> some View {
        environment(\.tint, color)
    }

    public func disabled(_ isDisabled: Bool = true) -> some View {
        environment(\.isEnabled, !isDisabled)
    }

    public func multilineTextAlignment(_ alignment: TextAlignment) -> some View {
        environment(\.multilineTextAlignment, alignment)
    }

    public func lineLimit(_ limit: Int?) -> some View {
        environment(\.lineLimit, limit)
    }
}
