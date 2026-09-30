//
//  LazyGrids.swift
//  NucleantUI
//

/// One column of a `LazyVGrid`, or one row of a `LazyHGrid`: how wide (or
/// tall) it is, the gap after it, and how cells sit in it.
public struct GridItem: Sendable, Hashable {

    public enum Size: Sendable, Hashable {
        /// Exactly this wide.
        case fixed(Double)
        /// A share of what the fixed items leave, kept between the bounds.
        case flexible(minimum: Double = 10, maximum: Double = .infinity)
        /// As many items as fit in a flexible item's share, each at least
        /// `minimum` wide — the shape of a photo grid that gains columns as
        /// its window widens.
        case adaptive(minimum: Double, maximum: Double = .infinity)
    }

    public var size: GridItem.Size
    /// The gap after this item; `nil` for the default.
    public var spacing: Double?
    /// Where a cell smaller than this item sits in it; `nil` centres it.
    public var alignment: Alignment?

    public init(_ size: GridItem.Size = .flexible(), spacing: Double? = nil, alignment: Alignment? = nil) {
        self.size = size
        self.spacing = spacing
        self.alignment = alignment
    }
}

/// A grid that grows downward: `columns` say how the width is divided, and
/// the cells fill it row by row, built only as they come near the visible
/// part of the scroll view it is in.
///
/// ```swift
/// ScrollView {
///     LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
///         ForEach(library.photos) { PhotoTile(photo: $0) }
///     }
/// }
/// ```
///
/// A row is as tall as its tallest cell. A `Section`'s header and footer
/// take a row of their own, across every column, and stay at the edge with
/// `pinnedViews`. See `LazyVStack` for what "lazy" means for a cell.
@View
public struct LazyVGrid<Content: View>: View {
    public let columns: [GridItem]
    public let alignment: HorizontalAlignment
    public let spacing: Double?
    public let pinnedViews: PinnedScrollableViews
    public let content: Content

    @State private var window = LazyWindow.initial
    @State private var memory = LazyLayoutMemory()

    public init(
        columns: [GridItem],
        alignment: HorizontalAlignment = .center,
        spacing: Double? = nil,
        pinnedViews: PinnedScrollableViews = .init(),
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self.columns = columns
        self.alignment = alignment
        self.spacing = spacing
        self.pinnedViews = pinnedViews
        self.content = content()
        self._viewID = _viewID
    }

    public var body: Never { bodyUnavailable() }
}

extension LazyVGrid: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let owner = context.path.hashValue
        var inner = context
        inner.stackAxis = nil
        inner.lazyCursor = LazyBuildCursor(owner: owner, window: window.units)
        let child = inner.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(
            content: LazyGridContent(
                axis: .vertical,
                tracks: columns,
                alignment: Alignment(horizontal: alignment, vertical: .center),
                spacing: spacing,
                pinnedViews: pinnedViews,
                owner: owner,
                window: $window,
                memory: memory
            ),
            children: [child]
        )
    }
}

/// A grid that grows sideways: `rows` say how the height is divided, and
/// the cells fill it column by column — `LazyVGrid` on its side.
@View
public struct LazyHGrid<Content: View>: View {
    public let rows: [GridItem]
    public let alignment: VerticalAlignment
    public let spacing: Double?
    public let pinnedViews: PinnedScrollableViews
    public let content: Content

    @State private var window = LazyWindow.initial
    @State private var memory = LazyLayoutMemory()

    public init(
        rows: [GridItem],
        alignment: VerticalAlignment = .center,
        spacing: Double? = nil,
        pinnedViews: PinnedScrollableViews = .init(),
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self.rows = rows
        self.alignment = alignment
        self.spacing = spacing
        self.pinnedViews = pinnedViews
        self.content = content()
        self._viewID = _viewID
    }

    public var body: Never { bodyUnavailable() }
}

extension LazyHGrid: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let owner = context.path.hashValue
        var inner = context
        inner.stackAxis = nil
        inner.lazyCursor = LazyBuildCursor(owner: owner, window: window.units)
        let child = inner.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(
            content: LazyGridContent(
                axis: .horizontal,
                tracks: rows,
                alignment: Alignment(horizontal: .center, vertical: alignment),
                spacing: spacing,
                pinnedViews: pinnedViews,
                owner: owner,
                window: $window,
                memory: memory
            ),
            children: [child]
        )
    }
}
