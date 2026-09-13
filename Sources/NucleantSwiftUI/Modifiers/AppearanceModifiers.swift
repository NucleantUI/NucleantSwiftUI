//
//  AppearanceModifiers.swift
//  NucleantSwiftUI
//

extension View {

    /// Puts `background` behind this view, stretched to this view's size.
    public func background<B: View>(
        _ background: B,
        alignment: Alignment = .center
    ) -> some View {
        _DecoratedView(
            content: self,
            decoration: background,
            order: .background,
            alignment: alignment
        )
    }

    public func background<B: View>(
        alignment: Alignment = .center,
        @ViewBuilder _ background: () -> B
    ) -> some View {
        self.background(background(), alignment: alignment)
    }

    /// Draws `overlay` on top of this view.
    public func overlay<O: View>(
        _ overlay: O,
        alignment: Alignment = .center
    ) -> some View {
        _DecoratedView(
            content: self,
            decoration: overlay,
            order: .overlay,
            alignment: alignment
        )
    }

    public func overlay<O: View>(
        alignment: Alignment = .center,
        @ViewBuilder _ overlay: () -> O
    ) -> some View {
        self.overlay(overlay(), alignment: alignment)
    }

    /// A stroked outline just inside this view's bounds.
    public func border(_ color: Color, width: Double = 1, cornerRadius: Double = 0) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(color, lineWidth: width)
        )
    }

    public func opacity(_ opacity: Double) -> some View {
        _ModifierView(content: self, key: ["opacity", opacity] as [AnyHashable]) { _ in OpacityContent(opacity: opacity) }
    }

    /// Laid out as usual, drawn not at all.
    public func hidden() -> some View {
        _ModifierView(content: self, key: ["hidden"] as [AnyHashable]) { _ in HiddenContent() }
    }

    /// Moves the drawing without disturbing the layout.
    public func offset(x: Double = 0, y: Double = 0) -> some View {
        _ModifierView(content: self, key: ["offset", Point(x: x, y: y)] as [AnyHashable]) { _ in OffsetContent(offset: Point(x: x, y: y)) }
    }

    public func rotationEffect(_ angle: Angle, anchor: UnitPoint = .center) -> some View {
        _ModifierView(content: self, key: ["rotation", angle, anchor] as [AnyHashable]) { _ in
            TransformContent(kind: .rotation(angle), anchor: anchor)
        }
    }

    public func scaleEffect(_ scale: Double, anchor: UnitPoint = .center) -> some View {
        scaleEffect(x: scale, y: scale, anchor: anchor)
    }

    public func scaleEffect(x: Double = 1, y: Double = 1, anchor: UnitPoint = .center) -> some View {
        _ModifierView(content: self, key: ["scale", x, y, anchor] as [AnyHashable]) { _ in
            TransformContent(kind: .scale(x: x, y: y), anchor: anchor)
        }
    }

    /// Clips to this view's bounds.
    public func clipped() -> some View {
        _ModifierView(content: self, key: ["clip", 0.0] as [AnyHashable]) { _ in ClipContent(cornerRadius: 0) }
    }

    /// Rounds the corners and clips to them.
    public func cornerRadius(_ radius: Double) -> some View {
        _ModifierView(content: self, key: ["clip", radius] as [AnyHashable]) { _ in ClipContent(cornerRadius: radius) }
    }

    /// Clips to a shape. Only the shape's bounding box (with its corner
    /// rounding, for a `RoundedRectangle` or `Capsule`) is honoured — ThorVG
    /// clips against a clipper paint, and a rect is what the display list
    /// carries.
    public func clipShape<S: Shape>(_ shape: S) -> some View {
        let radius = Self.clipCornerRadius(for: shape)
        return _ModifierView(content: self, key: ["clip", radius] as [AnyHashable]) { _ in
            ClipContent(cornerRadius: radius)
        }
    }

    private static func clipCornerRadius<S: Shape>(for shape: S) -> Double {
        switch shape {
        case let rounded as RoundedRectangle: return rounded.cornerRadius
        // A capsule's radius depends on the box it lands in, which isn't known
        // until placement; a large radius is clamped there.
        case is Capsule, is Circle, is Ellipse: return .greatestFiniteMagnitude
        default: return 0
        }
    }
}
