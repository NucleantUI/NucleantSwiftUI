//
//  EnvironmentModifiers.swift
//  NucleantUI
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

    /// At most `limit` lines — and, with `reservesSpace`, room for all of
    /// them even when fewer are used. The room is kept by a vertical
    /// `TextField`; a `Text` takes only the upper limit.
    public func lineLimit(_ limit: Int, reservesSpace: Bool) -> some View {
        lineLimits(lower: reservesSpace ? limit : 0, upper: limit)
    }

    /// Between `limit.lowerBound` and `limit.upperBound` lines. A vertical
    /// `TextField` keeps room for the lower bound and grows to the upper,
    /// then scrolls; a `Text` takes only the upper limit.
    public func lineLimit(_ limit: ClosedRange<Int>) -> some View {
        lineLimits(lower: limit.lowerBound, upper: limit.upperBound)
    }

    /// At least `limit.lowerBound` lines, with no upper limit.
    public func lineLimit(_ limit: PartialRangeFrom<Int>) -> some View {
        lineLimits(lower: limit.lowerBound, upper: nil)
    }

    /// At most `limit.upperBound` lines.
    public func lineLimit(_ limit: PartialRangeThrough<Int>) -> some View {
        lineLimits(lower: 0, upper: limit.upperBound)
    }

    private func lineLimits(lower: Int, upper: Int?) -> some View {
        _ModifierView(
            content: self,
            key: ["lineLimits", lower, upper] as [AnyHashable],
            environment: { values in
                values.lineLimit = upper
                values.reservedLineCount = lower
            },
            node: { context in EnvironmentContent(colorScheme: context.environment.colorScheme) }
        )
    }
}

private struct ReservedLineCountKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// The lines a vertical text field keeps room for however few it uses —
    /// the lower end of `.lineLimit(2...5)`, or `.lineLimit(3, reservesSpace: true)`.
    var reservedLineCount: Int {
        get { self[ReservedLineCountKey.self] }
        set { self[ReservedLineCountKey.self] = newValue }
    }
}
