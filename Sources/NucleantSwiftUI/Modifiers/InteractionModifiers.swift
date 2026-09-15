//
//  InteractionModifiers.swift
//  NucleantSwiftUI
//

extension View {

    /// Attach a raw hit target. Used by `Button`; exposed with an underscore
    /// because the supported spelling is `.onTapGesture`.
    public func _hitTarget(_ target: HitTarget) -> some View {
        _ModifierView(content: self) { _ in InteractionContent(target: target) }
    }

    /// Runs `action` when this view is tapped.
    public func onTapGesture(perform action: @escaping @MainActor () -> Void) -> some View {
        _ModifierView(content: self) { context in
            InteractionContent(target: HitTarget(
                isEnabled: context.environment.isEnabled,
                onRelease: { _, inside in if inside { action() } }
            ))
        }
    }

    /// Runs `action` when this view is tapped, with the tap location in the
    /// view's own coordinate space.
    public func onTapGesture(
        perform action: @escaping @MainActor (Point) -> Void
    ) -> some View {
        _ModifierView(content: self) { context in
            InteractionContent(target: HitTarget(
                isEnabled: context.environment.isEnabled,
                onRelease: { point, inside in if inside { action(point) } }
            ))
        }
    }

    /// Runs `action` the first time this view appears — once per appearance,
    /// not once per rebuild (identity is structural, the same key `@State`
    /// uses).
    public func onAppear(perform action: @escaping @MainActor () -> Void) -> some View {
        _ModifierView(content: self) { context in
            context.effects.onAppear(
                StateKey(path: context.path, propertyIndex: -1, viewType: ObjectIdentifier(OnAppearMarker.self)),
                action
            )
            return EnvironmentContent(colorScheme: context.environment.colorScheme)
        }
    }
}

/// Stands in for a view type in the `onAppear` key — the modifier has no
/// view of its own, and the key only needs to be distinct from every real one.
private enum OnAppearMarker {}
