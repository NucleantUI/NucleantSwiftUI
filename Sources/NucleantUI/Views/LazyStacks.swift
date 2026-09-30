//
//  LazyStacks.swift
//  NucleantUI
//

/// Stacks its children vertically, building only those near the visible
/// part of the scroll view it is in.
///
/// ```swift
/// ScrollView {
///     LazyVStack(alignment: .leading, pinnedViews: .sectionHeaders) {
///         ForEach(library.artists) { artist in
///             Section {
///                 ForEach(artist.albums) { AlbumRow(album: $0) }
///             } header: {
///                 Text(artist.name).bold()
///             }
///         }
///     }
/// }
/// ```
///
/// Unlike a `VStack` it fills the width it is offered, and gives each child
/// its ideal height rather than a share of its own — a `Spacer` inside
/// takes only its minimum length. The elements of a `ForEach` inside are
/// built as they come within a screen of the visible part and let go of
/// once they are well past it: a row's `@State` goes with it, and its
/// `onAppear` runs each time it comes back. See `LazyLayout.swift`.
@View
public struct LazyVStack<Content: View>: View {
    public let alignment: HorizontalAlignment
    public let spacing: Double?
    public let pinnedViews: PinnedScrollableViews
    public let content: Content

    @State private var window = LazyWindow.initial
    @State private var memory = LazyLayoutMemory()

    public init(
        alignment: HorizontalAlignment = .center,
        spacing: Double? = nil,
        pinnedViews: PinnedScrollableViews = .init(),
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.pinnedViews = pinnedViews
        self.content = content()
        self._viewID = _viewID
    }

    public var body: Never { bodyUnavailable() }
}

extension LazyVStack: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let owner = context.path.hashValue
        var inner = context
        inner.stackAxis = .vertical
        inner.lazyCursor = LazyBuildCursor(owner: owner, window: window.units)
        let child = inner.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(
            content: LazyStackContent(
                axis: .vertical,
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

/// Stacks its children horizontally, building only those near the visible
/// part of the scroll view it is in — `LazyVStack` on its side.
@View
public struct LazyHStack<Content: View>: View {
    public let alignment: VerticalAlignment
    public let spacing: Double?
    public let pinnedViews: PinnedScrollableViews
    public let content: Content

    @State private var window = LazyWindow.initial
    @State private var memory = LazyLayoutMemory()

    public init(
        alignment: VerticalAlignment = .center,
        spacing: Double? = nil,
        pinnedViews: PinnedScrollableViews = .init(),
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.pinnedViews = pinnedViews
        self.content = content()
        self._viewID = _viewID
    }

    public var body: Never { bodyUnavailable() }
}

extension LazyHStack: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let owner = context.path.hashValue
        var inner = context
        inner.stackAxis = .horizontal
        inner.lazyCursor = LazyBuildCursor(owner: owner, window: window.units)
        let child = inner.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(
            content: LazyStackContent(
                axis: .horizontal,
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
