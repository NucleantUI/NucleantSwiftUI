//
//  Image.swift
//  NucleantSwiftUI
//

/// A view that draws a bitmap.
///
/// ```swift
/// let sheet = RasterImage(contentsOf: url)!
/// Image(sheet)                              // one point per pixel
/// Image(sheet).resizable().scaledToFit()    // as large as fits, in proportion
/// ```
///
/// An image is drawn at its pixel size unless it is `.resizable()`, which
/// stretches it to whatever it is offered — pair that with
/// `.aspectRatio(contentMode:)` / `.scaledToFit()` to keep its proportions.
@View
public struct Image: View {
    public let image: RasterImage
    var isResizable = false

    public init(_ image: RasterImage) {
        self.image = image
    }

    public var body: Never { bodyUnavailable() }

    /// Stretched to the proposal instead of drawn at its pixel size.
    public func resizable() -> Image {
        var copy = self
        copy.isResizable = true
        return copy
    }
}

extension Image: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        ViewNode(content: ImageContent(image: image, isResizable: isResizable))
    }
}

/// `Image`.
struct ImageContent: NodeContent {
    let image: RasterImage
    let isResizable: Bool

    /// Fixed at its pixel size; resizable, it takes what it is offered and
    /// its pixel size on an axis nobody constrained.
    func flexibility(along axis: Axis, node: ViewNode) -> LayoutPriorityClass {
        isResizable ? .flexible : .fixed
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        isResizable ? proposal.replacingUnspecifiedDimensions(by: image.size) : image.size
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard rect.width > 0, rect.height > 0 else { return }
        list.append(.image(ImageDraw(
            image: image,
            frame: rect,
            opacity: context.opacity,
            transform: context.transform,
            clip: context.clip,
            clipCornerRadius: context.clipCornerRadius
        )))
    }
}

// MARK: - Aspect ratio

/// How `.aspectRatio(contentMode:)` fits a view to the space it is offered.
public enum ContentMode: Hashable, Sendable {
    /// As large as fits inside the proposal, in proportion.
    case fit
    /// As small as still covers the proposal, in proportion — the view
    /// overflows on one axis.
    case fill
}

extension View {
    /// Keeps this view at `aspectRatio` (width ÷ height) — or, with `nil`,
    /// at the proportions of its own ideal size — sized to fit or fill
    /// what it is offered.
    public func aspectRatio(_ aspectRatio: Double? = nil, contentMode: ContentMode) -> some View {
        _ModifierView(content: self, key: ["aspectRatio", aspectRatio, contentMode] as [AnyHashable]) { _ in
            AspectRatioContent(ratio: aspectRatio, contentMode: contentMode)
        }
    }

    /// `.aspectRatio(contentMode: .fit)`.
    public func scaledToFit() -> some View {
        aspectRatio(contentMode: .fit)
    }

    /// `.aspectRatio(contentMode: .fill)`.
    public func scaledToFill() -> some View {
        aspectRatio(contentMode: .fill)
    }
}

/// `.aspectRatio(_:contentMode:)`. The child is proposed a box of the
/// ratio, fitted to or filling the proposal; the node reports that box for
/// `.fit`, and the proposal itself for `.fill`, where the child overflows.
struct AspectRatioContent: NodeContent {
    let ratio: Double?
    let contentMode: ContentMode

    /// Width ÷ height: the one asked for, else the child's own.
    private func resolvedRatio(_ node: ViewNode) -> Double {
        if let ratio, ratio > 0 { return ratio }
        guard let child = node.singleChild else { return 1 }
        let ideal = child.sizeThatFits(.unspecified)
        return ideal.width > 0 && ideal.height > 0 ? ideal.width / ideal.height : 1
    }

    /// The box the child gets under `proposal`.
    private func childBox(_ proposal: ProposedSize, node: ViewNode) -> Size {
        let ratio = resolvedRatio(node)
        switch (proposal.width, proposal.height) {
        case (nil, nil):
            return node.singleChild?.sizeThatFits(.unspecified) ?? .zero
        case (let width?, nil):
            return Size(width: width, height: width / ratio)
        case (nil, let height?):
            return Size(width: height * ratio, height: height)
        case (let width?, let height?):
            guard width > 0, height > 0 else { return .zero }
            let byWidth = Size(width: width, height: width / ratio)
            let byHeight = Size(width: height * ratio, height: height)
            let wider = byWidth.height <= height
            switch contentMode {
            case .fit:  return wider ? byWidth : byHeight
            case .fill: return wider ? byHeight : byWidth
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        let box = childBox(proposal, node: node)
        switch contentMode {
        case .fit:  return box
        case .fill: return proposal.replacingUnspecifiedDimensions(by: box)
        }
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard let child = node.singleChild else { return }
        let box = childBox(proposal, node: node)
        child.place(
            in: Alignment.center.position(box, in: rect),
            proposal: ProposedSize(box),
            context: context,
            into: &list
        )
    }
}
