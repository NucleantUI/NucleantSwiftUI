//
//  HitTestingModifiers.swift
//  NucleantUI
//
//  `.allowsHitTesting(_:)` and `.contentShape(_:)` — what a press, a hover
//  or a drop can land on.
//

extension View {

    /// Whether this view and everything in it can be pressed, hovered or
    /// dropped on. `false` lets input through to whatever is behind — an
    /// overlay that only decorates, a label drawn over a control.
    ///
    /// ```swift
    /// canvas.overlay(
    ///     Text("Drop images here").allowsHitTesting(false)
    /// )
    /// ```
    public func allowsHitTesting(_ enabled: Bool) -> some View {
        _ModifierView(content: self, key: ["allowsHitTesting", enabled] as [AnyHashable]) { _ in
            HitTestingContent(allowsHitTesting: enabled)
        }
    }

    /// Makes `shape`, laid over this view's frame, the area a press must
    /// land in to reach this view and the gestures around it — a round
    /// button that ignores its corners.
    ///
    /// A pointer target here covers its whole frame already, so the
    /// common SwiftUI use of `.contentShape(Rectangle())` (filling the gaps
    /// of a stack) changes nothing; a shape that is not a rectangle does.
    public func contentShape<S: Shape>(_ shape: S, eoFill: Bool = false) -> some View {
        contentShape(.interaction, shape, eoFill: eoFill)
    }

    /// Sets the shape for the given kinds of use. Only `.interaction` —
    /// hit testing — has an effect here; the others are kept for source
    /// compatibility.
    public func contentShape<S: Shape>(
        _ kinds: ContentShapeKinds,
        _ shape: S,
        eoFill: Bool = false
    ) -> some View {
        _ModifierView(content: self) { _ in
            HitTestingContent(
                allowsHitTesting: true,
                hitShape: kinds.contains(.interaction)
                    ? HitShape(path: { rect in shape.path(in: rect) }, eoFill: eoFill)
                    : nil
            )
        }
    }
}

/// What a `.contentShape` is for — SwiftUI's `ContentShapeKinds`.
public struct ContentShapeKinds: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Hit testing: presses, hovers, drops.
    public static let interaction = ContentShapeKinds(rawValue: 1 << 0)
    public static let dragPreview = ContentShapeKinds(rawValue: 1 << 1)
    public static let contextMenuPreview = ContentShapeKinds(rawValue: 1 << 2)
    public static let hoverEffect = ContentShapeKinds(rawValue: 1 << 3)
    public static let focusEffect = ContentShapeKinds(rawValue: 1 << 4)
    public static let accessibility = ContentShapeKinds(rawValue: 1 << 5)
}

/// A `.contentShape` resolved against the frame it is laid over.
@MainActor
struct HitShape {
    /// The shape's path in a rect — absolute, as `Shape.path(in:)` is.
    let path: @MainActor (Rect) -> Path
    let eoFill: Bool

    /// Whether `point` (window space, any transform undone) falls inside
    /// the shape laid over `frame`.
    func contains(_ point: Point, in frame: Rect) -> Bool {
        path(frame).contains(point, eoFill: eoFill)
    }
}

/// `.allowsHitTesting(_:)` and `.contentShape(_:)`.
struct HitTestingContent: NodeContent {
    let allowsHitTesting: Bool
    var hitShape: HitShape? = nil
}
